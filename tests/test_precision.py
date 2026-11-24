#!/usr/bin/env python3
"""tests/test_precision.py -- the precision contract of this host's SQL
vector functions (gate 79).

The precision contract (precision plan R2/R3/R5/R7/R8):

  * every SQL-visible distance, norm and dot product accumulates in DOUBLE,
    in a fixed sequential order, with no fused multiply-add and no
    vectorised reduction, and is returned as a double (no rounding to
    float32 on the way out);
  * there is ONE cosine implementation in this repo (src/fsql_precision.h),
    so every SQL-visible cosine agrees to the last bit;
  * the canonical vector text round-trips bit-identically for float32;
  * ties break on the row id.

The reference here is the same arithmetic in Python floats (IEEE double, no
fused multiply-add), so the SQL results must be BIT-identical to it.

Scenarios:
  G1  the cosine distance / similarity, the L2 distance, the norm and the
      negative inner product are bit-identical to the sequential double
      reference, at 128 and 768 dims;
  G1  an adversarial near-tie set: the FULL ranking by the SQL distance
      equals the reference ranking (this is the check that detects a
      float32 accumulator);
  G2  cross-function consistency: the exact fallback of fractal_search and
      the indexed search both return the same bits as
      fractal_vector_cosine_distance;
  G3  the text round trip: vector -> text -> vector is bit-identical;
  degenerate inputs keep their documented conventions (a zero vector, a
  NULL argument, a dimension mismatch).

Skip-safe: exits 0 with SKIP if the mariadb connector is missing or no DB
is reachable.

Usage:
    python3 tests/test_precision.py
"""
import json
import math
import random
import struct
import sys

from _t2s_common import connect_or_skip, to_str

fails = 0


def check(ok, name, detail=""):
    global fails
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok:
        fails += 1


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def bits(x):
    return struct.pack("<d", x)


def vtxt(v):
    """The canonical vector text this host uses: a JSON array of numbers
    printed with the shortest float32 round-tripping form."""
    return "[" + ",".join(repr(f32(t)) for t in v) + "]"


def seq_parts(a, b):
    d = x = y = 0.0
    for p, q in zip(a, b):
        d += p * q
        x += p * p
        y += q * q
    return d, x, y


def ref_cos_dist(a, b):
    d, x, y = seq_parts(a, b)
    return 1.0 if x == 0.0 or y == 0.0 else 1.0 - d / (math.sqrt(x) * math.sqrt(y))


def ref_cos_sim(a, b):
    d, x, y = seq_parts(a, b)
    return 0.0 if x == 0.0 or y == 0.0 else d / (math.sqrt(x) * math.sqrt(y))


def ref_l2(a, b):
    s = 0.0
    for p, q in zip(a, b):
        t = p - q
        s += t * t
    return math.sqrt(s)


def call(cur, sql, params=()):
    """CALL a stored procedure and drain its result set, so the next
    statement is not left out of sync (the same CALL-then-SELECT-@var
    pattern the shell gates use)."""
    cur.execute(sql, params)
    try:
        cur.fetchall()
    except Exception:
        pass


