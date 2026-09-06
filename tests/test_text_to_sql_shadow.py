#!/usr/bin/env python3
"""tests/test_text_to_sql_shadow.py: shadow test for
fractal_text_to_sql(), against a real local model.

"Shadow" here means: run the real pipeline and independently EXECUTE
the SQL it returns, comparing the actual result against a ground truth
computed directly in SQL -- shadowing the pipeline's own implicit
verdict (it returned successfully = GENERATE + ALLOWLIST + EXPLAIN-
equivalent all approved it) against ground truth, without the
ground-truth check gating anything inside the pipeline itself.
MariaDB port of fractalsql-postgresql's test_text_to_sql_shadow.py,
same hard multi-constraint question (grouping + a HAVING-shaped
exclusion an LLM can plausibly miss).

Structural difference from postgres: reasoning config (which model,
use_review) is fixed at mariadbd startup, read once from the process
environment, so this file tests exactly ONE model per run: whatever
FRACTALSQL_HTTP_MODEL/FRACTALSQL_TEXT_TO_SQL_USE_REVIEW the server was
started with, rather than looping over FRACTALSQL_MODELS and
reconfiguring between them the
way postgres's version does. Run it once per model/config you want to
validate (e.g. once per mariadbd env in a matrix), not once total.

Outcomes:
    PASS            -- pipeline returned SQL, and it matches ground truth
    WRONG-ANSWER    -- pipeline returned SQL, but it does NOT match
                       ground truth -- review/EXPLAIN approved something
                       wrong. This is the real thing this test exists to
                       catch.
    GENERATION-FAILED -- pipeline exhausted its retry budget and errored;
                       disappointing but not a safety failure (it
                       refused to return something it couldn't validate).
    UNREACHABLE     -- couldn't reach the model endpoint at all; skips,
                       doesn't count for or against the run.

Exits 1 only on WRONG-ANSWER. Exits 0 (with a SKIP note) on
UNREACHABLE or GENERATION-FAILED.

Usage:
    python3 tests/test_text_to_sql_shadow.py
    (reasoning config comes from whatever mariadbd was started with --
     see build_test.sh's mdb_setup for the FRACTALSQL_* export pattern,
     pointed at a real endpoint like
     http://192.168.x.x:11434/v1/chat/completions instead of the mock)
"""
import sys

from _t2s_common import connect_or_skip, reasoning_available, to_str

SCHEMA_SQL = """
    CREATE TABLE _t2s_shadow_orders (
        id          BIGINT PRIMARY KEY AUTO_INCREMENT,
        customer    VARCHAR(64) NOT NULL,
        product     VARCHAR(64) NOT NULL,
        qty         INT NOT NULL,
        status      VARCHAR(16) NOT NULL
    )
"""
SEED_ROWS = [
    ("acme", "widget", 5, "paid"),
    ("acme", "widget", 3, "paid"),
    ("acme", "gadget", 1, "refunded"),
    ("globex", "widget", 2, "paid"),
    ("globex", "gizmo", 7, "paid"),
    ("initech", "gadget", 4, "paid"),
    ("initech", "gadget", 1, "paid"),
]

QUESTION = (
    "For each customer, show the total quantity of 'paid' orders, but "
    "only include customers who have more than one distinct product "
    "among their paid orders."
)

# Ground truth, computed directly -- customers with >1 distinct
# product among 'paid' rows only: acme (widget only among paid -- gadget
# row is refunded, so acme has only 1 distinct paid product, EXCLUDED),
# globex (widget + gizmo, both paid -- 2 distinct products, INCLUDED,
# qty 2+7=9), initech (gadget only, 1 distinct product, EXCLUDED).
# This is the "HAVING-shaped exclusion" -- naive SQL that groups by
# customer over ALL rows (not just 'paid') would wrongly include acme.
GROUND_TRUTH = {"globex": 9}


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    if not reasoning_available():
        print("SKIP: reasoning plugin not found on this host")
        return 0

    cur = conn.cursor()
    cur.execute("DROP TABLE IF EXISTS _t2s_shadow_orders")
    cur.execute(SCHEMA_SQL)
    cur.executemany(
        "INSERT INTO _t2s_shadow_orders (customer, product, qty, status) VALUES (?, ?, ?, ?)",
        SEED_ROWS)

    try:
        cur.execute(
            "CALL fractal_text_to_sql(?, ?, @s, @e)",
            (QUESTION, '["_t2s_shadow_orders"]'))
        cur.execute("SELECT @s, @e")
        sql, err = cur.fetchone()
        sql, err = to_str(sql), to_str(err)
    except Exception as e:
        print(f"SKIP: UNREACHABLE -- fractal_text_to_sql call failed: {e}")
        cur.execute("DROP TABLE IF EXISTS _t2s_shadow_orders")
        return 0

    if sql is None:
        print(f"SKIP: GENERATION-FAILED -- pipeline did not return SQL "
              f"(out_error={err!r})")
        cur.execute("DROP TABLE IF EXISTS _t2s_shadow_orders")
        return 0

    print(f"Generated SQL:\n{sql}\n")

    try:
        cur.execute(sql)
        rows = cur.fetchall()
    except Exception as e:
        cur.execute("DROP TABLE IF EXISTS _t2s_shadow_orders")
        fail(f"WRONG-ANSWER (or worse) -- generated SQL passed the pipeline's "
             f"own EXPLAIN-equivalent check but failed to actually execute: {e}\n"
             f"SQL was:\n{sql}")

    got = {}
    for row in rows:
        # Tolerate either (customer, total) or (customer, total, ...)
        # column ordering/naming -- the point is the VALUE, not the
        # LLM's chosen column alias.
        if len(row) < 2:
            continue
        got[to_str(row[0])] = float(row[1])

    if got != {k: float(v) for k, v in GROUND_TRUTH.items()}:
        cur.execute("DROP TABLE IF EXISTS _t2s_shadow_orders")
        fail(f"WRONG-ANSWER -- pipeline returned SQL that executes but doesn't "
             f"match ground truth.\nExpected: {GROUND_TRUTH!r}\nGot: {got!r}\n"
             f"SQL was:\n{sql}")

    cur.execute("DROP TABLE IF EXISTS _t2s_shadow_orders")
    print(f"OK: PASS -- generated SQL matches ground truth {GROUND_TRUTH!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
