#!/usr/bin/env python3
"""tests/test_text_to_sql_schema_context.py: fractal_schema_context()
edge-case coverage beyond build_test.sh's gate 03 smoke check (table
names, comments, foreign keys, and the nonexistent-table SIGNAL path).

No reasoning plugin / LLM needed -- fractal_schema_context is pure
INFORMATION_SCHEMA introspection (sql/install_udf.sql), unlike its
postgres namesake which formats pg_catalog output.

Skip-safe: exits 0 with a SKIP: message if the mariadb connector is
missing or no DB is reachable.

Usage:
    python3 tests/test_text_to_sql_schema_context.py
"""
import sys

from _t2s_common import connect_or_skip, to_str


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    cur = conn.cursor()
    cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
    cur.execute("""
        CREATE TABLE _t2s_ctx_customers (
            id   BIGINT PRIMARY KEY AUTO_INCREMENT,
            name VARCHAR(100) NOT NULL COMMENT 'Customer full name'
        ) COMMENT='Registered customers'
    """)
    cur.execute("""
        CREATE TABLE _t2s_ctx_orders (
            id          BIGINT PRIMARY KEY AUTO_INCREMENT,
            customer_id BIGINT NOT NULL,
            FOREIGN KEY (customer_id) REFERENCES _t2s_ctx_customers(id)
        )
    """)

    passed = 0

    # ---- all-tables mode (NULL argument) ----
    cur.execute("CALL fractal_schema_context(NULL, @ctx)")
    cur.execute("SELECT @ctx")
    ctx = to_str(cur.fetchone()[0])
    checks = [
        ("_t2s_ctx_customers", "table name present"),
        ("_t2s_ctx_orders", "table name present"),
        ("Registered customers", "table comment present"),
        ("Customer full name", "column comment present"),
    ]
    for needle, label in checks:
        if needle not in ctx:
            cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
            fail(f"schema_context: {label} -- missing {needle!r} in:\n{ctx}")
        print(f"OK: {label}")
        passed += 1
    if "FOREIGN KEY" not in ctx.upper():
        cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
        fail(f"schema_context: foreign key relationship missing in:\n{ctx}")
    print("OK: foreign key present")
    passed += 1

    # ---- filtered mode (explicit table list) ----
    cur.execute('CALL fractal_schema_context(?, @ctx2)', ('["_t2s_ctx_customers"]',))
    cur.execute("SELECT @ctx2")
    ctx2 = to_str(cur.fetchone()[0])
    if "_t2s_ctx_orders" in ctx2:
        cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
        fail("schema_context: filtered call still included an unrequested table")
    if "_t2s_ctx_customers" not in ctx2:
        cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
        fail("schema_context: filtered call dropped the requested table")
    print("OK: filtered (explicit table list) mode scopes correctly")
    passed += 1

    # ---- nonexistent table -> clean SIGNAL, not a crash ----
    try:
        cur.execute('CALL fractal_schema_context(?, @ctx3)', ('["_t2s_ctx_nonexistent"]',))
        cur.fetchall()
        cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
        fail("schema_context: expected a SIGNAL for a nonexistent table, call succeeded")
    except Exception as e:
        if "not found" not in str(e).lower() and "not visible" not in str(e).lower():
            cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
            fail(f"schema_context: expected a 'not found/not visible' SIGNAL, got: {e}")
        print(f"OK: nonexistent table SIGNALs cleanly ({e})")
        passed += 1

    cur.execute("DROP TABLE IF EXISTS _t2s_ctx_orders, _t2s_ctx_customers")
    print(f"OK: {passed}/7 schema_context checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
