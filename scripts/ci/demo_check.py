#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Correctness check for a full /demo run. Reads the per-script outputs and
# the summary written by the demo runner, and checks:
#   * every script exited 0;
#   * no unexpected SQL ERROR lines (an allowlist names the expected ones);
#   * no NaN or inf cells;
#   * the expectations each demo states in its own comments.
# Outputs are LLM-generated in places, so model-dependent expectations are
# reported as WARN (model outcome) rather than FAIL when the demo's own
# validation caught the bad output, which is the behaviour the demo tests.
#
# Usage: demo_check.py <outdir>   (outdir holds summary.txt and *.out)
import json
import os
import re
import sys

# ERROR lines a demo is expected to produce. Anything else is a failure.
ALLOWED_ERRORS = {
    "demo-fractal-vector": ["CONSTRAINT"],
}

results = []  # (status, name, message)


def record(status, name, message):
    results.append((status, name, message))


# Expected-output names used by check_expectations -> the file name
# run-all-demos.sh writes for that script.
ALIASES = {
    "demo-agents": "agents",
    "demo-fractal-vector": "fractal-vector",
    "demo-text-to-sql": "text-to-sql",
    "text-to-sql-spike-2-review": "t2s-spike-2-review",
    "text-to-sql-spike-3-validate": "t2s-spike-3-validate",
}


def read(outdir, name):
    path = os.path.join(outdir, ALIASES.get(name, name) + ".out")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def rows_after(lines, header_index):
    """Data rows following a header line, up to a blank line or the next header."""
    rows = []
    for line in lines[header_index + 1:]:
        if line.strip() == "":
            break
        rows.append(line.split("\t"))
    return rows


def find_header(lines, header):
    for i, line in enumerate(lines):
        if line.split("\t") == header:
            return i
    return None


def check_summary(outdir):
    summary = {}
    path = os.path.join(outdir, "summary.txt")
    if not os.path.exists(path):
        record("FAIL", "summary", "summary.txt missing: the run did not finish")
        return summary
    with open(path) as f:
        for line in f:
            m = re.match(r"(\S+) rc=(\d+)", line)
            if m:
                summary[m.group(1)] = int(m.group(2))
    if "DONE" not in open(path).read():
        record("FAIL", "summary", "run did not reach DONE")
    return summary


def check_script_generic(name, text, rc):
    if rc != 0:
        record("FAIL", name, f"exit code {rc}")
    if text is None:
        record("FAIL", name, "no output file")
        return
    errors = [l for l in text.splitlines() if "ERROR" in l and re.search(r"ERROR \d+ \(", l)]
    allowed = ALLOWED_ERRORS.get(name, [])
    unexpected = [l for l in errors if not any(a in l for a in allowed)]
    if unexpected:
        record("FAIL", name, f"{len(unexpected)} unexpected ERROR line(s): {unexpected[0][:160]}")
    for line in text.splitlines():
        for cell in line.split("\t"):
            if cell.strip() in ("NaN", "nan", "inf", "-inf", "Infinity", "-Infinity"):
                record("FAIL", name, f"non-finite value in output: {line[:120]}")
                break
        else:
            continue
        break


def read_defined_agents():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sql", "install_agents.sql")
    with open(path) as f:
        return set(re.findall(r"CREATE PROCEDURE (fractal_agent_\w+)", f.read()))


