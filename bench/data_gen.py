#!/usr/bin/env python3
"""
bench/data_gen.py: Generate the synthetic "Island" dataset for the
head-to-head benchmark.

Creates N
points in d dimensions, organized into K Gaussian clusters. Cluster
centers are placed uniformly in [-1, 1]^d; each point is sampled from a
Gaussian around its assigned center with per-component std=sigma.
Values are clipped to [-1, 1] so they fall within FractalSQL's default
search bounds.

Writes two tables:
    bench_vectors (id INT PK, cluster_id INT, emb_txt TEXT
                   [, emb_vec VECTOR(d) if --with-native-vector])
    bench_centers (cluster_id INT PK, center_txt TEXT)

emb_txt is this repo's portable fractal_vector convention (a JSON-
array-string, "[1.23,4.56,...]") -- works unchanged on every MariaDB
major in the 10.6-12.3 compat floor this repo targets. --with-native-
vector additionally adds emb_vec VECTOR(d), MariaDB's own built-in
type (GA 11.7+ only -- self-detected, see native_vector_supported()
below, same technique tests/test_vector_type.py already uses), and a
VECTOR INDEX on it -- this repo's actual ANN-index comparison arm, the
ANN index under test here. Default off so the base
head_to_head.py run (Scout Mode vs. brute-force distance-sort) is
unaffected on majors without native VECTOR(n) support.

MariaDB has no way to define a custom `fractal_vector` SQL type at all
(no CREATE TYPE / type-modifier mechanism exists here) -- the
only two vector storage shapes that exist here are the portable TEXT/
JSON-string convention and MariaDB's own native VECTOR(n), which is
why this file's flag is --with-native-vector, not --with-fractal-vector.

No bulk COPY in MariaDB -- loads via batched multi-row INSERT instead
(executemany with a tuned batch size), the standard MariaDB bulk-load
idiom.

Usage:
    python3 bench/data_gen.py --host 127.0.0.1 --port 3306 \\
        --n 5000 --dim 128 --clusters 50

Defaults: 5000 points, dim=128, 50 clusters -- MUCH smaller than the
100k/dim=768 scale a large-corpus ANN benchmark would use. See
bench/README.md's "Why such a small default N" section:
fractal_explore() (this repo's Scout Mode UDF) takes its ENTIRE corpus
as one client-supplied inline string argument (MariaDB's C UDF ABI has
no server-side table access and no table-returning UDFs, so no
server-side table scan is possible for it at all, see sql/
install_udf.sql's own "Scout Mode" comment). At 100k x dim=768 scale
that string would be hundreds of MB, sent over the
wire on every single query, impractical for a benchmark meant to
actually finish. bench/vector_type_head_to_head.py's
OTHER comparisons (storage size, bulk load, the fractal_search_trajectory
family) DO scan server-side via a real table+column and can handle much
larger N if you want to push --n up for those specifically.
"""

import argparse
import sys
import time

import numpy as np

try:
    import mariadb
except ImportError:
    print("SKIP: mariadb connector (pip install mariadb) not installed")
    sys.exit(0)


