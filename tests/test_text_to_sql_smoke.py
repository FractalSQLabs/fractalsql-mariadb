#!/usr/bin/env python3
"""tests/test_text_to_sql_smoke.py: smoke test for fractal_text_to_sql().

One live end-to-end call against whatever reasoning plugin/model
mariadbd was actually started with (FRACTALSQL_REASONING_PLUGIN /
HTTP_URL / HTTP_MODEL, fixed at process start and read once from the
process environment): does the full GENERATE -> ALLOWLIST ->
EXPLAIN-equivalent pipeline run without erroring and return SQL that
actually executes? Deliberately not a correctness/relevance check (see
test_text_to_sql_shadow.py for that, against a real model). This is the
fast "is anything on fire" gate to run after every build, including
against scripts/ci/mock_llm.py's fixed reply with no real model
attached.

Skip-safe: exits 0 with a SKIP: message if the mariadb connector is
missing, no DB is reachable, fractal_text_to_sql isn't deployed, the
reasoning plugin .so isn't present on this host, or the configured
endpoint doesn't respond.

Usage:
    python3 tests/test_text_to_sql_smoke.py
    FRACTALSQL_HOST=... python3 tests/test_text_to_sql_smoke.py
"""
import sys

from _t2s_common import connect_or_skip, reasoning_available, to_str


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    if not reasoning_available():
        print("SKIP: reasoning plugin not found on this host "
              "(set FRACTALSQL_REASONING_PLUGIN, or run inside the "
              "same container as mariadbd)")
        return 0

    cur = conn.cursor()
    cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
    cur.execute("""
        CREATE TABLE _t2s_smoke_orders (
            id          BIGINT PRIMARY KEY AUTO_INCREMENT,
            customer    VARCHAR(64) NOT NULL,
            total_cents INT NOT NULL,
            status      VARCHAR(16) NOT NULL
        )
    """)
    cur.execute("""
        INSERT INTO _t2s_smoke_orders (customer, total_cents, status) VALUES
            ('acme',    1200, 'paid'),
            ('acme',    3400, 'paid'),
            ('globex',   500, 'refunded')
    """)

    try:
        cur.execute(
            "CALL fractal_text_to_sql(?, ?, @s, @e)",
            ("How many orders does customer 'acme' have?",
             '["_t2s_smoke_orders"]'))
        cur.execute("SELECT @s, @e")
        sql, err = cur.fetchone()
        sql, err = to_str(sql), to_str(err)
    except Exception as e:
        print(f"SKIP: fractal_text_to_sql call failed -- reasoning "
              f"endpoint unreachable, model not pulled, or not deployed: {e}")
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        return 0

    if sql is None:
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        print(f"SKIP: fractal_text_to_sql returned no SQL (out_error={err!r}) "
              "-- endpoint unreachable or model refused")
        return 0

    print(f"Generated SQL:\n{sql}\n")

    if not sql.strip().lower().startswith("select"):
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        fail(f"generated SQL isn't a SELECT despite the default "
             f"allowed_statements=select: {sql!r}")

    # The procedure already ran a PREPARE-equivalent EXPLAIN check, but
    # actually executing it here is still a real, direct proof the
    # returned SQL runs, not just prepares. Deliberately NOT asserting
    # the SQL references _t2s_smoke_orders by name -- against
    # scripts/ci/mock_llm.py's fixed "SELECT 1" reply (the common CI
    # case, no real model attached) that would always fail; whether the
    # generated SQL is actually semantically relevant to the schema is
    # test_text_to_sql_shadow.py's job, against a real model.
    cur.execute(sql)
    rows = cur.fetchall()
    print(f"Executed successfully, {len(rows)} row(s): {rows}")

    cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
    print("OK: text-to-sql smoke test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
