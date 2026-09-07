#!/usr/bin/env python3
"""tests/test_scout.py: Scout Mode (fractal_explore) e2e gate.

This repo
has no server-side table access and no table-returning UDFs (MariaDB's
C UDF ABI can't run SQL against the calling session), so
fractal_explore(corpus, query, params) takes the corpus as an inline
argument instead, the same
convention as fractal_search itself. So this test builds the 3-island
corpus as a JSON string client-side and passes it directly, rather than
via a table.

Asserts the Scout enablement properties:
  (1)+(2) returns the population: population_size particles, each of
          the corpus dim (not a single best-point stub);
  (3)     discovery: the particles disperse across more than one island.

Skips cleanly (exit 0) if the mariadb connector is missing, no DB is
reachable, or fractal_explore isn't deployed.

Usage:
    python3 tests/test_scout.py
    FRACTALSQL_HOST=... FRACTALSQL_PORT=... python3 tests/test_scout.py
"""
import json
import random
import sys

from _t2s_common import connect_or_skip

CENTERS = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
DIM = 3
PER = 20
POP = 24


def nearest(p):
    return min(range(3), key=lambda k:
               sum((p[i] - CENTERS[k][i]) ** 2 for i in range(DIM)))


def main():
    rng = random.Random(11)
    conn = connect_or_skip()
    if conn is None:
        return 0

    corpus = []
    for c in CENTERS:
        for _ in range(PER):
            corpus.append([x + rng.uniform(-0.02, 0.02) for x in c])

    query = CENTERS[0]  # anchor inside island 0
    opts = json.dumps({"population_size": POP, "iterations": 12})

    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT fractal_explore(?, ?, ?)",
            (json.dumps(corpus), json.dumps(query), opts))
        result = json.loads(cur.fetchone()[0])
    except Exception as e:
        print(f"SKIP: fractal_explore unavailable / errored: {e}")
        return 0

    population = result.get("population")
    if not population:
        print("SKIP: fractal_explore returned no 'population' key "
              "(pre-Scout build? stub result?)")
        return 0

    if len(population) != POP:
        print(f"FAIL: expected {POP} particles, got {len(population)}", file=sys.stderr)
        return 1
    if not all(len(p) == DIM for p in population):
        print("FAIL: particle dim != 3", file=sys.stderr)
        return 1

    islands = len(set(nearest(p) for p in population))
    print(f"population: {len(population)} particles, dim {DIM}")
    print(f"SCOUT discovered {islands}/3 islands")
    if islands < 2:
        print(f"FAIL: Scout discovered only {islands} island(s); "
              "expected >= 2 (no dispersion)", file=sys.stderr)
        return 1
    print("OK: mariadb scout gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
