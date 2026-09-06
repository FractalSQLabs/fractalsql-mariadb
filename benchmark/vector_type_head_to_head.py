#!/usr/bin/env python3
"""
benchmark/vector_type_head_to_head.py: portable TEXT/JSON-string
storage vs. MariaDB's native VECTOR(n) column type, at data_gen.py's
actual scale.

MariaDB port of fractalsql-postgresql's bench/vector_type_head_to_head.py
(there: postgres's custom `fractal_vector` SQL type vs. plain
`float8[]`). There is no MariaDB equivalent of postgres's custom type
at all (no CREATE TYPE / typmod mechanism in MariaDB) -- the two real
storage shapes here are the portable TEXT/JSON-array-string convention
(works on every MariaDB major in the 10.6-12.2 compat floor) and
MariaDB's own built-in VECTOR(n) (GA 11.7+ only). Distinct from
benchmark/head_to_head.py (native-index-vs-Scout-Mode algorithm
comparison, unrelated to storage type). Requires bench_vectors.emb_vec,
i.e. run data_gen.py --with-native-vector first, on an 11.7+ server.

Measures:
  (a) OCTET_LENGTH per row, TEXT vs VECTOR(n), at real scale (MariaDB's
      answer to postgres's pg_column_size -- confirmed empirically this
      session: VECTOR(n) stores exactly 4*dim bytes, no TOAST-style
      compression path either way, so this ratio is architecturally
      fixed, not data-dependent the way postgres's TOAST-compression
      based ratio was; still measured directly rather than assumed).
  (b) Bulk-load throughput for both column types (batched multi-row
      INSERT -- MariaDB has no COPY).
  (c) fractal_search_trajectory query latency, TEXT vs VECTOR(n)
      column -- isolates the VEC_TOTEXT() unpack step's cost at scale.
      fractal_search_trajectory/_cross_modal_search/_telemetry/
      _hybrid_clinical_search all auto-detect a VECTOR(n) vs. TEXT
      vector_col via INFORMATION_SCHEMA (_fractalsql_scan_corpus,
      sql/install_udf.sql) and wrap the native column in VEC_TOTEXT()
      internally, so the SAME procedure call works against either
      column -- just point vector_col at emb_txt or emb_vec.

      *** KNOWN BUG this benchmark works around, found while writing
      it: _fractalsql_scan_corpus builds its corpus via GROUP_CONCAT()
      without raising the session's group_concat_max_len first. Past
      that limit (MariaDB's default is 1MB -- ~870 rows at dim=128,
      far fewer at higher dims or in an older my.cnf with the
      historical 1024-BYTE default), GROUP_CONCAT silently TRUNCATES
      (a warning, not an error) mid-vector, producing invalid JSON
      that fractal_search then silently treats as an empty corpus --
      fractal_search_trajectory/_cross_modal_search/_telemetry/
      _hybrid_clinical_search all return `[]` with NO error surfaced,
      at ANY table size past that limit. Confirmed directly: at 5000
      rows x dim=128 (~6MB of vector text), every one of these
      procedures silently returned zero results until this script's
      own SET SESSION group_concat_max_len below was added. This
      looks like a real bug in sql/install_udf.sql worth fixing
      upstream (raise group_concat_max_len inside
      _fractalsql_scan_corpus itself, or SIGNAL when GROUP_CONCAT's
      own warning fires) -- flagged here, not fixed here (out of
      scope for this benchmark port).
  (d) Peak backend RSS during a full-corpus scan: NOT PORTED, see
      this file's own bench_peak_rss()-equivalent absence and the
      comment where it would have gone. postgres's version reads
      /proc/<backend_pid>/status for the SPECIFIC backend process
      serving the benchmark connection (one OS process per postgres
      connection). MariaDB's threading model is the opposite: ONE
      shared multithreaded mariadbd process serves every connection,
      so there is no per-connection process to isolate an RSS delta
      from. A whole-process RSS reading during
      this benchmark's scan would be contaminated by whatever else
      that shared server is doing for other connections at the same
      moment, and wouldn't isolate the fractal_vector-detoast-loop
      claim it's meant to test the way postgres's per-backend reading
      does. Faking a noisy, non-isolating measurement seemed worse
      than dropping it with this explanation.

Usage:
    python3 benchmark/vector_type_head_to_head.py --host 127.0.0.1
"""

import argparse
import sys
import time

try:
    import mariadb
except ImportError:
    print("SKIP: mariadb connector (pip install mariadb) not installed")
    sys.exit(0)

# See this file's own docstring, sub-benchmark (c) -- works around a
# real GROUP_CONCAT truncation bug in _fractalsql_scan_corpus
# (sql/install_udf.sql) that otherwise silently empties any
# fractal_search_trajectory/_telemetry/_hybrid_clinical_search/
# _cross_modal_search call once the corpus's combined vector-text
# exceeds the session's group_concat_max_len.
SAFE_GROUP_CONCAT_MAX_LEN = 64 * 1024 * 1024


