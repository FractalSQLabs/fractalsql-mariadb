#!/usr/bin/env python3
"""
benchmark/head_to_head.py: native VECTOR(n) index vs FractalSQL Scout Mode.

MariaDB port of fractalsql-postgresql's bench/head_to_head.py (there:
pgvector's HNSW index vs. `fractal_search_explore`). This repo's own
native ANN index is MariaDB's own built-in VECTOR(n) column type + its
VECTOR INDEX (GA 11.7+) -- see benchmark/data_gen.py --with-native-vector.
Scout Mode here is `fractal_explore(corpus, query, params)`, this
repo's port of `fractal_search_explore` -- see that file's docstring
for why it takes the corpus as one inline client-supplied string
(no SPI / table-returning UDFs in MariaDB's C UDF ABI) rather than
scanning bench_vectors server-side, and why this means --n has to stay
modest here specifically (this script pulls the WHOLE bench_vectors.emb_txt
column into the client and re-sends it as a query parameter on every
Scout call).

Metrics
    Latency       Wall time per search, milliseconds.
    Island recall Distinct clusters (of K Gaussian islands) represented
                  in the returned point set. A cluster is "discovered" if
                  at least one returned coordinate is nearest to that
                  cluster's center.

Evaluation is symmetric: for BOTH methods we take the returned coords
and map each one to its nearest cluster center, same rule fractalsql-
postgresql's own head_to_head.py uses, ported unchanged (this part has
nothing to do with the SQL engine).

Requires bench_vectors.emb_vec (data_gen.py --with-native-vector) for
the native-index arm; self-skips that arm (prints a note, still runs
the Scout-only numbers) if the column/index isn't present or the
server predates MariaDB 11.7.

Usage:
    python3 benchmark/head_to_head.py --host 127.0.0.1 \\
        --n-queries 5 --top-k 50 --sfs-iter 8
"""

import argparse
import json
import sys
import time
from contextlib import contextmanager

import numpy as np

try:
    import mariadb
except ImportError:
    print("SKIP: mariadb connector (pip install mariadb) not installed")
    sys.exit(0)


@contextmanager
def timed():
    t0 = time.perf_counter()
    yield lambda: (time.perf_counter() - t0) * 1000.0


def nearest_cluster(points: np.ndarray, centers: np.ndarray) -> np.ndarray:
    pn = (points  * points ).sum(axis=1, keepdims=True)
    cn = (centers * centers).sum(axis=1, keepdims=True).T
    ab = points @ centers.T
    d2 = pn + cn - 2.0 * ab
    return np.argmin(d2, axis=1)