def check_expectations(outdir):
    text = read(outdir, "benchmark-api-reference")
    if text is not None:
        lines = text.splitlines()
        i = find_header(lines, ["change_points"])
        if i is not None and i + 1 < len(lines):
            try:
                cp = json.loads(lines[i + 1].strip())
            except ValueError:
                cp = None
            if cp is not None and len(cp) == 2 and 48 <= cp[0] <= cp[1] <= 64:
                record("PASS", "benchmark-api-reference", f"change point in [48,64] (got {cp})")
            else:
                record("FAIL", "benchmark-api-reference", f"change point expected in [48,64], got {lines[i + 1]}")
        else:
            record("FAIL", "benchmark-api-reference", "change_points result not found")
        i = find_header(lines, ["top_freq", "top_power"])
        if i is not None and i + 1 < len(lines):
            freq = float(lines[i + 1].split("\t")[0])
            if abs(freq - 0.125) < 1e-6:
                record("PASS", "benchmark-api-reference", f"periodogram top freq = 0.125 (got {freq})")
            else:
                record("FAIL", "benchmark-api-reference", f"periodogram top freq expected 0.125, got {freq}")

    text = read(outdir, "demo-agents")
    if text is not None:
        defined = read_defined_agents()
        listed = {l.strip() for l in text.splitlines() if l.startswith("fractal_agent_") and " " not in l.strip()}
        missing = sorted(defined - listed)
        if missing:
            record("FAIL", "demo-agents", f"installed agent routines not listed: {missing}")
        else:
            record("PASS", "demo-agents", f"all {len(defined)} installed fractal_agent_* routines listed")

    text = read(outdir, "demo-fractal-vector")
    if text is not None:
        if "dimension constraint rejected" in text:
            record("PASS", "demo-fractal-vector", "the 2-element insert was rejected by the dimension constraint")
        elif "NOT rejected" in text:
            record("FAIL", "demo-fractal-vector", "the dimension constraint did not reject a 2-element vector")
        else:
            record("FAIL", "demo-fractal-vector", "negative insert result not found")

    text = read(outdir, "response-modes")
    if text is not None:
        if "```" in text:
            record("FAIL", "response-modes", "code fence markers left in the returned SQL")
        else:
            record("PASS", "response-modes", "no fence markers in the returned SQL")

    text = read(outdir, "demo-text-to-sql")
    if text is not None:
        # Each generation prints one row: generated_sql, sql_missing, out_error.
        # A row passes when the SQL is present and no error was reported.
        rows = []
        for line in text.splitlines():
            cells = line.split("\t")
            if len(cells) == 3 and cells[1] in ("0", "1"):
                rows.append(cells)
        bad = [r for r in rows if r[1] != "0" or r[2] != "NULL"]
        if not rows:
            record("FAIL", "demo-text-to-sql", "no generation rows found")
        elif bad:
            record("FAIL", "demo-text-to-sql", f"{len(bad)} of {len(rows)} generations failed: {bad[0][2][:120]}")
        else:
            record("PASS", "demo-text-to-sql", f"{len(rows)} generations returned SQL with no out_error")

    spike3 = read(outdir, "text-to-sql-spike-3-validate")
    spike2 = read(outdir, "text-to-sql-spike-2-review")
    if spike3 is not None:
        lines = spike3.splitlines()
        rows = []
        for i, line in enumerate(lines):
            if line.split("\t")[:1] == ["service"]:
                rows = [r for r in rows_after(lines, i)]
        # Column layout depends on the candidate SQL, so check values, not headers:
        # the stated result is api-gateway with two critical and two info alerts,
        # and no payments or auth-service rows.
        services = {r[0] for r in rows if r}
        values = [v for r in rows for v in r]
        ok = (services == {"api-gateway"} and "2" in values
              and not ({"payments", "auth-service"} & services))
        if ok:
            record("PASS", "text-to-sql-spike-3-validate", "execute output matches the stated result")
        elif spike2 is not None and "FAIL" in spike2:
            record("WARN", "text-to-sql-spike-3-validate",
                   f"candidate SQL was wrong ({rows}); the reviewer rejected it, so validation caught it")
        else:
            record("FAIL", "text-to-sql-spike-3-validate",
                   f"execute output {rows} does not match the stated result and the reviewer did not reject it")

# Scripts whose output the expectation checks require. A missing output is a
# FAIL, not a silent skip.
REQUIRED = ["benchmark-api-reference", "demo-agents", "demo-fractal-vector",
            "demo-text-to-sql", "text-to-sql-spike-3-validate"]


def main():
    outdir = sys.argv[1]
    summary = check_summary(outdir)
    for name, rc in sorted(summary.items()):
        if name == "DONE":
            continue
        check_script_generic(name, read(outdir, name), rc)
    for name in REQUIRED:
        if read(outdir, name) is None:
            record("FAIL", name, "expected output missing: the script did not produce a result")
    check_expectations(outdir)

    counts = {"PASS": 0, "FAIL": 0, "WARN": 0}
    for status, name, message in results:
        counts[status] += 1
        print(f"[{status}] {name}: {message}")
    print(f"\nscripts: {len(summary) - ('DONE' in summary)}  "
          f"PASS {counts['PASS']}  FAIL {counts['FAIL']}  WARN {counts['WARN']}")
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    sys.exit(main())
