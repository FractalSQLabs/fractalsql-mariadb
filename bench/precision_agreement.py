#!/usr/bin/env python3
"""
bench/precision_agreement.py -- the precision-contract agreement metric
for this host's SQL vector functions.

For each dimension it draws unit vectors, computes the cosine distance /
L2 / dot through the extension's SQL functions (fractal_vector_cosine_distance
and friends) and compares them with a float64 reference (numpy) and with
the sequential-double reference the precision contract specifies. It
reports the top-10 agreement, the maximum absolute and relative error
against the float64 reference, and the share of results BIT-identical to
the sequential double reference (1.0000 expected).

The IVF index (fractal_index) is a separate benchmark track: see
index_head_to_head.py.

Usage:
    python3 bench/precision_agreement.py [--host 127.0.0.1] [--port 3306]
        [--db fractalsql_bench] [--dims 128,768,1536] [--n 400] [--queries 20]
        [--embeddings FILE.npy]
"""
import argparse
import json
import math
import os
import struct
import sys

import numpy as np

try:
    import mariadb
except ImportError:
    print("SKIP: mariadb connector (pip install mariadb) not installed")
    sys.exit(0)


def vtxt(v):
    """The canonical vector text this host uses: a JSON array of numbers
    in the shortest float32 round-tripping form."""
    f = np.asarray(v, dtype="<f4")
    return "[" + ",".join(repr(float(x)) for x in f) + "]"


def seq_cos(a, b):
    d = x = y = 0.0
    for p, q in zip(a.tolist(), b.tolist()):
        d += p * q
        x += p * p
        y += q * q
    return 1.0 if x == 0 or y == 0 else 1.0 - d / (math.sqrt(x) * math.sqrt(y))


def run(cur, name, X, Q):
    agree = 0
    exact = tot = 0
    max_abs = max_rel = 0.0
    X64 = X.astype(np.float64)
    for q in Q:
        sql = np.array([cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)",
                                    (vtxt(q), vtxt(x))).fetchone()[0] for x in X], dtype=np.float64)
        q64 = q.astype(np.float64)
        ref64 = 1.0 - (X64 @ q64) / (np.linalg.norm(X64, axis=1) * np.linalg.norm(q64))
        seq = np.array([seq_cos(q, x) for x in X])
        agree += int(list(np.lexsort((np.arange(len(X)), sql))[:10])
                     == list(np.lexsort((np.arange(len(X)), ref64))[:10]))
        err = np.abs(sql - ref64)
        max_abs = max(max_abs, err.max())
        max_rel = max(max_rel, (err / np.maximum(np.abs(ref64), 1e-30)).max())
        exact += int((sql.view(np.uint64) == seq.view(np.uint64)).sum())
        tot += len(X)
    print("%-30s top-10 agreement %3d/%-3d  max abs err %.2e  max rel err %.2e  "
          "bit-identical to the sequential double %.4f"
          % (name, agree, len(Q), max_abs, max_rel, exact / tot))
    return exact == tot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("FRACTALSQL_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("FRACTALSQL_PORT", "3306")))
    ap.add_argument("--db", default=os.environ.get("FRACTALSQL_DB", "fractalsql_bench"))
    ap.add_argument("--user", default=os.environ.get("FRACTALSQL_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("FRACTALSQL_PASSWORD", ""))
    ap.add_argument("--dims", default="128,768,1536")
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--queries", type=int, default=20)
    ap.add_argument("--embeddings")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    try:
        conn = mariadb.connect(host=a.host, port=a.port, user=a.user, password=a.password, database=a.db)
        conn.autocommit = True
    except Exception as e:
        print("SKIP: no DB reachable at %s:%d: %s" % (a.host, a.port, e))
        return 0
    cur = conn.cursor()

    ok = True

    def unit(n, d):
        v = rng.standard_normal((n, d))
        v /= np.linalg.norm(v, axis=1, keepdims=True)
        return v.astype(np.float32)

    for d in [int(x) for x in a.dims.split(",")]:
        ok &= run(cur, "random unit, dim %d" % d, unit(a.n, d), unit(a.queries, d))
    if a.embeddings:
        E = np.load(a.embeddings).astype(np.float32)
        E /= np.linalg.norm(E, axis=1, keepdims=True)
        ok &= run(cur, "real embeddings, dim %d" % E.shape[1], E[a.queries:a.queries + a.n], E[:a.queries])

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
