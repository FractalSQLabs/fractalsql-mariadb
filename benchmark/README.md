# FractalSQL benchmark: native VECTOR(n) index vs Scout Mode

Head-to-head comparison of MariaDB's own built-in `VECTOR(n)` ANN index
against `fractal_explore` (Scout Mode, `walk=0`). Measures search
latency and island recall on a synthetic Gaussian-cluster dataset.

This is a SEPARATE suite from `benchmark/tester/` (the pre-existing Node.js
throughput driver that measures raw `fractal_search()` latency percentiles);
this one is a research/methodology comparison.

## Prerequisites

- MariaDB 10.6-12.2 with `fractalsql.so` installed. The native-`VECTOR(n)`
  comparison arm additionally needs MariaDB 11.7+ (GA in 11.8 LTS). Every
  script here self-detects and degrades gracefully (Scout-only numbers, no
  native arm) on older majors.
- Python 3.9+
- A database you can create/drop tables in (default: `fractalsql_bench`)

## Setup

```bash
pip install -r benchmark/requirements.txt
mariadb -uroot -p -e "CREATE DATABASE fractalsql_bench;"
```

`fractal_explore`/`fractal_search` (used by `head_to_head.py`) are UDFs,
registered globally by `sql/install_udf.sql` and callable from any
database once installed anywhere. `fractal_search_trajectory` (used by
`vector_type_head_to_head.py`'s search-latency arm) is a stored
PROCEDURE, not a UDF, schema-owned like any other, so it only exists
in whichever database `sql/install_udf.sql` was sourced into. If
that's not `fractalsql_demo` already, source it into `fractalsql_bench`
too (confirmed against a live server: skipping this step fails
`vector_type_head_to_head.py`'s arm (c) with `PROCEDURE
fractalsql_bench.fractal_search_trajectory does not exist`, while
`head_to_head.py` runs fine without it):

```bash
mariadb -uroot -p fractalsql_bench < sql/install_udf.sql
```

## Run the benchmark

```bash
python3 benchmark/data_gen.py --host 127.0.0.1 --password <root password> \
    --with-native-vector          # ~15-45s to populate 5000 rows + build the index
python3 benchmark/head_to_head.py --host 127.0.0.1 --password <root password>
```

## What you should see

The output is a per-query table followed by an average. This example is
from an actual run against a real `mariadb:12.2` container (5000 rows,
dim=128), not a hand-written estimate:

```
Benchmark: 5000 stored vectors, 50 clusters, dim=128
  Native VECTOR(n) index: available, LIMIT 50
  Scout (fractal_explore): population=50, iterations=8, mdn=2, walk=0.0 (brute-force relevance scan + MMR)

qi  anchor      |     Native ms   Native recall  |     Scout ms   Scout recall
--------------------------------------------------------------------------------
 0  cluster  23 |        5.5      1 / 50     |      227.1      5 / 50
 1  cluster  25 |        3.1      1 / 50     |      183.1      5 / 50
 2  cluster  37 |        5.9      1 / 50     |      190.6      5 / 50
 3  cluster  47 |        4.3      1 / 50     |      193.8      6 / 50
 4  cluster   1 |        4.0      2 / 50     |      192.9      7 / 50

Averages over 5 queries:
  Native:     4.6 ms   recall  1.2 / 50
  Scout:    197.5 ms   recall  5.6 / 50
  Scout is 43.3x slower and discovers 4.7x more distinct clusters
```

The shape of the result will vary run to run, but the pattern is robust and
matches fractalsql-postgresql's own HNSW-vs-Scout finding: the native ANN
index finds ~1 cluster at single-digit-millisecond latency; Scout Mode finds
5-7 clusters at ~200ms. Same story as postgres, different index technology,
different algorithms solving different problems.

## Why such a small default N (and why this differs from postgres's suite)

`data_gen.py` defaults to **5000 rows, dim=128**, while postgres's own suite
defaults to 100,000 rows, dim=768. This is not a smaller-is-easier choice,
it's architectural: `fractal_explore()` (Scout Mode) takes its **entire**
corpus as one client-supplied inline string argument on every call. MariaDB's
C UDF ABI has no SPI and no table-returning UDFs at all (see
`sql/install_udf.sql`'s own "Scout Mode" comment), so
unlike postgres's `fractal_search_explore(table, col, ...)`, there is no way
for this repo's Scout Mode to scan `bench_vectors` server-side. `head_to_head.py`
pulls the whole corpus into the Python client and re-sends it as a query
parameter on every single Scout call. At postgres's 100k x dim=768 scale that
string would be hundreds of megabytes, sent over the wire per query,
impractical for a benchmark meant to actually finish. 5000 x dim=128 keeps
the whole run under two seconds while still producing a clear, real
latency/recall gap.

The native-index arm has no such constraint (it's a real server-side
`ORDER BY VEC_DISTANCE_EUCLIDEAN(...) LIMIT k` query). If you only care
about that arm, `--n` can go much higher. `benchmark/vector_type_head_to_head.py`
(below) also scans server-side throughout and isn't bound by this limit
either.

## Tuning

`head_to_head.py` exposes:

```
--n-queries     number of queries to average (default 5)
--top-k         #results per method, also SFS population_size (50)
--sfs-iter      SFS generations (default 8)
--sfs-mdn       diffusion factor (default 2)
--seed          query-selection RNG seed
```

`data_gen.py` exposes the dataset shape:

```
--n                  total points (default 5000)
--dim                vector dimension (default 128)
--clusters           number of Gaussian islands (default 50)
--sigma              intra-cluster std (default 0.05)
--with-native-vector add emb_vec VECTOR(dim) + VECTOR INDEX (11.7+ only)
--batch-size         rows per executemany() batch (default 500)
```

`benchmark/scale_sweep.sh [host] [port] [password]` runs `head_to_head.py
--quiet` across N = 500/1000/2000/5000/10000 (smaller range than postgres's
500-50000, same reasoning as above).

## Portable TEXT vs native VECTOR(n) at scale

A second, unrelated benchmark: MariaDB's built-in `VECTOR(n)` type vs. this
repo's own portable TEXT/JSON-array-string convention: storage size,
bulk-load throughput, and search latency, at `data_gen.py`'s real scale.
Distinct from the native-index-vs-Scout comparison above. There is no
MariaDB equivalent of postgres's own custom `fractal_vector` SQL type (no
`CREATE TYPE`/typmod mechanism in MariaDB at all), this compares the two
storage shapes that actually exist here.

```bash
python3 benchmark/data_gen.py --host 127.0.0.1 --password <root password> \
    --with-native-vector   # adds bench_vectors.emb_vec, if not already present
python3 benchmark/vector_type_head_to_head.py --host 127.0.0.1 --password <root password>
```

Real measured output (5000 rows, dim=128, MariaDB 12.2):

```
vector_type_head_to_head: 5000 rows, dim=128, native VECTOR(n)=yes

-- (a) storage size (OCTET_LENGTH, avg over up to 200 sampled rows) --
  VECTOR(n)     : 512 bytes  (fixed at 4 bytes/dim, float32)
  TEXT (JSON)   : 1218 bytes
  ratio         : 2.38x

-- (b) bulk load throughput (500 rows, dim=128, batched INSERT) --
  TEXT      : 0.22s (2235 rows/s)
  VECTOR(n) : 0.11s (4507 rows/s)

-- (c) fractal_search_trajectory latency: TEXT vs VECTOR(n) column --
  TEXT      : 139.2 ms avg over 5 queries (min 132.0, max 148.6)
  VECTOR(n) : 208.1 ms avg over 5 queries (min 194.3, max 216.1)
```

**Read this honestly, it isn't a clean sweep for either column type.**
`VECTOR(n)` is smaller on disk (fixed 4 bytes/dim, no TOAST-style
compression path either side, this ratio is architecturally fixed, not
data-dependent the way postgres's TOAST-compression-based ratio was) and
loads faster. But it was *slower* on sub-benchmark (c) in this run: the
underlying `fractal_search_trajectory`/`_telemetry`/`_hybrid_clinical_search`/
`_cross_modal_search` family reads a `VECTOR(n)` column through `VEC_TOTEXT()`
first (`_fractalsql_scan_corpus`, `sql/install_udf.sql`) to get it into this
repo's own vector-text grammar, and that per-row conversion step costs more
than reading a plain `TEXT` column directly costs, in this measurement.
Judge for your own workload; don't assume `VECTOR(n)` wins on latency just
because it wins on storage size.

### A real bug this benchmark found (fixed at the source)

While writing sub-benchmark (c), every `fractal_search_trajectory` call
against the full 5000-row corpus (dim=128, ~6MB of vector text) silently
returned `[]`, zero results, **no error**. Root cause, confirmed directly:
`_fractalsql_scan_corpus` and `fractal_hybrid_clinical_search`
(`sql/install_udf.sql`) each build their corpus via `GROUP_CONCAT()`
without first raising the session's `group_concat_max_len`. MariaDB's
default is 1MB (as low as 1024 bytes on an older `my.cnf`), and past that,
`GROUP_CONCAT` silently *truncates* (a warning, not an error), producing
invalid JSON that `fractal_search` then treats as an empty corpus. This
affected `fractal_search_telemetry`, `fractal_hybrid_clinical_search`,
`fractal_search_trajectory`, and `fractal_cross_modal_search` alike, at
any table whose combined vector text crossed that limit, a few hundred
rows at dim=128 was enough.

This is now fixed at the source: both procedures raise
`SESSION group_concat_max_len` to 1 GiB before their `GROUP_CONCAT`
call and restore the session's prior value immediately after (see
`sql/install_udf.sql`'s comment on `_fractalsql_scan_corpus`, right
above the fix, for the full account). Live re-verified against a fresh
2000-row/dim=128 corpus (well past the ~870-row threshold that used to
trigger truncation): `fractal_search_telemetry` now returns the correct
top-k every time, no client-side workaround needed.
`vector_type_head_to_head.py`'s own `SET SESSION group_concat_max_len`
call (below) is now redundant with the upstream fix but is harmless and
left in place as defense-in-depth for anyone running this script
against an older, unpatched build.

`vector_type_head_to_head.py`'s own knobs:

```
--load-n           row count for the load-throughput sub-benchmark
                    (default 2000, smaller than the full corpus,
                    this arm is O(n) by design so a subset is
                    representative)
--search-queries    queries to average for the latency sub-benchmark
                    (default 10)
```

### Sub-benchmark (d), peak RSS: not included

A fourth sub-benchmark reading `/proc/<backend_pid>/status` around a
full-corpus scan, a regression tripwire for a per-row `pfree()` loop
actually keeping memory bounded, needs a one-process-per-connection
model to isolate a specific backend's RSS delta. MariaDB's threading
model is the opposite: one shared multithreaded `mariadbd` process
serves every connection at once, so there is no per-connection process
to read an isolated RSS delta from. A whole-process reading during this
benchmark's scan would be contaminated by whatever else that shared
server is doing for other connections at the same moment, and wouldn't
actually isolate the thing (d) is meant to test. Dropped rather than
faked; if you need memory-bound verification for the
native-`VECTOR(n)`/TEXT scan paths, a real profiler attached to the
`mariadbd` process is the honest tool for that, not this benchmark.
