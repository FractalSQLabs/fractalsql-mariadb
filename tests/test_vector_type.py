#!/usr/bin/env python3
"""tests/test_vector_type.py: MariaDB's NATIVE VECTOR(n) column type
(11.7+, GA in 11.8 LTS) interop with this repo's portable fractal_vector
JSON-array-string convention.

Structurally very different from fractalsql-postgresql's own
test_vector_type.py, which exercises a custom `fractal_vector` SQL
type this extension itself defines (typmod dimension enforcement,
custom binary I/O, custom `<->`/`<=>` operators). MariaDB has no
CREATE TYPE / typmod mechanism at all -- there is no custom type here.
What MariaDB DOES have, from 11.7 on, is its OWN built-in VECTOR(n)
column type + VEC_FROMTEXT()/VEC_TOTEXT()/VEC_DISTANCE_COSINE()/
VEC_DISTANCE_EUCLIDEAN() builtins, which this repo's fractal_vector_*
functions interoperate with via a shared bracket-comma text grammar
(verified, not assumed -- see sql/install_udf.sql's own comment near
CREATE FUNCTION fractal_vector_dims, and this file's own scenarios
below, each independently confirmed against a live mariadb:12.2
container before being written). Below 11.7, none of this exists;
every fractal_vector_* function still works unchanged on the portable
TEXT/JSON-string path (covered by build_test.sh's gate 22, not here).

Scenarios:
  1. Native round trip: VEC_FROMTEXT(fractal_vector_normalize(...)) into
     a VECTOR(n) column, VEC_TOTEXT() back out, matches the portable
     path's own output.
  2. Cross-path distance agreement: VEC_DISTANCE_COSINE() on the native
     column vs. fractal_vector_cosine_distance() on VEC_TOTEXT() of the
     same column agree (both paths, same underlying float32 storage).
  3. Native dimension enforcement: MariaDB itself (not this repo's SQL)
     rejects an INSERT whose vector literal doesn't match the column's
     declared VECTOR(n) width -- no code in this repo has to detect
     this, unlike postgres's typmod-based fractal_vector.
  4. Vectorizer auto-detection: fractal_vectorizer_create() against a
     VECTOR(n) embedding_col sets fractal_vectorizers.embedding_is_
     vector_type, and fractal_vectorizer_process_queue() writes back
     through VEC_FROMTEXT() automatically -- exercised end-to-end
     against the mock embeddings endpoint, not just asserting the flag.

Skip-safe: exits 0 with SKIP if the mariadb connector is missing, no DB
is reachable, or VECTOR(n) isn't supported by the connected server
(below 11.7 -- detected by attempting a throwaway VECTOR(1) column,
not by parsing VERSION() text, since that's what actually matters).
Scenario 4 additionally skips (not fails) if the reasoning plugin
isn't present on this host.

Usage:
    python3 tests/test_vector_type.py
"""
import os
import sys

