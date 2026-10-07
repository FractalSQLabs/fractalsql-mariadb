#!/usr/bin/env python3
"""tests/test_text_to_sql_fuzz.py: adversarial/fuzz suite for the
text-to-sql allowlist (fractal_t2s_check_allowlist) and the GENERATE
round trip (fractal_t2s_generate + fractal_text_to_sql).

Two structural notes, both already noted by mock_llm.py's
own docstring and this repo's src/fractalsql_textsql.c:

  1. fractal_t2s_check_allowlist(sql) is a standalone, deterministic,
     no-LLM-needed function (the allowlist check is deliberately
     factored out of fractal_text_to_sql() itself, so it can be
     exercised directly without getting a "model" to emit a specific
     string). Most of this
     suite exercises it directly: more scenarios, faster, no mock
     server needed for them at all.

  2. fractal_text_to_sql's reasoning config (which plugin/endpoint) is
     fixed at mariadbd startup, read once from the process environment,
     so this suite can't point the pipeline at a fresh mock per
     scenario. The small GENERATE-path integration section
     instead uses
     _t2s_common.MutableMockLLMServer, bound to the SAME fixed port
     FRACTALSQL_HTTP_URL already names, and swaps its canned reply
     between scenarios.

  3. MariaDB's WITH clause is SELECT-only at the CTE-body level (no
     "WITH d AS (DELETE ...) SELECT ..." syntax exists in MariaDB) --
     see fractalsql_textsql.c's own header comment. A "data-modifying
     CTE hidden under a top-level SELECT"
     scenario is structurally impossible here; the equivalent hazard
     ("WITH cte AS (SELECT ...) DELETE FROM t WHERE id IN (SELECT ..
     FROM cte)", a CTE feeding a top-level DELETE) is covered instead
     -- same case build_test.sh's gate 10 already exercises, repeated
     here as part of a broader adversarial sweep, not a duplicate check.

Skip-safe: exits 0 with a SKIP: message if the mariadb connector is
missing or no DB is reachable. The direct-allowlist scenarios need no
reasoning plugin at all; the GENERATE-path section additionally skips
(not fails) if FRACTALSQL_REASONING_PLUGIN isn't present on this host.

Usage:
    python3 tests/test_text_to_sql_fuzz.py
"""
import os
import sys

from _t2s_common import connect_or_skip, reasoning_available, to_str, MutableMockLLMServer

# (name, candidate SQL, substring expected in the rejection reason, or
# None for "must pass the allowlist cleanly").
ALLOWLIST_SCENARIOS = [
    ("stacked statement injection",
     "SELECT 1; DROP TABLE _t2s_fuzz_target",
     "exactly one SQL statement"),
    ("bare DDL",
     "DROP TABLE _t2s_fuzz_target",
     "not permitted"),
    ("disallowed statement type (DELETE, default allowed=select)",
     "DELETE FROM _t2s_fuzz_target",
     "not permitted"),
    ("CTE feeding a top-level DELETE",
     "WITH cte AS (SELECT id FROM _t2s_fuzz_target) "
     "DELETE FROM _t2s_fuzz_target WHERE id IN (SELECT id FROM cte)",
     "not permitted"),
    ("INTO OUTFILE exfiltration",
     "SELECT * FROM _t2s_fuzz_target INTO OUTFILE '/tmp/fsql_fuzz_exfil'",
     "OUTFILE"),
    ("INTO DUMPFILE exfiltration",
     "SELECT * FROM _t2s_fuzz_target INTO DUMPFILE '/tmp/fsql_fuzz_exfil2'",
     "OUTFILE"),  # same rejection path/message covers DUMPFILE too
    ("malformed WITH clause",
     "WITH cte AS (SELECT id FROM _t2s_fuzz_target",  # unterminated
     "does not parse"),
    ("empty string",
     "",
     "SQL is empty"),
    ("positive control (plain SELECT)",
     "SELECT COUNT(*) FROM _t2s_fuzz_target",
     None),
    ("positive control (SELECT with WITH clause)",
     "WITH cte AS (SELECT id FROM _t2s_fuzz_target) SELECT COUNT(*) FROM cte",
     None),
]


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def run_allowlist_scenarios(cur):
    passed = 0
    for name, candidate, expect_substr in ALLOWLIST_SCENARIOS:
        cur.execute("SELECT fractal_t2s_check_allowlist(?)", (candidate,))
        verdict = to_str(cur.fetchone()[0])
        if expect_substr is None:
            if verdict is not None:
                fail(f"[{name}] expected the allowlist to pass, got rejection: {verdict!r}")
            print(f"OK: [{name}] passed the allowlist")
        else:
            if verdict is None:
                fail(f"[{name}] expected rejection containing {expect_substr!r}, "
                     "allowlist passed it")
            if expect_substr.lower() not in verdict.lower():
                fail(f"[{name}] expected rejection containing {expect_substr!r}, got: {verdict!r}")
            print(f"OK: [{name}] rejected as expected ({verdict!r})")
        passed += 1
    return passed


def run_generate_scenarios(cur, mock_port):
    """GENERATE-path integration: fenced-extraction + allowlist, driven
    through the real fractal_text_to_sql() procedure against a mutable
    local mock. Smaller than ALLOWLIST_SCENARIOS -- only cases that
    actually exercise the fence-extraction step, not the allowlist
    logic already covered above."""
    passed = 0
    scenarios = [
        ("GENERATE: stacked statement",
         "```sql\nSELECT 1; DROP TABLE _t2s_fuzz_target;\n```",
         "exactly one SQL statement"),
        ("GENERATE: positive control",
         "```sql\nSELECT count(*) FROM _t2s_fuzz_target\n```",
         None),
    ]
    with MutableMockLLMServer(mock_port) as mock:
        for name, canned, expect_substr in scenarios:
            mock.set_content(canned)
            cur.execute(
                "CALL fractal_text_to_sql(?, ?, @s, @e)",
                (f"scenario: {name}", '["_t2s_fuzz_target"]'))
            cur.execute("SELECT @s, @e")
            sql, err = cur.fetchone()
            sql, err = to_str(sql), to_str(err)
            if expect_substr is None:
                if sql is None:
                    fail(f"[{name}] expected success, got out_error={err!r}")
                print(f"OK: [{name}] returned {sql!r}")
            else:
                if sql is not None:
                    fail(f"[{name}] expected rejection containing {expect_substr!r}, "
                         f"got returned SQL instead: {sql!r}")
                if not err or expect_substr.lower() not in err.lower():
                    fail(f"[{name}] expected out_error containing {expect_substr!r}, got: {err!r}")
                print(f"OK: [{name}] rejected as expected ({err!r})")
            passed += 1
    return passed


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    cur = conn.cursor()
    cur.execute("DROP TABLE IF EXISTS _t2s_fuzz_target")
    cur.execute("CREATE TABLE _t2s_fuzz_target (id BIGINT PRIMARY KEY AUTO_INCREMENT, name TEXT)")

    passed = run_allowlist_scenarios(cur)

    if reasoning_available():
        mock_port = int(os.environ.get("FRACTALSQL_MOCK_PORT", "18080"))
        try:
            passed += run_generate_scenarios(cur, mock_port)
        except OSError as e:
            print(f"SKIP: GENERATE-path section -- could not bind mock port "
                  f"{mock_port} (already in use by another gate?): {e}")
    else:
        print("SKIP: GENERATE-path section -- reasoning plugin not found on this host")

    cur.execute("DROP TABLE IF EXISTS _t2s_fuzz_target")
    print(f"OK: {passed} fuzz scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
