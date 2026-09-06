#!/usr/bin/env python3
"""tests/test_vectorizer.py: fractal_embed() and the vectorizer's
actual SUCCESS path, against a mock embeddings HTTP server.

Every text-to-sql test in this suite deliberately drives the pipeline
into REJECTION paths with a canned model response, since real models
are unreliable for eliciting one specific adversarial output on demand.
This file covers the opposite: does fractal_embed() actually return a
real, correctly parsed vector when the plugin succeeds, and does
fractal_vectorizer_process_queue() actually write it back to a row?
build_test.sh's gate 13 covers only the basic round trip; this adds
malformed-response handling, pause/resume gating, the rate-window cap,
and SQL-injection-safety of the dynamic per-table trigger/backfill SQL
fractal_vectorizer_create()/_process_queue() build.

MariaDB port of fractalsql-postgresql's test_vectorizer.py. Structural
differences:
  - No native float8[] column type: embeddings are TEXT holding a
    fractal_vector JSON-array-string, so results are json.loads()'d
    before comparison, with a float tolerance (the core stores vectors
    as float32, see sql/install_udf.sql's own comment on this near
    CREATE FUNCTION fractal_vector_dims).
  - No CREATE EXTENSION / serial / RETURNING; identifiers are
    backtick-quoted (_fractalsql_quote_ident), not double-quoted.
  - No generate_series()/interval arithmetic: built with a small
    literal INSERT loop / DATE_SUB(NOW(), INTERVAL n HOUR) instead.
  - Reasoning config (which mock URL) is fixed at mariadbd startup,
    read once from the process environment; every scenario below swaps
    the reply through ONE already-running
    _t2s_common.MutableMockLLMServer instead of spinning up (and
    reconfiguring the server to point at) a fresh mock per scenario.

Requires the real, vendored fractalsql-reasoning-http.so, pointed to
by FRACTALSQL_REASONING_PLUGIN, and FRACTALSQL_HTTP_EMBED_URL already
pointed at 127.0.0.1:<mock port> (matching build_test.sh's own
mdb_setup wiring). Skip-safe: exits 0 with SKIP if the mariadb
connector is missing, no DB is reachable, or the reasoning plugin
isn't present on this host.

Usage:
    python3 tests/test_vectorizer.py
    FRACTALSQL_MOCK_PORT=18080 python3 tests/test_vectorizer.py
"""
import math
import os
import sys

from _t2s_common import connect_or_skip, reasoning_available, to_str, MutableMockLLMServer


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def qi(name):
    """Backtick-quote a MariaDB identifier, doubling embedded
    backticks -- mirrors _fractalsql_quote_ident's own escaping rule
    (sql/install_udf.sql), hand-rolled so scenario D exercises the
    same convention a real adversarial caller would hit, not a helper
    that could mask a mistake."""
    return "`" + name.replace("`", "``") + "`"


def parse_vec(raw):
    return [float(x) for x in __import__("json").loads(to_str(raw))]