def bench_storage_size(cur, has_native: bool) -> None:
    print("\n-- (a) storage size (OCTET_LENGTH, avg over up to 200 sampled rows) --")
    if has_native:
        cur.execute("""
            SELECT AVG(OCTET_LENGTH(emb_vec)), AVG(OCTET_LENGTH(emb_txt))
            FROM (SELECT emb_vec, emb_txt FROM bench_vectors ORDER BY RAND() LIMIT 200) s
        """)
        vec_avg, txt_avg = cur.fetchone()
        ratio = txt_avg / vec_avg if vec_avg else float("nan")
        print(f"  VECTOR(n)     : {vec_avg:.0f} bytes  (fixed at 4 bytes/dim, float32)")
        print(f"  TEXT (JSON)   : {txt_avg:.0f} bytes")
        print(f"  ratio         : {ratio:.2f}x")
    else:
        cur.execute("SELECT AVG(OCTET_LENGTH(emb_txt)) FROM "
                    "(SELECT emb_txt FROM bench_vectors ORDER BY RAND() LIMIT 200) s")
        txt_avg = cur.fetchone()[0]
        print(f"  TEXT (JSON)   : {txt_avg:.0f} bytes")
        print("  SKIP native VECTOR(n) column -- run data_gen.py --with-native-vector "
              "on an 11.7+ server for the comparison")


def bench_load_throughput(cur, n: int, dim: int, has_native: bool) -> None:
    print(f"\n-- (b) bulk load throughput ({n} rows, dim={dim}, batched INSERT) --")
    import numpy as np
    rng = np.random.default_rng(7)
    vecs = np.clip(rng.normal(0.0, 0.3, (n, dim)), -1.0, 1.0)
    lits = ["[" + ",".join(f"{x:.6f}" for x in vecs[i]) + "]" for i in range(n)]

    arms = [("TEXT", "_bt_copy_txt", "v TEXT", "INSERT INTO _bt_copy_txt VALUES (?, ?)",
             [(i, lits[i]) for i in range(n)])]
    if has_native:
        arms.append(("VECTOR(n)", "_bt_copy_vec", f"v VECTOR({dim})",
                     "INSERT INTO _bt_copy_vec VALUES (?, VEC_FROMTEXT(?))",
                     [(i, lits[i]) for i in range(n)]))

    for label, table, coldef, sql, rows in arms:
        cur.execute(f"DROP TABLE IF EXISTS {table}")
        cur.execute(f"CREATE TABLE {table} (id INT PRIMARY KEY, {coldef})")
        t0 = time.perf_counter()
        batch, batch_size = [], 500
        for row in rows:
            batch.append(row)
            if len(batch) >= batch_size:
                cur.executemany(sql, batch)
                batch = []
        if batch:
            cur.executemany(sql, batch)
        elapsed = time.perf_counter() - t0
        print(f"  {label:10s}: {elapsed:.2f}s ({n / elapsed:.0f} rows/s)")
        cur.execute(f"DROP TABLE {table}")


def bench_search_latency(cur, n_queries: int, has_native: bool) -> None:
    print(f"\n-- (c) fractal_search_trajectory latency: TEXT vs VECTOR(n) column --")
    cur.execute(f"SET SESSION group_concat_max_len = {SAFE_GROUP_CONCAT_MAX_LEN}")
    cur.execute("SELECT emb_txt FROM bench_vectors LIMIT 1")
    baseline = cur.fetchone()[0]

    arms = [("TEXT", "emb_txt")]
    if has_native:
        arms.append(("VECTOR(n)", "emb_vec"))
    else:
        print("  SKIP VECTOR(n) arm -- run data_gen.py --with-native-vector "
              "on an 11.7+ server for the comparison")

    for label, col in arms:
        times = []
        for _ in range(n_queries):
            t0 = time.perf_counter()
            cur.execute(
                "CALL fractal_search_trajectory('bench_vectors', ?, ?, ?, 10, @r)",
                (col, baseline, baseline))
            cur.execute("SELECT @r")
            cur.fetchall()
            times.append((time.perf_counter() - t0) * 1000.0)
        avg = sum(times) / len(times)
        print(f"  {label:10s}: {avg:.1f} ms avg over {n_queries} queries "
              f"(min {min(times):.1f}, max {max(times):.1f})")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="")
    ap.add_argument("--database", default="fractalsql_bench")
    ap.add_argument("--load-n", type=int, default=2_000,
                    help="row count for the bulk-load sub-benchmark "
                         "(default: %(default)s -- smaller than the full "
                         "corpus, this arm is O(n) by design so a subset "
                         "is representative)")
    ap.add_argument("--search-queries", type=int, default=10,
                    help="queries to average for the latency sub-benchmark "
                         "(default: %(default)s)")
    args = ap.parse_args()

    conn = mariadb.connect(host=args.host, port=args.port, user=args.user,
                           password=args.password, database=args.database,
                           autocommit=True)
    cur = conn.cursor()

    cur.execute("SELECT COUNT(*) FROM information_schema.columns "
               "WHERE table_schema = DATABASE() AND table_name = 'bench_vectors' "
               "AND column_name = 'emb_vec'")
    has_native = cur.fetchone()[0] == 1

    cur.execute("SELECT COUNT(*) FROM bench_vectors")
    n_total = cur.fetchone()[0]
    if n_total == 0:
        print("bench_vectors is empty -- run data_gen.py first", file=sys.stderr)
        return 1
    cur.execute("SELECT CHAR_LENGTH(emb_txt) - CHAR_LENGTH(REPLACE(emb_txt, ',', '')) + 1 "
               "FROM bench_vectors LIMIT 1")
    dim = cur.fetchone()[0]
    print(f"vector_type_head_to_head: {n_total} rows, dim={dim}, "
          f"native VECTOR(n)={'yes' if has_native else 'no'}")

    bench_storage_size(cur, has_native)
    bench_load_throughput(cur, args.load_n, dim, has_native)
    bench_search_latency(cur, args.search_queries, has_native)

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
