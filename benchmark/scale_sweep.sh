#!/usr/bin/env bash
# benchmark/scale_sweep.sh: native VECTOR(n) index vs FractalSQL Scout
# Mode at a range of small-to-medium corpus sizes, dim=128 fixed.
#
# MariaDB port of fractalsql-postgresql's bench/scale_sweep.sh. Regenerates
# bench_vectors at each N via data_gen.py --with-native-vector, then runs
# head_to_head.py --quiet once per N. Prints one line per N so the whole
# sweep reads as a single table you can eyeball for the latency/recall
# trend.
#
# Sizes are much smaller than postgres's own sweep (500-50000 there) --
# see benchmark/data_gen.py's own docstring for why: fractal_explore()
# (Scout Mode here) takes its ENTIRE corpus as one client-supplied
# inline string on every call (no server-side table scan is possible
# for it at all, no SPI in MariaDB's C UDF ABI), so this sweep's upper
# end is bounded by "does the benchmark still finish in a reasonable
# time", not by anything server-side.
#
# Usage:
#   benchmark/scale_sweep.sh [host] [port] [password]
#
# host/port/password default to 127.0.0.1/3306/test, matching this
# repo's own live-tested Docker container conventions (build_test.sh,
# the other benchmark/*.py scripts' own defaults).

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
PASSWORD="${3:-test}"
DIM=128
SIZES=(500 1000 2000 5000 10000)

cd "$(dirname "$0")/.."

for n in "${SIZES[@]}"; do
  echo "=== n=$n dim=$DIM ===" >&2
  python3 benchmark/data_gen.py --host "$HOST" --port "$PORT" --password "$PASSWORD" \
      --n "$n" --dim "$DIM" --with-native-vector >&2
  python3 benchmark/head_to_head.py --host "$HOST" --port "$PORT" --password "$PASSWORD" \
      --quiet
done