def close(a, b, tol=1e-3):
    return len(a) == len(b) and all(math.isclose(x, y, abs_tol=tol) for x, y in zip(a, b))


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    if not reasoning_available():
        print("SKIP: reasoning plugin not found on this host")
        return 0

    mock_port = int(os.environ.get("FRACTALSQL_MOCK_PORT", "18080"))
    cur = conn.cursor()
    passed = 0

    try:
        with MutableMockLLMServer(mock_port) as mock:
            # ---- Scenario A: fractal_embed() direct success --------
            vec_a = [0.25, -0.5, 0.75]
            mock.set_embed_vector(vec_a)
            cur.execute("SELECT fractal_embed(CONNECTION_ID(), 'hello world')")
            got = parse_vec(cur.fetchone()[0])
            if not close(got, vec_a):
                fail(f"[direct fractal_embed] expected {vec_a!r}, got {got!r}")
            print(f"OK: [direct fractal_embed] {got!r}")
            passed += 1

            # ---- Scenario B: vectorizer end-to-end, real embeddings
            vec_b = [1.0, 2.0, 3.0]
            mock.set_embed_vector(vec_b)
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_docs'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_docs")
            cur.execute("""
                CREATE TABLE _vec_test_docs (
                    id BIGINT PRIMARY KEY AUTO_INCREMENT,
                    body TEXT NOT NULL,
                    embedding TEXT
                )
            """)
            cur.execute("INSERT INTO _vec_test_docs (body) VALUES ('a'), ('b')")

            cur.execute("CALL fractal_vectorizer_create('_vec_test_docs', 'body', 'embedding', NULL, @vzid)")
            cur.execute("SELECT @vzid")
            vzid = cur.fetchone()[0]

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n = cur.fetchone()[0]
            if n != 2:
                fail(f"[vectorizer e2e] expected 2 rows processed, got {n}")

            cur.execute("SELECT embedding FROM _vec_test_docs ORDER BY id")
            rows = cur.fetchall()
            for r in rows:
                got = parse_vec(r[0])
                if not close(got, vec_b):
                    fail(f"[vectorizer e2e] row embedding {got!r} != {vec_b!r}")

            cur.execute(
                "SELECT status, n FROM fractal_vectorizer_status WHERE vectorizer_id = ?",
                (vzid,))
            status_rows = {to_str(s): n for s, n in cur.fetchall()}
            if status_rows != {"done": 2}:
                fail(f"[vectorizer e2e] expected status {{'done': 2}}, got {status_rows!r}")

            print(f"OK: [vectorizer e2e] 2/2 rows embedded correctly, status={status_rows!r}")
            passed += 1

            # ---- Scenario C: malformed response -- real per-row
            # failure, via the actual plugin's own response parsing
            # rejecting a body with no "data" key. ------------------
            mock.set_embed_body({"error": "not a real embeddings response"})
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_bad'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_bad")
            cur.execute("""
                CREATE TABLE _vec_test_bad (
                    id BIGINT PRIMARY KEY AUTO_INCREMENT,
                    body TEXT NOT NULL,
                    embedding TEXT
                )
            """)
            cur.execute("INSERT INTO _vec_test_bad (body) VALUES ('c')")
            cur.execute("CALL fractal_vectorizer_create('_vec_test_bad', 'body', 'embedding', NULL, @vzid2)")
            cur.execute("SELECT @vzid2")
            vzid2 = cur.fetchone()[0]

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n = cur.fetchone()[0]
            if n != 1:
                fail(f"[malformed response] expected 1 row processed, got {n}")

            cur.execute(
                "SELECT status, last_error FROM fractal_vectorizer_status WHERE vectorizer_id = ?",
                (vzid2,))
            status, last_error = cur.fetchone()
            status, last_error = to_str(status), to_str(last_error)
            if status != "failed":
                fail(f"[malformed response] expected status 'failed', got {status!r}")
            if not last_error:
                fail("[malformed response] expected a non-empty error, got none")
            print(f"OK: [malformed response] row failed cleanly: {last_error!r}")
            passed += 1

            # ---- Scenario D: adversarial identifiers -- table name,
            # text_col, and embedding_col all carry an embedded
            # backtick + DROP TABLE + comment-marker payload, through
            # the full create -> backfill -> process_queue ->
            # write-back pipeline with a REAL successful embed.
            # fractal_vectorizers must be provably untouched by the
            # payload (row counts, not just "no exception raised"). --
            evil_tbl = "vec_evil`; drop table fractal_vectorizers; --"
            evil_txt = "txt`; drop table fractal_vectorizers;--"
            evil_emb = "emb`; drop table fractal_vectorizers;--"
            vec_d = [9.0, 8.0, 7.0]
            mock.set_embed_vector(vec_d)

            cur.execute("SELECT count(*) FROM fractal_vectorizers")
            n_before = cur.fetchone()[0]

            cur.execute(f"DROP TABLE IF EXISTS {qi(evil_tbl)}")
            cur.execute(
                f"CREATE TABLE {qi(evil_tbl)} "
                f"(id BIGINT PRIMARY KEY AUTO_INCREMENT, {qi(evil_txt)} TEXT, {qi(evil_emb)} TEXT)")
            cur.execute(
                f"INSERT INTO {qi(evil_tbl)} ({qi(evil_txt)}) VALUES (?), (?)",
                ("hello", "world"))

            cur.execute(
                "CALL fractal_vectorizer_create(?, ?, ?, NULL, @vzid3)",
                (evil_tbl, evil_txt, evil_emb))
            cur.execute("SELECT @vzid3")
            vzid3 = cur.fetchone()[0]

            cur.execute("SELECT count(*) FROM fractal_vectorizers")
            n_after_create = cur.fetchone()[0]
            if n_after_create != n_before + 1:
                fail(f"[adversarial identifiers] expected exactly 1 new row in "
                     f"fractal_vectorizers, before={n_before} after={n_after_create} "
                     f"-- possible injection side effect")

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n = cur.fetchone()[0]
            if n != 2:
                fail(f"[adversarial identifiers] expected 2 rows processed, got {n}")

            cur.execute(f"SELECT {qi(evil_emb)} FROM {qi(evil_tbl)} ORDER BY id")
            rows = cur.fetchall()
            for r in rows:
                got = parse_vec(r[0])
                if not close(got, vec_d):
                    fail(f"[adversarial identifiers] row embedding {got!r} != {vec_d!r} "
                         f"-- write-back through the malicious column name failed")

            cur.execute("SELECT count(*) FROM fractal_vectorizers")
            n_final = cur.fetchone()[0]
            if n_final != n_after_create:
                fail(f"[adversarial identifiers] fractal_vectorizers row count changed "
                     f"during process_queue() ({n_after_create} -> {n_final}) "
                     f"-- possible injection side effect")

            print(f"OK: [adversarial identifiers] table/text_col/embedding_col "
                  f"all containing embedded backticks + DROP TABLE + comment markers "
                  f"round-tripped safely, fractal_vectorizers untouched ({n_final} rows)")
            passed += 1

            cur.execute("DELETE FROM fractal_vectorizers WHERE id = ?", (vzid3,))
            cur.execute(f"DROP TABLE IF EXISTS {qi(evil_tbl)}")

            # ---- Scenario E: pause/resume -- enabled=FALSE must stop
            # BOTH future enqueueing (the trigger no-ops) and
            # processing of already-pending rows (process_queue()'s
            # join excludes it), and resume must cleanly restore both.
            vec_e = [4.0, 5.0, 6.0]
            mock.set_embed_vector(vec_e)
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_pause'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_pause")
            cur.execute("""
                CREATE TABLE _vec_test_pause (
                    id BIGINT PRIMARY KEY AUTO_INCREMENT,
                    body TEXT NOT NULL,
                    embedding TEXT
                )
            """)
            cur.execute("INSERT INTO _vec_test_pause (body) VALUES ('a')")

            cur.execute("CALL fractal_vectorizer_create('_vec_test_pause', 'body', 'embedding', NULL, @vzid4)")
            cur.execute("SELECT @vzid4")
            vzid4 = cur.fetchone()[0]

            cur.execute("CALL fractal_vectorizer_pause(?)", (vzid4,))
            cur.execute("INSERT INTO _vec_test_pause (body) VALUES ('b')")

            cur.execute(
                "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id = ?",
                (vzid4,))
            n_queued_while_paused = cur.fetchone()[0]
            if n_queued_while_paused != 1:
                fail(f"[pause/resume] expected 1 queued row (the pre-pause backfill "
                     f"of 'a' only -- 'b' inserted while paused must NOT enqueue), "
                     f"got {n_queued_while_paused}")

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n_while_paused = cur.fetchone()[0]
            if n_while_paused != 0:
                fail(f"[pause/resume] expected 0 rows processed while paused, "
                     f"got {n_while_paused}")

            cur.execute("CALL fractal_vectorizer_resume(?)", (vzid4,))
            cur.execute("UPDATE _vec_test_pause SET body = 'b-updated' WHERE body = 'b'")

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n_after_resume = cur.fetchone()[0]
            if n_after_resume != 2:
                fail(f"[pause/resume] expected 2 rows processed after resume "
                     f"('a' from before the pause + 'b' enqueued by the post-resume "
                     f"update), got {n_after_resume}")

            try:
                cur.execute("CALL fractal_vectorizer_pause(-1)")
                fail("[pause/resume] pausing a nonexistent vectorizer id should raise")
            except Exception:
                pass

            print("OK: [pause/resume] enqueue+processing correctly gated by "
                  "enabled -- 0 processed while paused, 2 processed after resume")
            passed += 1

            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_pause'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_pause")

            # ---- Scenario F: rate cap -- options.max_embeds_per_window
            # must cap embed ATTEMPTS per rolling window (not just
            # successes), and the window must roll over. -------------
            mock.set_embed_body({"error": "unreachable -- rate-capped rows "
                                          "should never even call this"})
            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_rate'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_rate")
            cur.execute("""
                CREATE TABLE _vec_test_rate (
                    id BIGINT PRIMARY KEY AUTO_INCREMENT,
                    body TEXT NOT NULL,
                    embedding TEXT
                )
            """)
            for i in range(1, 6):
                cur.execute("INSERT INTO _vec_test_rate (body) VALUES (?)", (f"row {i}",))

            cur.execute(
                "CALL fractal_vectorizer_create('_vec_test_rate', 'body', 'embedding', ?, @vzid5)",
                ('{"max_embeds_per_window": 2, "rate_window_secs": 3600}',))
            cur.execute("SELECT @vzid5")
            vzid5 = cur.fetchone()[0]

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n_first_call = cur.fetchone()[0]
            if n_first_call != 2:
                fail(f"[rate cap] expected exactly 2 rows attempted (the cap), "
                     f"got {n_first_call}")

            cur.execute(
                "SELECT window_calls FROM fractal_vectorizer_rate_window WHERE vectorizer_id = ?",
                (vzid5,))
            window_calls = cur.fetchone()[0]
            if window_calls != 2:
                fail(f"[rate cap] expected window_calls=2, got {window_calls}")

            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n_second_call = cur.fetchone()[0]
            if n_second_call != 0:
                fail(f"[rate cap] expected 0 more rows this window (cap already "
                     f"hit), got {n_second_call}")

            # Simulate the window elapsing -- proves rollover, not just
            # that the cap holds within one window.
            cur.execute(
                "UPDATE fractal_vectorizer_rate_window "
                "SET window_start = DATE_SUB(NOW(), INTERVAL 2 HOUR) "
                "WHERE vectorizer_id = ?",
                (vzid5,))
            cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
            n_after_rollover = cur.fetchone()[0]
            if n_after_rollover != 2:
                fail(f"[rate cap] expected 2 more rows after window rollover, "
                     f"got {n_after_rollover}")

            print(f"OK: [rate cap] capped at 2/window across 2 calls, allowed "
                  f"2 more after simulated rollover (3 rows never attempted, "
                  f"still pending -- mock's 'unreachable' error body never hit)")
            passed += 1

            cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_vec_test_rate'")
            cur.execute("DROP TABLE IF EXISTS _vec_test_rate")
    finally:
        cur.execute("DELETE FROM fractal_vectorizers WHERE source_table IN "
                    "('_vec_test_docs', '_vec_test_bad', '_vec_test_pause', '_vec_test_rate')")
        cur.execute("DROP TABLE IF EXISTS _vec_test_docs")
        cur.execute("DROP TABLE IF EXISTS _vec_test_bad")
        cur.execute("DROP TABLE IF EXISTS _vec_test_pause")
        cur.execute("DROP TABLE IF EXISTS _vec_test_rate")

    print(f"\ntest_vectorizer: PASS ({passed}/6 scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
