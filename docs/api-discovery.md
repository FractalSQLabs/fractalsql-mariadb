<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Discovery API Reference

The Discovery tier provides high-precision and diverse retrieval mechanisms. Unlike traditional vector search, it treats the embedding space as a continuous optimization problem.

`fractal_search` covers two modes in **one** function: pass a non-empty corpus for top-k search, or pass an empty corpus (`''`) for pure Sniper-mode convergence, and set `"debug":true` in `params` for a trajectory trace. There is no separate `fractal_search_debug` function.

---

## `fractal_search`
**Corpus top-k search, or pure Sniper-Mode convergence**

Runs Stochastic Fractal Search against an inline corpus and returns the top-`k` closest points by cosine distance, alongside the raw converged best point. Pass an empty corpus for the pure-convergence behavior — converge to the single best point in `[-1,1]^d`: `fractal_search('', '[1,0]', 1, '{}')` returns a synthetic one-row result whose `top_k[0]` **is** the converged point.

### Signature
```sql
fractal_search(
    vector_csv TEXT,   -- corpus: '[[v11,v12],[v21,v22]]' or 'v11,v12;v21,v22', or '' for none
    query_csv  TEXT,   -- single query vector, same string formats
    k          INT,    -- positive integer, top-k count
    params     TEXT    -- JSON object of SFS tuning knobs, see below
) RETURNS TEXT   -- JSON
```

### `params` (all keys optional, pass `'{}'` for defaults)
```json
{"iterations": 30, "population_size": 50, "diffusion_factor": 2,
 "walk": 0.5, "debug": false, "session_id": 0}
```
| Key | Default | Range | Description |
| --- | --- | --- | --- |
| `iterations` | `30` | 1–10,000 | Number of SFS generations to run. |
| `population_size` | `50` | 1–100,000 | Number of particles per generation. |
| `diffusion_factor` | `2` | 1–32 | SFS MDN (walk-per-particle count). |
| `walk` | `0.5` | n/a | Diffusion walk parameter. |
| `debug` | `false` | n/a | Adds a `"trace"` object to the result (see below): `{"trace":{"best_point":[...],"best_fit":..,"edition":"Community"}}`, no per-generation history. |
| `session_id` | `0` (none) | n/a | Pass `CONNECTION_ID()` to run this search on your session's persistent, Diversify-aware ctx instead of a fresh throwaway one. Required for `fractal_diversify_*` settings (below) to actually affect this call, and for D_q/overhead stats to accumulate across calls. Omit for the default, stateless behavior. |

A value outside its documented range makes the whole call return `NULL` (verified: `iterations=10001` → `NULL`), not a clamped or partial result.

### Return
```json
{ "dim": 2, "n_corpus": 3, "best_fit": 0.0,
  "best_point": [1, 0],
  "top_k": [{"idx": 0, "dist": 0.0}, {"idx": 2, "dist": 0.0061}] }
```

### Getting a plain rows-of-(idx, dist) result from an inline corpus
`fractal_search`'s own `top_k` array already carries these rows. Use `JSON_TABLE()` to unpack it:
```sql
SELECT t.idx, t.dist
FROM JSON_TABLE(
       (SELECT fractal_search(@corpus, @query, 5, '{}')),
       '$.top_k[*]' COLUMNS (idx INT PATH '$.idx', dist DOUBLE PATH '$.dist')
     ) t;
```
This is different from the table-backed procedures below: `fractal_search` takes the corpus as an inline argument, it never reads a table.

---

## Table-backed search: `fractal_search_telemetry` and its siblings

`fractal_search`/`fractal_explore` take their corpus as an inline argument. The four procedures below instead scan a real table directly. They are stored procedures, not functions, because a MariaDB C UDF cannot run a query against the calling session's tables. Each takes `table_name` (a bare, non-schema-qualified name in the current database, with exactly one single-column `PRIMARY KEY`) and `vector_col` (a `TEXT` column holding a JSON-array-string vector such as `'[0.1,0.2,...]'`, or a MariaDB 11.7+ native `VECTOR(n)` column, auto-detected via `INFORMATION_SCHEMA` and read through `VEC_TOTEXT()` transparently). Call one, then read its `OUT` parameter:

