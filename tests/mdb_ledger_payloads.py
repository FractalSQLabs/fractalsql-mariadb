#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/mdb_ledger_payloads.py -- what fractal_audit_log writes into the decision-audit chain for every shape
of entry type and payload.

The ledger entry is built from the caller's text: {"type": ..., "entry": ...} with an "_actor" block added.
Whatever the text holds must never break the JSON or the chain: an object payload takes the actor inside it, a
scalar or an array is wrapped as {"value": ...}, and the entry type is escaped (quote, backslash, control
characters, unicode). Each entry must be accepted or refused cleanly, and the chain must still verify.

Env: FSQL_MARIADB_JSON -- the mariadb client command as a JSON list (connection options, -N). Exit status is
nonzero when a check fails.
"""
import json
import os
import subprocess
import sys

CLI = json.loads(os.environ["FSQL_MARIADB_JSON"]) + ["--default-character-set=utf8mb4"]

ESC = "q\" b\\ bs\b ff\f nl\n cr\r tab\t c1\x01 c1f\x1f end"

# (what, payload, accepted). Every payload is already JSON text, so the shapes the entry builder
# distinguishes are: an object (the actor goes inside it) and everything else (wrapped as a value).
PAYLOADS = (
    ("an object",                    '{"n":1}',                 True),
    ("a nested object",              '{"a":{"b":[1,2,{"c":null}]}}', True),
    ("an object with a null value",  '{"a":null}',              True),
    ("an empty object",              '{}',                      True),
    ("an array",                     '[1,2,3]',                 True),
    ("an array of objects",          '[{"a":1},{"b":2}]',       True),
    ("a string",                     '"text"',                  True),
    ("a number",                     '12',                      True),
    ("true",                         'true',                    True),
    ("null",                         'null',                    True),
    ("an object that is not closed", '{"a":1',                  False),
    ("plain text",                   'not json',                False),
    ("the empty string",             '',                        False),
)

# (what, entry type)
TYPES = (
    ("a plain name",        "plain"),
    ("a quote",             'a"b'),
    ("a backslash",         "a\\b"),
    ("every escape and control character", ESC),
    ("a long type",         "t" * 300),
    ("a unicode type",      "tipo é 日本 \U0001f600"),
    ("an empty type",       ""),
    ("a JSON-looking type", '{"type":"forged"}'),
)

passes = fails = 0


def safe(t):
    """The text under test may hold characters a Windows console (cp1252) cannot print: show them escaped.

    Printing it raw kills the driver, and the report of the defect goes with it."""
    return str(t).encode("ascii", "backslashreplace").decode("ascii")


def check(cond, what, detail=""):
    global passes, fails
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL %s %s" % (safe(what), ("-- " + safe(detail)[:250]) if detail else ""))


def sql(s):
    p = subprocess.run(CLI + ["-e", s], capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "replace").strip(), p.stderr.decode("utf-8", "replace")


def lit(t):
    """A text literal, sent as bytes so the server sees exactly the characters under test."""
    return "CONVERT(UNHEX('%s') USING utf8mb4)" % t.encode("utf-8").hex()


def main():
    global passes, fails
    # --- the payload shapes -----------------------------------------------------------------------
    for what, payload, accepted in PAYLOADS:
        rc, out, err = sql("SELECT fractal_audit_log('type.payload', %s)" % lit(payload))
        if accepted:
            check(rc == 0, "audit_log accepts %s" % what, (out, err))
        else:
            # A payload that is not JSON at all: the call must be refused cleanly -- refused with an
            # error, or answered with a NULL, but never a crash and never a broken chain.
            check(rc != 0 or out.upper() == "NULL", "audit_log refuses %s cleanly" % what, (out, err))

    # --- the entry types --------------------------------------------------------------------------
    for what, etype in TYPES:
        rc, out, err = sql("SELECT fractal_audit_log(%s, '{\"k\":1}')" % lit(etype))
        check(rc == 0, "audit_log takes an entry type with %s" % what, (out, err))

    # --- the chain still verifies ------------------------------------------------------------------
    rc, out, err = sql("SELECT fractal_ledger_verify(CONNECTION_ID())")
    if check(rc == 0, "the chain verifies after every entry", (out, err)):
        try:
            report = json.loads(out)
            check(report.get("ok") is True, "the verification report says ok", out[:200])
        except Exception as e:
            check(False, "the verification report is JSON", (e, out[:200]))

    print("ledger payloads: %d checks passed, %d failed" % (passes, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