def parse_vec(raw):
    return [float(x) for x in raw.strip("[]").split(",")]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="")
    ap.add_argument("--database", default="fractalsql_bench")
    ap.add_argument("--n-queries", type=int, default=5,
                    help="number of queries to average over (default: %(default)s)")
    ap.add_argument("--top-k", type=int, default=50,
                    help="#returned points per method; also SFS population_size "
                         "(default: %(default)s)")
    ap.add_argument("--sfs-iter", type=int, default=8,
                    help="SFS generations (default: %(default)s)")
    ap.add_argument("--sfs-mdn", type=int, default=2,
                    help="SFS diffusion factor (default: %(default)s)")
    ap.add_argument("--seed", type=int, default=1,
                    help="RNG seed for query selection (default: %(default)s)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only the final averages line (for sweep drivers)")
    args = ap.parse_args()

    conn = mariadb.connect(host=args.host, port=args.port, user=args.user,
                           password=args.password, database=args.database,
                           autocommit=True)
    cur = conn.cursor()

    cur.execute("SELECT cluster_id, center_txt FROM bench_centers ORDER BY cluster_id")
    rows = cur.fetchall()
    centers = np.array([parse_vec(r[1]) for r in rows], dtype=np.float64)
    K, dim = centers.shape

    cur.execute("SELECT COUNT(*) FROM bench_vectors")
    n_total = cur.fetchone()[0]

    cur.execute("SELECT COUNT(*) FROM information_schema.columns "
               "WHERE table_schema = DATABASE() AND table_name = 'bench_vectors' "
               "AND column_name = 'emb_vec'")
    has_native = cur.fetchone()[0] == 1

    if not args.quiet:
        print(f"Benchmark: {n_total} stored vectors, {K} clusters, dim={dim}")
        print(f"  Native VECTOR(n) index: {'available' if has_native else 'NOT AVAILABLE '
              '(run data_gen.py --with-native-vector on MariaDB 11.7+)'}, LIMIT {args.top_k}")
        print(f"  Scout (fractal_explore): population={args.top_k}, "
              f"iterations={args.sfs_iter}, mdn={args.sfs_mdn}, walk=0.0 "
              f"(brute-force relevance scan + MMR)")
        print()

    if not has_native and not args.quiet:
        print("NOTE: no native VECTOR(n) index arm this run -- printing Scout "
              "Mode numbers only.\n")

    # Pull the WHOLE corpus once (Scout Mode's inline-corpus constraint,
    # see this file's own docstring) -- reused across all queries.
    cur.execute("SELECT emb_txt FROM bench_vectors ORDER BY id")
    corpus_json = "[" + ",".join(r[0] for r in cur.fetchall()) + "]"

    rng = np.random.default_rng(args.seed)
    qci     = rng.integers(0, K, size=args.n_queries)
    queries = centers[qci] + rng.normal(0.0, 0.02, (args.n_queries, dim))
    queries = np.clip(queries, -1.0, 1.0)

    hdr = ("qi  anchor      |     Native ms   Native recall  |"
           "     Scout ms   Scout recall")
    if not args.quiet:
        print(hdr)
        print("-" * len(hdr))

    native_ms_list, native_recall_list = [], []
    sfs_ms_list,    sfs_recall_list    = [], []

    for qi in range(args.n_queries):
        q_anchor = int(qci[qi])
        q = queries[qi]
        q_txt = "[" + ",".join(f"{x:.6f}" for x in q) + "]"

        if has_native:
            with timed() as clk:
                cur.execute(
                    "SELECT emb_txt FROM bench_vectors "
                    "ORDER BY VEC_DISTANCE_EUCLIDEAN(emb_vec, VEC_FROMTEXT(?)) "
                    "LIMIT ?",
                    (q_txt, args.top_k))
                rows = cur.fetchall()
            native_ms = clk()
            native_pts = np.array([parse_vec(r[0]) for r in rows], dtype=np.float64)
            native_clusters = len(set(nearest_cluster(native_pts, centers).tolist()))
            native_ms_list.append(native_ms)
            native_recall_list.append(native_clusters)
        else:
            native_ms, native_clusters = float("nan"), 0

        opts = json.dumps({
            "population_size":  int(args.top_k),
            "iterations":       int(args.sfs_iter),
            "diffusion_factor": int(args.sfs_mdn),
            "walk":             0.0,
        })
        with timed() as clk:
            cur.execute("SELECT fractal_explore(?, ?, ?)", (corpus_json, q_txt, opts))
            result = json.loads(cur.fetchone()[0])
        sfs_ms = clk()
        sfs_pts = np.array(result["population"], dtype=np.float64)
        sfs_clusters = len(set(nearest_cluster(sfs_pts, centers).tolist()))

        sfs_ms_list.append(sfs_ms); sfs_recall_list.append(sfs_clusters)

        if not args.quiet:
            native_str = f"{native_ms:10.1f}   {native_clusters:4d} / {K}    " if has_native \
                else "       n/a          n/a    "
            print(f"{qi:2d}  cluster {q_anchor:3d} | {native_str} | "
                  f"{sfs_ms:10.1f}   {sfs_clusters:4d} / {K}")

    if not args.quiet:
        print()
        print("Averages over", args.n_queries, "queries:")
        if has_native:
            lat_ratio = np.mean(sfs_ms_list) / max(np.mean(native_ms_list), 1e-9)
            rec_ratio = np.mean(sfs_recall_list) / max(np.mean(native_recall_list), 1e-9)
            print(f"  Native: {np.mean(native_ms_list):>7.1f} ms   "
                  f"recall {np.mean(native_recall_list):>4.1f} / {K}")
            print(f"  Scout:  {np.mean(sfs_ms_list):>7.1f} ms   "
                  f"recall {np.mean(sfs_recall_list):>4.1f} / {K}")
            print(f"  Scout is {lat_ratio:.1f}x slower and discovers "
                  f"{rec_ratio:.1f}x more distinct clusters")
        else:
            print(f"  Scout:  {np.mean(sfs_ms_list):>7.1f} ms   "
                  f"recall {np.mean(sfs_recall_list):>4.1f} / {K}")
    else:
        native_str = f"Native={np.mean(native_ms_list):7.2f}ms/{np.mean(native_recall_list):4.1f}  " \
            if has_native else "Native=n/a  "
        print(f"n={n_total:<7d} {native_str}"
              f"Scout={np.mean(sfs_ms_list):7.2f}ms/{np.mean(sfs_recall_list):4.1f}")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
