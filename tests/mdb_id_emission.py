#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/mdb_id_emission.py -- how the agents write a row's id into their JSON result.

The id column is the caller's data, so what an agent writes must never become JSON structure and must never be
altered: the id comes back byte for byte -- quotes, backslashes, control characters, unicode, an empty id, a
400-digit id -- and the result document stays valid JSON.

Env: FSQL_MARIADB_JSON -- the mariadb client command as a JSON list (connection options, -N). Exit status is
nonzero when a check fails.

The client runs with --raw: in batch mode the mariadb client escapes backslashes in its output, so every id
holding a quote, a backslash or a control character would arrive here doubled.
"""
import json
import os
import subprocess
import sys

CLI = (json.loads(os.environ["FSQL_MARIADB_JSON"])
       + ["--default-character-set=utf8mb4", "--raw"])

IDS = ("42", "0", "-7", "10.5", "007", "", "true", "null", "NaN",
       '{"x":1', '["a"', 'quote " and backslash \\', "tab\there", "line\nbreak", "cr\rhere",
       "back\bspace and form\ffeed", "ctl\x01\x02\x1f end", "slash / and unicode é 日本 \U0001f600",
       "-" + "9" * 400, "1" + "0" * 400)

TABLE = "mdb_id_emission"

passes = fails = 0


def safe(t):
    """The id may hold characters a Windows console cannot print (cp1252): show them escaped.

    Without this the driver dies printing the id it is complaining about, and the report of the defect
    is lost with it."""
    return str(t).encode("ascii", "backslashreplace").decode("ascii")


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (safe(what), ("-- " + safe(detail)[:250]) if detail else ""))


def charset_refusal(err):
    """The server's character set cannot hold the text: that is the charset, not a defect.

    MariaDB's wording varies with the version and the column: "Incorrect string value" (the
    column's charset cannot hold the characters), "Character set ...", and the generic
    "character"/"charset"/"encoding" words.

    "Data too long" is NOT here: that is a length refusal, not a charset one."""
    e = err.lower()
    return ("character" in e or "charset" in e or "encoding" in e
            or "incorrect string value" in e) and "data too long" not in e


def sql(s):
    p = subprocess.run(CLI + ["-e", s], capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "replace").strip(), p.stderr.decode("utf-8", "replace")


def lit(t):
    """A text literal, sent as bytes so the server sees exactly the characters under test."""
    return "CONVERT(UNHEX('%s') USING utf8mb4)" % t.encode("utf-8").hex()


def main():
    global passes, fails
    rc, out, err = sql("DROP TABLE IF EXISTS %s; CREATE TABLE %s (id VARCHAR(512) PRIMARY KEY, emb JSON)" % (TABLE, TABLE))
    if rc != 0:
        print("  FAIL the fixture table could not be created: %s" % err[:200])
        return 1

    # One row per awkward id, so the agent's answer is about that row and not about a neighbour.
    for ident in IDS:
        rc, out, err = sql("INSERT INTO %s (id, emb) VALUES (%s, JSON_ARRAY(0.1, 0.2, 0.3))" % (TABLE, lit(ident)))
        if rc != 0:
            # A server whose character set cannot hold the text refuses the insert; that is the character
            # set, not a defect in the extension.
            if charset_refusal(err):
                print("  note: the server's character set cannot hold one of the ids -- skipped")
                continue
            check(False, "the row with the id %r could be written" % ident[:24], (out, err))

    # --- the id comes back exactly -----------------------------------------------------------------
    for ident in IDS:
        # One row on its own, so the agent's answer is about that row and not a neighbour.
        sql("DELETE FROM %s" % TABLE)
        rc, out, err = sql("INSERT INTO %s (id, emb) VALUES (%s, JSON_ARRAY(0.1, 0.2, 0.3))" % (TABLE, lit(ident)))
        if rc != 0:
            if charset_refusal(err):
                continue
            check(False, "the row with the id %r could be written" % ident[:24], (out, err))
            continue

        # The id in the table is exactly what the caller put there.
        rc, back, err = sql("SELECT HEX(CONVERT(id USING utf8mb4)) FROM %s" % TABLE)
        if rc != 0:
            check(False, "the id %r can be read back" % ident[:24], (out, err))
            continue
        check(back.strip().lower() == ident.encode("utf-8").hex(),
              "the id %r survives the table round trip" % ident[:24], (back.strip()[:80],))

        # The agent's OUT parameter is a user variable, so the CALL takes it as its last argument.
        rc, out, err = sql(
            "SET @r = NULL; "
            "CALL fractal_agent_track_anomaly('%s', 'emb', JSON_ARRAY(0.1, 0.2, 0.3), JSON_ARRAY(0.1, 0.2, 0.3), "
            "JSON_ARRAY(0.1, 0.2, 0.3), 1, @r); SELECT @r;" % TABLE)
        if rc != 0:
            if charset_refusal(err):
                continue
            check(False, "the agent answers for the id %r" % ident[:24], (out, err))
            continue
        # The procedure's OUT parameter comes back as a JSON document (the last line of the answer).
        try:
            result = json.loads([l for l in out.splitlines() if l.strip()][-1])
        except Exception as e:
            check(False, "the agent's result for the id %r is JSON" % ident[:24], (e, out[:160]))
            continue
        check(isinstance(result, dict) and "nearest_fleet_id" in result,
              "the agent's result for the id %r carries the id field" % ident[:24], str(result)[:160])
        # The agent writes the row's own id into the answer, and it must be the caller's text, byte for
        # byte -- never a mangled, truncated or re-encoded version of it.
        got = result.get("nearest_fleet_id") if isinstance(result, dict) else None
        check(got == ident, "the id %r comes back byte for byte" % ident[:24], (got, str(result)[:160]))

    sql("DROP TABLE IF EXISTS %s" % TABLE)
    print("id emission: %d checks passed, %d failed" % (passes, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