```sql
CALL fractal_search_telemetry('documents', 'embedding', '[0.1,0.2,0.3]', 5, @result);
SELECT @result;
```

All four raise a real client-visible `SIGNAL SQLSTATE '45000'` error (unlike the C UDFs above, whose row-level failures surface as a silent `NULL`) if `table_name` is schema-qualified, lacks exactly one single-column `PRIMARY KEY`, if `vector_col` doesn't exist on it, or if the scan matches no rows.

### `fractal_search_telemetry`
**Ground-truth row retrieval**

Returns the real `k` nearest rows in `table_name` to `query`, by cosine distance.

```sql
fractal_search_telemetry(
    IN  table_name VARCHAR(128),
    IN  vector_col VARCHAR(64),
    IN  query      JSON,   -- same vector-string formats as fractal_search's query_csv
    IN  k          INT,
    OUT result     JSON
)
```

Returns a JSON array of `{"doc_id": ..., "dist": ...}` objects, ascending by distance:
```json
[{"doc_id": 42, "dist": 0.0031}, {"doc_id": 17, "dist": 0.045}]
```

---

## `fractal_hybrid_clinical_search`
**Cohort-restricted telemetry**

Same as `fractal_search_telemetry`, but scoped to a caller-supplied subset of rows instead of the whole table.

```sql
fractal_hybrid_clinical_search(
    IN  table_name VARCHAR(128),
    IN  vector_col VARCHAR(64),
    IN  query      JSON,
    IN  doc_ids    JSON,   -- e.g. '[1,2,3]': the primary-key values to restrict to
    IN  k          INT,
    OUT result     JSON
)
```

`doc_ids` is a JSON array of real primary-key values, computed by the caller with ordinary SQL (for example, from a cohort-filtering `WHERE` clause). No dynamic SQL predicate or filter string is ever accepted here, so this argument can't be used to inject a filter condition. Returns the same `{"doc_id", "dist"}` array shape as `fractal_search_telemetry`.

---

## `fractal_search_trajectory`
**Drift-vector search**

Searches near the delta between two states (`current_vector - baseline_vector`) against the whole table: "what has changed" rather than "where am I", for drift and trajectory monitoring.

```sql
fractal_search_trajectory(
    IN  table_name      VARCHAR(128),
    IN  vector_col      VARCHAR(64),
    IN  baseline_vector JSON,
    IN  current_vector  JSON,
    IN  k               INT,
    OUT result          JSON
)
```

---

## `fractal_cross_modal_search`
**Weighted modality concatenation**

Searches a combined space of two different modalities (for example, morphology and clinical data) using a weighted concatenation: each modality keeps its own dimensions, scaled by `alpha_weight` and `1 - alpha_weight` respectively before concatenation. `table_name.vector_col` must already be stored in this same combined shape; that's an upstream ETL concern, not something this procedure validates beyond the usual dimension-match requirement.

```sql
fractal_cross_modal_search(
    IN  table_name        VARCHAR(128),
    IN  vector_col        VARCHAR(64),
    IN  morphology_vector JSON,
    IN  clinical_vector   JSON,
    IN  alpha_weight      DOUBLE,  -- [0,1]; 1 - alpha_weight goes to clinical_vector
    IN  k                 INT,
    OUT result            JSON
)
```

---

## `fractal_explore`
**Scout Mode: population dispersion**

There is no table/column-scanning set-returning function here: MariaDB's C UDF ABI cannot query the calling session's tables, and there are no table-returning UDFs. `fractal_explore` takes the corpus inline instead, the same convention `fractal_search` uses.

### Signature
```sql
fractal_explore(
    corpus_csv TEXT,   -- same formats as fractal_search's vector_csv
    query_csv  TEXT,
    params     TEXT    -- same SFS knobs as fractal_search's params
) RETURNS TEXT   -- JSON, walk=0 dispersion; carries a "population" array
```

