#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/mdb_kit_mutation.py -- every kit statement re-run with one literal swapped for an awkward value.

The kits in demo/ are the engine's own end-to-end exercises: each one builds a fixture, calls the fractal_*
functions over it and prints a headline result. Every statement in them that CALLS a fractal_ function is
re-run here with one of its literal arguments swapped for an awkward value (NULL, an empty string, a huge
number, a malformed JSON fragment, ...) and with its argument list changed (an argument dropped, an extra
argument appended). The mutated statement must be answered or refused cleanly: the daemon may not crash and
may not hang.

Env: FSQL_MARIADB_JSON -- the mariadb client command as a JSON list (connection options, -N); MUT_MAX (the
literal mutants per statement, default 8); MUT_FILTER (a regex over the kit file name); MUT_MAX_KITS (a cap,
for debugging). Exit status is nonzero when a check fails.
"""
import glob
import json
import os
import re
import subprocess
import sys

CLI = json.loads(os.environ["FSQL_MARIADB_JSON"]) + ["--default-character-set=utf8mb4"]
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MUT_MAX = int(os.environ.get("MUT_MAX", "8") or 8)
MUT_MAX_KITS = int(os.environ.get("MUT_MAX_KITS", "0") or 0)
FILTER = re.compile(os.environ.get("MUT_FILTER", ""))

# A literal: a single-quoted string (with '' for an embedded quote) or a number that is not glued to a word
# character or a dot.
LIT = re.compile(r"'(?:[^']|'')*'|(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w.])")
STR_POOL = ["NULL", "''", "'{}'", "'[]'", "'{\"a\":'", "'x'", "'0'", "-1", "0", "1e308", "'[1,2'"]
NUM_POOL = ["NULL", "0", "-1", "1", "2147483647", "1e308", "-1e308", "'x'", "''", "0.0", "1e-300"]

TARGET = re.compile(r"(?is)^\s*(select|with)\b")
CALL = re.compile(r"\bfractal_[a-z0-9_]*\s*\(")

passes = fails = 0
crashes = 0
mutated = 0


def safe(t):
    """A mutated statement may hold characters a Windows console (cp1252) cannot print: show them escaped."""
    return str(t).encode("ascii", "backslashreplace").decode("ascii")


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (safe(what), ("-- " + safe(detail)[:250]) if detail else ""))


def sql(s):
    """One statement. Returns (ok, output): a refusal is ok=False with the error text."""
    try:
        p = subprocess.run(CLI + ["-e", s], capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    out = (p.stdout + p.stderr).decode("utf-8", "replace").strip()
    if p.returncode != 0:
        # A dead server reads as an empty output and a nonzero status: that is the crash this gate looks for.
        if "Lost connection" in out or "server has gone away" in out or "Can't connect" in out:
            return False, "CRASH: " + out[:160]
        return False, out
    return True, out


def split_statements(text):
    """Splits a script into statements on a top-level semicolon, honouring quotes and comments."""
    stmts, buf = [], []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(text[i:min(j + 1, n)])
            i = j + 1
            continue
        if ch == '"':
            j = text.find('"', i + 1)
            j = n if j < 0 else j + 1
            buf.append(text[i:j])
            i = j
            continue
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            buf.append(" ")
            i = j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            buf.append(" ")
            i = j
            continue
        if ch == ";":
            stmts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if "".join(buf).strip():
        stmts.append("".join(buf))
    return [s.strip() for s in stmts if s.strip()]


def literal_mutants(st, limit):
    """One literal swapped for an awkward value of its own kind, spread over the statement's literals."""
    lits = list(LIT.finditer(st))
    out = []
    pool_i = 0
    round_no = 0
    while len(out) < limit and lits:
        added = 0
        for m in lits:
            if len(out) >= limit:
                break
            pool = STR_POOL if m.group(0).startswith("'") else NUM_POOL
            v = pool[(pool_i + round_no) % len(pool)]
            pool_i += 1
            if v == m.group(0):
                continue
            out.append(st[:m.start()] + v + st[m.end():])
            added += 1
        round_no += 1
        if added == 0:
            break
    return out


def arity_mutants(st):
    """The argument list changed: the trailing arguments dropped, an extra argument appended."""
    out = []
    for m in re.finditer(r"\bfractal_[a-z0-9_]*\s*\(", st):
        open_at = st.index("(", m.start())
        depth, i, args = 0, open_at, []
        arg_start = open_at + 1
        while i < len(st):
            ch = st[i]
            if ch == "'":
                j = i + 1
                while j < len(st):
                    if st[j] == "'":
                        if j + 1 < len(st) and st[j + 1] == "'":
                            j += 2
                            continue
                        break
                    j += 1
                i = j + 1
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    args.append((arg_start, i))
                    break
            elif ch == "," and depth == 1:
                args.append((arg_start, i))
                arg_start = i + 1
            i += 1
        if not args:
            continue
        texts = [st[a:b] for a, b in args]
        if len(texts) > 1:
            out.append(st[:open_at + 1] + ",".join(texts[:-1]) + st[args[-1][1]:])
        out.append(st[:args[-1][1]] + ", NULL" + st[args[-1][1]:])
        for a, b in args:
            out.append(st[:a] + " NULL " + st[b:])
    return out


def main():
    global passes, fails, crashes, mutated
    demo = os.path.join(ROOT, "demo")
    kits = sorted(glob.glob(os.path.join(demo, "demo-vertical-*.sql")))
    if MUT_MAX_KITS:
        kits = kits[:MUT_MAX_KITS]
    if not kits:
        print("  FAIL no kit files under demo/")
        return 1

    for kit in kits:
        name = os.path.basename(kit)
        if not FILTER.search(name):
            continue
        with open(kit, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        stmts = split_statements(text)
        setup = [s for s in stmts if not (TARGET.match(s) and CALL.search(s))]
        targets = [s for s in stmts if TARGET.match(s) and CALL.search(s)]
        for s in setup:
            sql(s + ";")
        for st in targets:
            for mu in literal_mutants(st, MUT_MAX) + arity_mutants(st):
                mutated += 1
                ok, out = sql(mu + ";")
                if "CRASH:" in out:
                    crashes += 1
                    check(False, "the daemon died on: %s" % mu[:120].replace("\n", " "), out[:160])
                    break
        for s in setup:
            sql("DROP TABLE IF EXISTS " + s.split("CREATE TABLE", 1)[-1].split("(", 1)[0].strip() + ";")

    check(crashes == 0, "no mutated statement crashed the daemon (%d statements mutated over %d kits)"
          % (mutated, len(kits)), crashes)
    print("kit mutation: %d kits, %d mutated statements, %d crashed" % (len(kits), mutated, crashes))
    return 1 if crashes else 0


if __name__ == "__main__":
    sys.exit(main())