def native_vector_supported(cur):
    try:
        cur.execute("DROP TABLE IF EXISTS _bench_vec_probe")
        cur.execute("CREATE TABLE _bench_vec_probe (v VECTOR(1) NOT NULL)")
        cur.execute("DROP TABLE _bench_vec_probe")
        return True
    except Exception:
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="")
    ap.add_argument("--database", default="fractalsql_bench")
    ap.add_argument("--n", type=int, default=5_000,
                    help="number of points (default: %(default)s -- see this "
                         "file's own docstring for why the 100k/dim=768 scale a "
                         "large-corpus ANN benchmark would use doesn't port "
                         "directly)")
    ap.add_argument("--dim", type=int, default=128,
                    help="vector dimension (default: %(default)s). Scout Mode's "
                         "fitness cost scales linearly with dim (O(N x D) per "
                         "evaluation) -- keep this modest unless --n is also "
                         "small.")
    ap.add_argument("--clusters", type=int, default=50,
                    help="number of Gaussian clusters (default: %(default)s)")
    ap.add_argument("--sigma", type=float, default=0.05,
                    help="per-component std of intra-cluster noise "
                         "(default: %(default)s)")
    ap.add_argument("--with-native-vector", action="store_true",
                    help="also add an emb_vec VECTOR(dim) column + VECTOR INDEX, "
                         "for the native-index arm of head_to_head.py and for "
                         "vector_type_head_to_head.py (requires MariaDB 11.7+; "
                         "self-skips the column/index, not the whole run, on "
                         "older majors)")
    ap.add_argument("--batch-size", type=int, default=500,
                    help="rows per executemany() batch (default: %(default)s)")
    ap.add_argument("--seed", type=int, default=42,
                    help="RNG seed (default: %(default)s)")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)

    print(f"Generating {args.n} points in R^{args.dim}, "
          f"{args.clusters} clusters, sigma={args.sigma}")
    t0 = time.perf_counter()

    centers = rng.uniform(-1.0, 1.0, (args.clusters, args.dim))
    labels  = rng.integers(0, args.clusters, size=args.n)
    noise   = rng.normal(0.0, args.sigma, (args.n, args.dim))
    vectors = np.clip(centers[labels] + noise, -1.0, 1.0)

    print(f"  generated in {time.perf_counter() - t0:.1f}s "
          f"({vectors.nbytes / 1e6:.1f} MB)")

    print(f"Connecting to {args.host}:{args.port}/{args.database} ...")
    conn = mariadb.connect(host=args.host, port=args.port, user=args.user,
                           password=args.password, database=args.database,
                           autocommit=True)
    cur = conn.cursor()

    has_native = args.with_native_vector and native_vector_supported(cur)
    if args.with_native_vector and not has_native:
        print("  --with-native-vector requested but this server has no "
              "VECTOR(n) support (MariaDB < 11.7) -- proceeding WITHOUT the "
              "native column/index, TEXT-path only")

    cur.execute("DROP TABLE IF EXISTS bench_vectors")
    cur.execute("DROP TABLE IF EXISTS bench_centers")

    vec_col = f",\n            emb_vec    VECTOR({args.dim}) NOT NULL" if has_native else ""
    cur.execute(f"""
        CREATE TABLE bench_vectors (
            id         INT PRIMARY KEY,
            cluster_id INT  NOT NULL,
            emb_txt    TEXT NOT NULL{vec_col}
        )
    """)
    cur.execute("""
        CREATE TABLE bench_centers (
            cluster_id INT PRIMARY KEY,
            center_txt TEXT NOT NULL
        )
    """)

    print(f"  inserting {args.clusters} cluster centers ...")
    cur.executemany(
        "INSERT INTO bench_centers VALUES (?, ?)",
        [(i, "[" + ",".join(f"{x:.6f}" for x in centers[i]) + "]")
         for i in range(args.clusters)])

    print(f"  bulk-loading {args.n} vectors via batched INSERT "
          f"(batch={args.batch_size}) ...")
    t0 = time.perf_counter()
    if has_native:
        sql = "INSERT INTO bench_vectors (id, cluster_id, emb_txt, emb_vec) VALUES (?, ?, ?, VEC_FROMTEXT(?))"
    else:
        sql = "INSERT INTO bench_vectors (id, cluster_id, emb_txt) VALUES (?, ?, ?)"
    batch = []
    for i in range(args.n):
        coords = ",".join(f"{x:.6f}" for x in vectors[i])
        lit = f"[{coords}]"
        row = (i, int(labels[i]), lit, lit) if has_native else (i, int(labels[i]), lit)
        batch.append(row)
        if len(batch) >= args.batch_size:
            cur.executemany(sql, batch)
            batch = []
    if batch:
        cur.executemany(sql, batch)
    print(f"    loaded in {time.perf_counter() - t0:.1f}s")

    if has_native:
        print("  building VECTOR INDEX on emb_vec ...")
        t0 = time.perf_counter()
        cur.execute("ALTER TABLE bench_vectors ADD VECTOR INDEX (emb_vec)")
        print(f"    index built in {time.perf_counter() - t0:.1f}s")

    cur.execute("SELECT COUNT(*) FROM bench_vectors")
    n = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM bench_centers")
    k = cur.fetchone()[0]
    print(f"\nDone. bench_vectors={n} rows, bench_centers={k} rows, "
          f"native_vector={'yes' if has_native else 'no'}")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