### Return
```json
{"population": [[x1,y1,z1], [x2,y2,z2], ...]}
```
`population` has `population_size` entries (one per particle), each of the corpus's dimensionality.

---

## Diversify / Repulsion (session-scoped)

MariaDB is one shared multithreaded process for *every* connection, so a single file-static ctx would leak one session's Diversify tuning (and its rolling D_q/overhead stats) into every other concurrent session's queries. Every function below instead takes an explicit `session_id BIGINT` as its first argument, backed by a connection-scoped ctx registry (`src/fractalsql_session.c`). Convention: pass `CONNECTION_ID()`.

`fractal_search`/`fractal_explore` pick up that same session's ctx via the optional `"session_id"` key in their own `params` JSON. Diversify settings only affect a search that opts in that way:

```sql
SELECT fractal_diversify_enable(CONNECTION_ID());
SELECT fractal_diversify_set_params(CONNECTION_ID(),
         '{"window_n": 8, "repulsion_weight": 0.7}');
SELECT fractal_search(@corpus, @query, 5,
         JSON_SET('{}', '$.session_id', CONNECTION_ID()));
SELECT fractal_detect_collapse(CONNECTION_ID()) AS dq;
SELECT fractal_explain_result(CONNECTION_ID()) AS diagnostics;
SELECT fractal_diversify_disable(CONNECTION_ID());
SELECT fractal_session_close(CONNECTION_ID());  -- optional early cleanup
```

> **Known limitation**: MariaDB gives UDFs no on-disconnect hook, so a session's registry entry can only be reclaimed by an idle-TTL sweep or LRU eviction, not exactly on disconnect, and MariaDB can reuse `CONNECTION_ID()` values over the server's lifetime under sustained churn. See `src/fractalsql_session.h` for the full reasoning and the bounded, documented residual risk. Call `fractal_session_close(...)` explicitly at the end of a logical session (e.g. from a connection pool's release hook) to avoid relying on the idle sweep at all.

### `fractal_diversify_enable(session_id)` → `INT` (0)
### `fractal_diversify_disable(session_id)` → `INT` (0)

### `fractal_diversify_set_params(session_id, params_json)` → `INT` (0)
`params_json` is a JSON object, all keys optional (only supplied keys override the session's current value):
```json
{"window_n": 5, "stall_threshold": 0.15, "repulsion_sigma": null,
 "repulsion_weight": null, "max_shadows_considered": 64, "tail_buffer_cap": 256}
```
| Key | Default | Max |
| --- | --- | --- |
| `window_n` | `5` | 32 |
| `stall_threshold` | `0.15` | n/a |
| `repulsion_sigma` | f(dim) | n/a |
| `repulsion_weight` | n/a | n/a |
| `max_shadows_considered` | `64` | n/a |
| `tail_buffer_cap` | `256` | 1024 |

### `fractal_detect_collapse(session_id)` → `DOUBLE`
Current D_q (diversity metric). `NULL` if Diversify is disabled or no Diversify-aware search has run yet on this session.

### `fractal_explain_result(session_id)` → `TEXT` (JSON)
```json
{"dq": 0.42, "diversify_enabled": true, "overhead_p99_us": 120}
```

### `fractal_session_close(session_id)` → `INT` (0)
Explicit early cleanup of a session's registry entry; see the idle-TTL note above.

### `fractal_feedback_report(session_id, result_handle, kind [, dwell_ms])` → `INT` (0)
`kind`: `'dwell'` | `'positive'` | `'negative'`. Writes into the same per-session rolling state `fractal_detect_collapse`/`fractal_explain_result` read. Inert until `fractal_diversify_enable()` has been called on this session.

### `fractal_isolate_background(session_id, result_handle)` → `INT` (0)
Convenience wrapper: `fractal_feedback_report(session_id, result_handle, 'negative', 0)`.