def unit(rng, n):
    v = [rng.gauss(0, 1) for _ in range(n)]
    s = math.sqrt(sum(t * t for t in v))
    return [f32(t / s) for t in v]


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0
    cur = conn.cursor()

    rng = random.Random(7)

    for dim in (128, 768):
        q = unit(rng, dim)
        X = [unit(rng, dim) for _ in range(40)]
        qt, xt = vtxt(q), [vtxt(x) for x in X]

        sql = []
        for t in xt:
            cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)", (qt, t))
            sql.append(float(cur.fetchone()[0]))
        ref = [ref_cos_dist(q, x) for x in X]
        check(all(bits(a) == bits(b) for a, b in zip(sql, ref)),
              "dim %d: the cosine distance is bit-identical to the sequential double reference" % dim)

        order_sql = sorted(range(len(X)), key=lambda i: (sql[i], i))[:10]
        order_ref = sorted(range(len(X)), key=lambda i: (ref[i], i))[:10]
        check(order_sql == order_ref,
              "dim %d: G1 the ordered top-10 by the SQL distance equals the reference top-10" % dim)

        sql = []
        for t in xt:
            cur.execute("SELECT fractal_vector_cosine_similarity(%s, %s)", (qt, t))
            sql.append(float(cur.fetchone()[0]))
        ref = [ref_cos_sim(q, x) for x in X]
        check(all(bits(a) == bits(b) for a, b in zip(sql, ref)),
              "dim %d: the cosine similarity is bit-identical" % dim)

        sql = []
        for t in xt:
            cur.execute("SELECT fractal_vector_l2_distance(%s, %s)", (qt, t))
            sql.append(float(cur.fetchone()[0]))
        ref = [ref_l2(q, x) for x in X]
        check(all(bits(a) == bits(b) for a, b in zip(sql, ref)),
              "dim %d: the L2 distance is bit-identical" % dim)

        dots = []
        for t in xt:
            cur.execute("SELECT fractal_vector_negative_inner_product(%s, %s)", (qt, t))
            dots.append(float(cur.fetchone()[0]))
        ref = [-seq_parts(q, x)[0] for x in X]
        check(all(bits(a) == bits(b) for a, b in zip(dots, ref)),
              "dim %d: the negative inner product is bit-identical (and is -dot)" % dim)

        cur.execute("SELECT fractal_vector_norm(%s)", (qt,))
        n = float(cur.fetchone()[0])
        s = 0.0
        for p in q:
            s += p * p
        check(bits(n) == bits(math.sqrt(s)), "dim %d: the norm is bit-identical" % dim)

    # --- the adversarial near-tie set -----------------------------------
    dim = 256
    base = unit(rng, dim)
    q = unit(rng, dim)
    cand = [[f32(b + (rng.random() - 0.5) * 2e-7) for b in base] for _ in range(120)]
    sql = []
    for c in cand:
        cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)", (vtxt(q), vtxt(c)))
        sql.append(float(cur.fetchone()[0]))
    ref = [ref_cos_dist(q, c) for c in cand]
    check([i for i in sorted(range(len(cand)), key=lambda i: (sql[i], i))]
          == [i for i in sorted(range(len(cand)), key=lambda i: (ref[i], i))],
          "near-tie set: the FULL ranking by the SQL distance equals the reference ranking (G1)")
    check(len(set(ref)) > 90,
          "near-tie set: the candidates really are near-ties (distinct distances within 1e-7)",
          len(set(ref)))

    # --- G2: every SQL-visible cosine path agrees to the last bit -------
    dim = 32
    rows = [unit(rng, dim) for _ in range(24)]
    cur.execute("DROP TABLE IF EXISTS _fp_g2")
    cur.execute("CREATE TABLE _fp_g2 (id INT PRIMARY KEY, emb TEXT)")
    for i, r in enumerate(rows):
        cur.execute("INSERT INTO _fp_g2 VALUES (%s, %s)", (i + 1, vtxt(r)))
    q = unit(rng, dim)
    vec = {}
    for i, r in enumerate(rows):
        cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)", (vtxt(r), vtxt(q)))
        vec[i + 1] = float(cur.fetchone()[0])

    # the exact fallback of the indexed search
    call(cur, "CALL fractal_search('_fp_g2', 'emb', %s, 24, %s, @r, @s)",
         (vtxt(q), json.dumps({"use_index": False})))
    cur.execute("SELECT @r")
    fallback = {int(x["doc_id"]): float(x["dist"]) for x in json.loads(to_str(cur.fetchone()[0]) or "[]")}
    check(len(fallback) == len(vec) and all(bits(vec[k]) == bits(v) for k, v in fallback.items()),
          "G2: the exact fallback of fractal_search equals fractal_vector_cosine_distance bit for bit",
          sorted(fallback.items())[:3])

    # the indexed search (the same bits, when the index is available)
    try:
        call(cur, "CALL fractal_index_create('_fp_g2', 'emb', %s, @r)",
             (json.dumps({"name": "_fp_ix", "vector_format": "FP32"}),))
        cur.execute("SELECT @r")
        created = to_str(cur.fetchone()[0])
        if "does not carry the IVF index" in (created or ""):
            print("  [SKIP] G2: the indexed-search half needs a core that carries the IVF index")
        else:
            call(cur, "CALL fractal_search('_fp_g2', 'emb', %s, 24, %s, @r, @s)",
                 (vtxt(q), json.dumps({"index": "_fp_ix", "nprobe": 64})))
            cur.execute("SELECT @r")
            indexed = {int(x["doc_id"]): float(x["dist"]) for x in json.loads(to_str(cur.fetchone()[0]) or "[]")}
            check(len(indexed) >= len(vec) - 1
                  and all(bits(vec[k]) == bits(v) for k, v in indexed.items() if k in vec),
                  "G2: the verified distances of the indexed search equal fractal_vector_cosine_distance bit for bit",
                  sorted(indexed.items())[:3])
            call(cur, "CALL fractal_index_drop('_fp_ix', @ok)")
    except Exception as e:
        print("  [SKIP] G2: the indexed-search half is unavailable here: %s" % e)

    # --- G3: the text round trip ----------------------------------------
    bad = 0
    for _ in range(50):
        v = [f32(rng.uniform(-1e3, 1e3) * 10 ** rng.randint(-8, 3)) for _ in range(rng.randint(1, 40))]
        cur.execute("SELECT fractal_vector_to_float8_array(%s)", (vtxt(v),))
        back = to_str(cur.fetchone()[0])
        vals = [f32(float(t)) for t in back.strip("[]").split(",")]
        if vals != v:
            bad += 1
    check(bad == 0, "G3: vector -> text -> vector is bit-identical for 50 random float32 vectors", bad)

    # --- degenerate inputs -----------------------------------------------
    z, u = vtxt([0.0] * 8), vtxt([1.0] * 8)
    cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)", (z, u))
    check(float(cur.fetchone()[0]) == 1.0, "a zero vector has cosine distance 1.0 (not NaN)")
    cur.execute("SELECT fractal_vector_cosine_similarity(%s, %s)", (z, u))
    check(float(cur.fetchone()[0]) == 0.0, "a zero vector has cosine similarity 0.0")
    cur.execute("SELECT fractal_vector_cosine_distance(NULL, %s)", (u,))
    check(cur.fetchone()[0] is None, "a NULL argument gives a NULL result")
    # A dimension mismatch is refused. On this host a failing UDF CALL
    # returns NULL (MariaDB's UDF ABI has no error text on the runtime
    # path; the message goes to the daemon's log), so the refusal is a
    # NULL result -- an exception is accepted too.
    try:
        cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)", (u, vtxt([1.0] * 3)))
        check(cur.fetchone()[0] is None, "a dimension mismatch is refused (NULL result)", None)
    except Exception:
        check(True, "a dimension mismatch is refused (an error)")

    cur.execute("DROP TABLE IF EXISTS _fp_g2")

    print("test_precision: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