from _t2s_common import connect_or_skip, reasoning_available, to_str, MutableMockLLMServer


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def native_vector_supported(cur):
    try:
        cur.execute("DROP TABLE IF EXISTS _fv_probe")
        cur.execute("CREATE TABLE _fv_probe (v VECTOR(1) NOT NULL)")
        cur.execute("DROP TABLE _fv_probe")
        return True
    except Exception:
        return False


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    cur = conn.cursor()
    if not native_vector_supported(cur):
        print("SKIP: connected server has no native VECTOR(n) support "
              "(MariaDB < 11.7) -- fractal_vector_* still works unchanged "
              "on the portable TEXT/JSON path, see build_test.sh gate 22")
        return 0

    passed = 0

    # ---- Scenario 1: native round trip vs. the portable path --------
    cur.execute("DROP TABLE IF EXISTS _fv_native")
    cur.execute("CREATE TABLE _fv_native (id INT PRIMARY KEY, embedding VECTOR(3) NOT NULL)")
    cur.execute(
        "INSERT INTO _fv_native VALUES (1, VEC_FROMTEXT(fractal_vector_normalize('[3,4,0]')))")
    cur.execute("SELECT VEC_TOTEXT(embedding) FROM _fv_native WHERE id = 1")
    native_text = to_str(cur.fetchone()[0])
    cur.execute("SELECT fractal_vector_normalize('[3,4,0]')")
    portable_text = to_str(cur.fetchone()[0])
    native_vals = [float(x) for x in native_text.strip("[]").split(",")]
    portable_vals = [float(x) for x in portable_text.strip("[]").split(",")]
    if len(native_vals) != 3 or any(abs(a - b) > 1e-3 for a, b in zip(native_vals, portable_vals)):
        fail(f"[native round trip] native={native_vals!r} != portable={portable_vals!r}")
    print(f"OK: [native round trip] VEC_FROMTEXT/VEC_TOTEXT matches the portable "
          f"path: {native_vals!r}")
    passed += 1

    # ---- Scenario 2: cross-path distance agreement ------------------
    cur.execute(
        "SELECT VEC_DISTANCE_COSINE(embedding, VEC_FROMTEXT('[1,0,0]')) FROM _fv_native WHERE id = 1")
    native_dist = float(cur.fetchone()[0])
    cur.execute(
        "SELECT fractal_vector_cosine_distance(VEC_TOTEXT(embedding), '[1,0,0]') "
        "FROM _fv_native WHERE id = 1")
    portable_dist = float(cur.fetchone()[0])
    if abs(native_dist - portable_dist) > 1e-3:
        fail(f"[cross-path distance] VEC_DISTANCE_COSINE={native_dist} != "
             f"fractal_vector_cosine_distance={portable_dist}")
    print(f"OK: [cross-path distance] native={native_dist:.6f} == "
          f"portable={portable_dist:.6f}")
    passed += 1
    cur.execute("DROP TABLE IF EXISTS _fv_native")

    # ---- Scenario 3: native dimension enforcement --------------------
    cur.execute("DROP TABLE IF EXISTS _fv_dim")
    cur.execute("CREATE TABLE _fv_dim (id INT PRIMARY KEY, embedding VECTOR(3) NOT NULL)")
    try:
        cur.execute("INSERT INTO _fv_dim VALUES (1, VEC_FROMTEXT('[1,2]'))")
        cur.execute("DROP TABLE IF EXISTS _fv_dim")
        fail("[dimension enforcement] expected MariaDB to reject a dim-2 "
             "literal into a VECTOR(3) column, insert succeeded")
    except Exception as e:
        print(f"OK: [dimension enforcement] MariaDB itself rejected the "
              f"mismatched insert: {e}")
        passed += 1
    cur.execute("DROP TABLE IF EXISTS _fv_dim")

    # ---- Scenario 4: vectorizer auto-detects a native VECTOR(n) col -
    if not reasoning_available():
        print("SKIP: [vectorizer auto-detect] reasoning plugin not found on this host")
    else:
        mock_port = int(os.environ.get("FRACTALSQL_MOCK_PORT", "18080"))
        vec = [0.1, 0.2, 0.3]
        try:
            with MutableMockLLMServer(mock_port) as mock:
                mock.set_embed_vector(vec)
                cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_fv_vec_auto'")
                cur.execute("DROP TABLE IF EXISTS _fv_vec_auto")
                cur.execute("""
                    CREATE TABLE _fv_vec_auto (
                        id BIGINT PRIMARY KEY AUTO_INCREMENT,
                        body TEXT NOT NULL,
                        embedding VECTOR(3)
                    )
                """)
                cur.execute("INSERT INTO _fv_vec_auto (body) VALUES ('a')")
                cur.execute(
                    "CALL fractal_vectorizer_create('_fv_vec_auto', 'body', 'embedding', NULL, @vzid)")
                cur.execute("SELECT @vzid")
                vzid = cur.fetchone()[0]

                cur.execute(
                    "SELECT embedding_is_vector_type FROM fractal_vectorizers WHERE id = ?",
                    (vzid,))
                is_vec = cur.fetchone()[0]
                if not is_vec:
                    fail("[vectorizer auto-detect] embedding_is_vector_type was not "
                         "set TRUE for a VECTOR(3) embedding_col")

                cur.execute("CALL fractal_vectorizer_process_queue(100, 600)")
                n = cur.fetchone()[0]
                if n != 1:
                    fail(f"[vectorizer auto-detect] expected 1 row processed, got {n}")

                cur.execute("SELECT VEC_TOTEXT(embedding) FROM _fv_vec_auto WHERE id = 1")
                got_text = to_str(cur.fetchone()[0])
                got = [float(x) for x in got_text.strip("[]").split(",")]
                if any(abs(a - b) > 1e-3 for a, b in zip(got, vec)):
                    fail(f"[vectorizer auto-detect] wrote back {got!r}, expected {vec!r}")

                print(f"OK: [vectorizer auto-detect] embedding_is_vector_type set "
                      f"automatically, process_queue wrote back through VEC_FROMTEXT() "
                      f"correctly: {got!r}")
                passed += 1

                cur.execute("DELETE FROM fractal_vectorizers WHERE source_table = '_fv_vec_auto'")
                cur.execute("DROP TABLE IF EXISTS _fv_vec_auto")
        except OSError as e:
            print(f"SKIP: [vectorizer auto-detect] could not bind mock port "
                  f"{mock_port}: {e}")

    print(f"\ntest_vector_type: PASS ({passed} scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
