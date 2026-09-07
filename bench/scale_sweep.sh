#!/usr/bin/env bash
# bench/scale_sweep.sh: native VECTOR(n) index vs FractalSQL Scout
# Mode at a range of small-to-medium corpus sizes, dim=128 fixed.
#
# Regenerates
# bench_vectors at each N via data_gen.py --with-native-vector, then runs
# head_to_head.py --quiet once per N. Prints one line per N so the whole
# sweep reads as a single table you can eyeball for the latency/recall
# trend.
#
# Sizes span 500-50000 --
# see bench/data_gen.py's own docstring for why: fractal_explore()
# (Scout Mode here) takes its ENTIRE corpus as one client-supplied
# inline string on every call (no server-side table scan is possible
# for it at all -- MariaDB's C UDF ABI has no server-side table
# access), so this sweep's upper
# end is bounded by "does the benchmark still finish in a reasonable
# time", not by anything server-side.
#
# Usage:
#   bench/scale_sweep.sh [host] [port] [password]
#
# host/port/password default to 127.0.0.1/3306/test, matching this
# repo's own live-tested Docker container conventions (build_test.sh,
# the other bench/*.py scripts' own defaults).

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
PASSWORD="${3:-test}"
DIM=128
SIZES=(500 1000 2000 5000 10000)

cd "$(dirname "$0")/.."

for n in "${SIZES[@]}"; do
  echo "=== n=$n dim=$DIM ===" >&2
  python3 bench/data_gen.py --host "$HOST" --port "$PORT" --password "$PASSWORD" \
      --n "$n" --dim "$DIM" --with-native-vector >&2
  python3 bench/head_to_head.py --host "$HOST" --port "$PORT" --password "$PASSWORD" \
      --quiet
done
