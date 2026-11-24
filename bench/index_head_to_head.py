#!/usr/bin/env python3
"""
bench/index_head_to_head.py -- the native IVF index (fractal_index_create
+ the indexed fractal_search) against an exact scan, on this host.

Contestants, all on the same table:
  exact       fractal_search with {"use_index":false} (the brute-force
              scan, the ground truth)
  index       fractal_search over an index, for each vector_format, at a
              fixed nprobe and at every cell

For every contestant it reports recall@10 against the exact top-10, the
median latency per query, the build seconds and the ROWS SCANNED (the
"index actually used" check: far below the table's row count). The
distances the index returns are exact: every candidate is verified
against the base table with the shared double-precision cosine.

The index needs a core that carries the IVF maths. When the vendored
archive predates it, every index call reports "this build of
fractalsql-core does not carry the IVF index (rebuild the core and
refresh include/<platform>)" and this script says so and exits 0.

Usage:
    python3 bench/index_head_to_head.py [--host 127.0.0.1] [--port 3306]
        [--db fractalsql_bench] [--n 20000] [--dim 128] [--clusters 50]
        [--queries 60] [--formats INT8,INT4,FP16,FP32] [--embeddings FILE.npy]
"""
import argparse
import json
import os
import statistics
import sys
import time

import numpy as np

try:
    import mariadb
except ImportError:
    print("SKIP: mariadb connector (pip install mariadb) not installed")
    sys.exit(0)


def vtxt(v):
    f = np.asarray(v, dtype="<f4")
    return "[" + ",".join(repr(float(x)) for x in f) + "]"


def call(cur, sql, params=()):
    """CALL a stored procedure and drain its result set, so the next
    statement is not left out of sync."""
    cur.execute(sql, params)
    try:
        cur.fetchall()
    except Exception:
        pass


def out(cur, var):
    cur.execute("SELECT @" + var)
    row = cur.fetchone()
    return row[0] if row else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("FRACTALSQL_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("FRACTALSQL_PORT", "3306")))
    ap.add_argument("--db", default=os.environ.get("FRACTALSQL_DB", "fractalsql_bench"))
    ap.add_argument("--user", default=os.environ.get("FRACTALSQL_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("FRACTALSQL_PASSWORD", ""))
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--dim", type=int, default=128)
    ap.add_argument("--clusters", type=int, default=50)
    ap.add_argument("--queries", type=int, default=60)
    ap.add_argument("--formats", default="INT8,INT4,FP16,FP32")
    ap.add_argument("--embeddings")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--k", type=int, default=10)
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    if a.embeddings:
        X = np.load(a.embeddings).astype(np.float32)
    else:
        cent = rng.standard_normal((a.clusters, a.dim))
        X = (cent[rng.integers(0, a.clusters, a.n)] + 0.25 * rng.standard_normal((a.n, a.dim))).astype(np.float32)
    n, d = X.shape

    try:
        conn = mariadb.connect(host=a.host, port=a.port, user=a.user, password=a.password, database=a.db)
        conn.autocommit = True
    except Exception as e:
        print("SKIP: no DB reachable at %s:%d: %s" % (a.host, a.port, e))
        return 0
    cur = conn.cursor()

    cur.execute("DROP TABLE IF EXISTS fsq_idx_bench")
    cur.execute("CREATE TABLE fsq_idx_bench (id BIGINT PRIMARY KEY, emb TEXT NOT NULL)")
    for i in range(n):
        cur.execute("INSERT INTO fsq_idx_bench VALUES (%s, %s)", (i + 1, vtxt(X[i])))
    qi = rng.choice(n, size=min(a.queries, n), replace=False)
    Q = [X[i] for i in qi]
    print("rows %d dim %d queries %d, recall@%d against the exact top-%d" % (n, d, len(Q), a.k, a.k))

    def run(opts, label):
        lat = []
        res = []
        stats = None
        for q in Q:
            t0 = time.perf_counter()
            call(cur, "CALL fractal_search('fsq_idx_bench', 'emb', %s, %s, %s, @r, @s)",
                 (vtxt(q), a.k + 1, json.dumps(opts)))
            r = json.loads(out(cur, "r") or "[]")
            s = json.loads(out(cur, "s") or "{}")
            lat.append((time.perf_counter() - t0) * 1000)
            res.append([int(x["doc_id"]) for x in r])
            stats = s
        return res, statistics.median(lat), (stats or {})

    truth, lat_exact, st_exact = run({"use_index": False}, "exact")
    truth = [r[:a.k] for r in truth]

    def recall(res):
        return sum(len(set(r[:a.k]) & set(truth[j])) for j, r in enumerate(res)) / (a.k * len(res))

    print("%-28s recall %.3f  median %7.2f ms  rows scanned %9d"
          % ("exact (full scan)", 1.0, lat_exact, st_exact.get("rows_scanned", n)))

    for fmt in [f.strip().upper() for f in a.formats.split(",")]:
        t0 = time.time()
        call(cur, "CALL fractal_index_create('fsq_idx_bench', 'emb', %s, @r)",
             (json.dumps({"vector_format": fmt, "name": "ix_" + fmt}),))
        created = out(cur, "r")
        build = time.time() - t0
        if isinstance(created, str) and "does not carry the IVF index" in created:
            print("%s: the core does not carry the IVF index (rebuild it and refresh include/<platform>)" % fmt)
            return 0
        info = json.loads(created)
        print("%s: nlist %d pca_dim %d, code %d bytes/row, build %.1fs"
              % (fmt, info["nlist"], info["pca_dim"], info["code_bytes"], build))
        for label, nprobe in (("nprobe 4", 4), ("nprobe 16", 16), ("every cell", info["nlist"])):
            opts = {"index": "ix_" + fmt, "nprobe": nprobe}
            res, lat, st = run(opts, label)
            print("   %-24s recall %.3f  median %7.2f ms  rows scanned %9d (used_index=%s)"
                  % (label, recall(res), lat, st.get("rows_scanned", -1), st.get("used_index")))
        call(cur, "CALL fractal_index_drop(%s, @ok)", ("ix_" + fmt,))

    cur.execute("DROP TABLE IF EXISTS fsq_idx_bench")
    return 0


if __name__ == "__main__":
    sys.exit(main())
