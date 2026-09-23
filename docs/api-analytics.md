<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Analytics API Reference

The Analytics tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into structural insights.

MariaDB has no array types and no `DEFAULT`-argument syntax for `CREATE FUNCTION`. Every array argument is therefore a CSV-or-bracketed-JSON-array **string** (the same convention `fractal_search`'s own `vector_csv`/`query_csv` arguments already use: `'1,2,3'` or `'[1,2,3]'`), and every optional trailing scalar argument is bundled into one trailing JSON `params` string instead. Functions that return structured results return them as JSON-valid `STRING` values.

---

## Fractal Dimension Analysis

### `fractal_dimension_dfa`
**Detrended Fluctuation Analysis**

Calculates the scaling exponent (α) of a time-ordered series to distinguish between white noise, pink noise, and Brownian motion. ~0.5 uncorrelated, ~1.0 1/f "pink" noise, ~1.5 Brownian motion.

**Signature**: `fractal_dimension_dfa(series_csv TEXT) RETURNS DOUBLE`

**Requirement**: Documented (here and in the vendored core headers) as "≥ 16 points", but 16 is necessary, not sufficient: the underlying check rejects every series shorter than 24 points in practice, and silently (`*error=1` with no distinguishing message). The real minimum likely depends on the data's own characteristics rather than a fixed constant, so don't treat 24 as authoritative either, just safer than the documented 16.

```sql
SELECT fractal_dimension_dfa('[0.12,-0.45,0.88,...]');  -- >= 24 points to be safe
```

### `fractal_dimension_boxcount`
**Minkowski-Bouligand Dimension**

Measures the spatial complexity of a point cloud using box-counting. `points_csv` is a flat, row-major `n_points * dim` CSV/JSON-array.

**Signature**: `fractal_dimension_boxcount(points_csv TEXT, dim INT) RETURNS DOUBLE`

**Requirement**: Documented as "≥ 8 points and a non-degenerate bounding box", the same "necessary, not sufficient" gap as `fractal_dimension_dfa` above: 500 uniform-random 2-D points succeeded in testing, 64 did not.

### `fractal_dimension_drift`
**Regime Change Detection**

Detects changes in the DFA exponent between a recent window and the baseline. Positive drift = increasing complexity/irregularity.

**Signature**: `fractal_dimension_drift(series_csv TEXT, win INT) RETURNS TEXT` (JSON: `{"drift":.., "recent_alpha":.., "baseline_alpha":..}`)

**Requirement**: `n >= win + 16`, `win >= 16`.

---

## Time-Series and Topology

### `fractal_change_point_detect`
**Change-Point Localization**
DFA's complement: localizes *where* a series' mean and/or variance shifted, instead of only characterizing its overall scaling behavior.

**Signature**: `fractal_change_point_detect(series_csv TEXT, win INT, threshold DOUBLE, max_points INT) RETURNS TEXT` (JSON array of ascending 0-indexed boundary positions, e.g. `"[12,47]"`)
Sliding two-sample test over adjacent windows of `win` samples; flags a boundary when the mean differs by more than `threshold` pooled-standard-deviation units or the variance ratio exceeds `threshold` squared. Returns up to `max_points` boundaries. Requires at least `2 * win` points.

### `fractal_periodogram`
**Classical Periodogram**
Power at each positive Fourier frequency, computed by direct $O(n^2)$ DFT (exact, not an FFT approximation).

**Signature**: `fractal_periodogram(series_csv TEXT, max_peaks INT) RETURNS TEXT` (JSON: `{"freqs":[..],"power":[..]}`)
**Return**: only the `max_peaks` bins with highest power, sorted descending. `freqs[i]` is cycles per sample in $(0, 0.5]$; `1.0/freqs[i]` is samples per cycle. Useful for network-beaconing and retry-loop cadence detection that DFA alone is blind to. Requires at least 4 points.

### `fractal_tda_persistence_diagram`
**Topological Persistence**
Topological analysis over a point cloud's Vietoris-Rips filtration, capped at 512 points.

**Signature**: `fractal_tda_persistence_diagram(points_csv TEXT, dim INT, max_dim INT, max_thresh DOUBLE, max_h0_bars INT) RETURNS TEXT` (JSON: `{"h0_bars":[{"birth":..,"death":..},..],"n_h0_bars":N,"betti1":N_or_null}`)
**Return**: `h0_bars` is an exact 0-dimensional persistence computation (single-linkage clustering). `betti1` (only computed when `max_dim = 1`) is the underlying graph's cycle rank, **not** full simplicial $H_1$: it over-counts true $H_1$ whenever a filled triangle exists in the data. A full simplicial computation (what Ripser/GUDHI do via boundary-matrix reduction) is out of scope. `points_csv`: flat, row-major `n_points x dim`, `2 <= n_points <= 512`.

### `fractal_state_fingerprint`
**SimHash State Fingerprint**
Random-hyperplane SimHash (Charikar 2002): projects a state vector onto `n_bits` random hyperplanes (deterministic from `seed`) and packs the sign of each projection MSB-first into bytes.

**Signature**: `fractal_state_fingerprint(vec_csv TEXT, n_bits INT, seed DOUBLE) RETURNS TEXT` (JSON array of the `(n_bits+7)/8` output bytes)
Two nearly-identical states collapse to the same or a very low Hamming-distance fingerprint, unlike an exact hash's all-or-nothing sensitivity to floating-point noise.

### `fractal_cycle_detect`
**Streaming Cycle Detection**
Brent's algorithm (1980) run over a stream of `fractal_state_fingerprint` outputs, all fed through one detector in a single call.

**Signature**: `fractal_cycle_detect(fingerprints_csv TEXT, n_bytes INT, hamming_threshold INT) RETURNS TEXT` (JSON: `{"detected":true,"cycle_len":N,"at_index":I}` or `{"detected":false}`)
**Return**: the FIRST cycle found. `at_index` is the position in the stream where the cycle closed, `cycle_len` its length. `fingerprints_csv` is the concatenated fingerprint byte stream, exactly `n_fingerprints * n_bytes` values long. `hamming_threshold = 0` requires byte-exact fingerprint matches; above that, near-identical states count. Unlike the streaming core kernel, this single-call wrapper cannot continue across calls (a true incremental wrapper would need a session-scoped handle, out of scope for this pass).

These two pair into tolerant "have I basically been in this state before" loop detection; `fractal_agent_detect_loop` composes them (see [api-agency.md](api-agency.md)).

---

## Domain-Specific Geometry

These functions take **pre-extracted geometry** (graphs, meshes, skeletons) as flat, row-major CSV/JSON-array strings, not raw imaging data.

| Function | Signature | Returns | Description |
| --- | --- | --- | --- |
| `fractal_vascular_network` | `(node_coords_csv, edges_csv, edge_arc_length_csv)` | `{"mean_tortuosity":.., "branch_density":.., "fractal_dimension":..}` | Vessel network complexity. `node_coords`: flat `n_nodes*3` (x,y,z). `edges`: flat `n_edges*2` node-index pairs. `edge_arc_length`: `n_edges` true centerline arc lengths (e.g. from VMTK). |
| `fractal_cortical_folding` | `(vertices_csv, faces_csv)` | `{"mesh_area":.., "hull_area":.., "gyrification_index":..}` | Gyrification Index (Zilles et al. 1988): mesh surface area / convex hull surface area. `vertices`: flat `n_vertices*3`. `faces`: flat `n_faces*3` triangle vertex indices. Requires ≥ 4 non-coplanar vertices. |
| `fractal_nerve_plexus_metric` | `(node_coords_csv, dim, edges_csv)` | `{"fiber_length_density":.., "branch_density":.., "fractal_dimension":..}` | Nerve fiber plexus metrics (corneal confocal microscopy convention). `node_coords`: flat `n_nodes*dim` (dim typically 2). `edges`: flat `n_edges*2` node-index pairs. |
| `fractal_morphological_complexity` | `(points_csv, dim)` | `{"dimension":.., "lacunarity":..}` | Box-counting dimension + fixed-grid lacunarity of a pre-segmented mask. `points`: flat `n_points*dim` occupied mask points. |

All four return a JSON `TEXT` string.

---

## Portfolio Optimization

### `fractal_optimize_portfolio`
**Cardinality-Constrained Sharpe-Ratio Maximization**

Finds the best `k` assets in a large universe without brute-force exponential cost. `mu`: `n_assets` expected returns. `cov`: flat, row-major `n_assets x n_assets` covariance matrix.

**Signature**: `fractal_optimize_portfolio(mu_csv TEXT, cov_csv TEXT, k INT, params TEXT) RETURNS TEXT`

**Return**: `{"sharpe":.., "weights":[..]}`

`params` is a JSON object, all keys optional; pass `'{}'` for defaults:
```json
{"seed": 0, "use_obl": false, "diffusion_mode": "gaussian"}
```
- `use_obl`: apply Opposition-Based Learning to each SFS trial candidate, also evaluating its bound-reflected opposite and keeping whichever fits better. Off by default; doubles the fitness-eval cost of the affected diffusion step when enabled.
- `diffusion_mode`: `"gaussian"` (default, canonical SFS) or `"levy"`, which substitutes a heavy-tailed Levy-flight step (Mantegna's algorithm) for the Gaussian walk. This can help escape local optima on highly multimodal problems at the cost of occasional very large steps.

```sql
SELECT fractal_optimize_portfolio('[0.1,0.15]', '[0.04,0.01,0.01,0.03]', 2, '{}');
```

### `fractal_optimize_portfolio_multimodal`
**Enterprise tier.** Diverse-candidate variant of `fractal_optimize_portfolio`: runs `n_restarts` independent single-best searches and greedy-selects up to `n_restarts` structurally distinct candidates instead of one. Returns `NULL` cleanly if no enterprise library is loaded (`FRACTALSQL_ENTERPRISE_LIB`, see [`enterprise.md`](enterprise.md)).

**Signature**: `fractal_optimize_portfolio_multimodal(mu_csv TEXT, cov_csv TEXT, k INT, n_restarts INT, overlap_threshold DOUBLE, quality_frac DOUBLE, seed BIGINT) RETURNS TEXT`

**Return**: `{"n_found":N,"candidates":[{"sharpe":..,"weights":[..]},...]}`, Sharpe descending.

All 7 arguments are required and positional (MariaDB UDFs have no default-argument syntax, and this function has no trailing params-JSON convention, unlike the Community-tier `fractal_optimize_portfolio` above).
- `overlap_threshold`: max allowed selected-asset overlap (0.0-1.0, Jaccard-style) between any two returned candidates.
- `quality_frac`: a candidate must reach at least `quality_frac` × the best Sharpe found to be kept.

Also logs a best-effort audit-chain entry (kind=2) with the full candidate set, same as `fractal_optimize_portfolio` does for its one result. See [`enterprise.md`](enterprise.md).

### `fractal_optimize_portfolio_multimodal_ex`
**Enterprise tier.** The OBL/Lévy-flight-capable sibling of `fractal_optimize_portfolio_multimodal` above: same `n_restarts` search and diverse selection, with two extra knobs applied uniformly to every restart's search. MariaDB's UDF ABI has no default-argument syntax, so the two knobs couldn't be added to the 7-argument function above as optional parameters without breaking every existing positional call site; `_ex` is a separate, additive 9-argument symbol instead.

**Signature**: `fractal_optimize_portfolio_multimodal_ex(mu_csv TEXT, cov_csv TEXT, k INT, n_restarts INT, overlap_threshold DOUBLE, quality_frac DOUBLE, seed BIGINT, use_obl INT, diffusion_mode TEXT) RETURNS TEXT`

**Return**: same shape as `fractal_optimize_portfolio_multimodal`.

- `use_obl`: `0`/`1` (the UDF ABI has no BOOLEAN) — Opposition-Based Learning: evaluate each SFS trial candidate's bound-reflected opposite, keep whichever fits better.
- `diffusion_mode`: `'gaussian'` (default behavior) or `'levy'`, a heavy-tailed Mantegna-algorithm step that can help escape local optima on highly multimodal problems.

All 9 arguments are required and positional; same NULL-dormant and audit-chain behavior as the function above. When the loaded enterprise library predates the `_ex` symbol, passing the default knobs (`use_obl=0`, `diffusion_mode='gaussian'`) falls back to the base function's identical search; requesting either knob on such a library returns `NULL`.

### `fractal_optimize_portfolio_multimodal_pareto`
**Enterprise tier.** Pareto-front sibling of `fractal_optimize_portfolio_multimodal`: runs the same `n_restarts` independent searches, but scores each by decomposed **(return, risk)** instead of scalar Sharpe and reduces them to a genuine non-dominated Pareto front (NSGA-II crowding-distance truncation if the front exceeds `max_front`). This is not the sharpe-threshold + asset-overlap selection the sibling above uses. Purely additive: does not change that function's selection semantics.

**Signature**: `fractal_optimize_portfolio_multimodal_pareto(mu_csv TEXT, cov_csv TEXT, k INT, n_restarts INT, max_front INT, seed BIGINT, use_obl INT, diffusion_mode TEXT) RETURNS TEXT`

**Return**: `{"n_found":N,"candidates":[{"return":..,"risk":..,"sharpe":..,"weights":[..]},...]}`, Sharpe descending. `sharpe = return/risk` is informational, not the selection criterion.

- `max_front`: cap on returned front size, `1 <= max_front <= n_restarts`.
- `use_obl`/`diffusion_mode`: same knobs and encoding as `fractal_optimize_portfolio_multimodal_ex` above, applied uniformly to every restart.

All 8 arguments are required and positional; same NULL-dormant and audit-chain behavior as above. Unlike `_ex`, this one has no fallback to a base symbol — there is no non-Pareto shape of this result to fall back to.

### `fractal_optimize_subset`
**Value-Weighted k-Subset Allocation**

Generalizes `fractal_optimize_portfolio`'s cardinality-constrained search into a pluggable-objective optimizer; this SQL entry point hardcodes value-weighted allocation: maximize `sum(weight[i] * item_values[i])` subject to at most `k` of `n_items` nonzero, each `weight <= upper_bounds[i]`, weights summing to 1.0.

**Signature**: `fractal_optimize_subset(item_values_csv TEXT, upper_bounds_csv TEXT, k INT, params TEXT) RETURNS TEXT`
**Return**: `{"score":.., "weights":[..]}` where `score` is the achieved total value (higher is better). `upper_bounds_csv` may be `''` for the core default (`[0,1]` per item). The sum of the `k` largest `upper_bounds` must reach 1.0 or no feasible k-subset exists. Turnover-penalty rebalancing (the core primitive's `prev_weights`/`turnover_penalty` knobs) is not exposed here — every call runs with it disabled; `params` is a JSON object, all keys optional (`{"seed": 0}`), pass `'{}'` for defaults.

Per-item upper bounds map naturally onto per-node capacity limits (task routing under battery/credit budgets), which is the primitive's design center.

```sql
SELECT fractal_optimize_subset('[0.12,0.09,0.15,0.06,0.11]', '[0.4,0.4,0.4,0.4,0.4]', 2, '{}');
```

---

## Named Feature Store

A generic per-item vector store for custom metadata or flagged examples. Community tier here; independent of the ledger/audit mechanism entirely (see [`enterprise.md`](enterprise.md)).

Both are stored PROCEDUREs, composing the existing `fractal_vector_l2_squared` UDF over a fixed internal table (`fractalsql_feature_store`). No dynamic SQL is needed for either: unlike the table-backed search procedures elsewhere in this doc, this table's name is fixed, not caller-supplied.

### `fractal_store_morphology`
Upserts a vector against a `doc_id`.

**Signature**: `fractal_store_morphology(doc_id BIGINT, feature_array TEXT)` — `feature_array` is a JSON-array-string vector, the same convention as `fractal_search`'s `vector_csv`/`query_csv`.

```sql
CALL fractal_store_morphology(1, '[0.1,0.2,0.3]');
```

### `fractal_mine_topology_negatives`
Brute-force k-NN scan (squared Euclidean distance) over the feature store.

**Signature**: `fractal_mine_topology_negatives(surrogate_vector TEXT, k INT, OUT result JSON)`

**Return**: `[{"doc_id":.., "dist":..}, ...]`, ascending by distance — O(n) per call, no index. Intended for a curated store (e.g. vectors flagged via `fractal_store_morphology` as rejected/negative examples), not a full corpus scan.

```sql
CALL fractal_mine_topology_negatives('[0.1,0.2,0.3]', 5, @result);
SELECT @result;
```

---

## Vector Math and Quantization

Utilities over the portable JSON vector representation (see [`vectorizer-setup.md`](vectorizer-setup.md)).

### `fractal_vector_lp_distance`
**Generalized $L_p$ Distance**

**Signature**: `fractal_vector_lp_distance(a TEXT, b TEXT, p DOUBLE) RETURNS DOUBLE`
$(\sum_i |a_i - b_i|^p)^{1/p}$ for $p > 0$, over the two vectors' shared dimension. `p = 2` is the plain Euclidean distance. For $0 < p < 1$ this is **not** a proper metric (the triangle inequality does not hold), so never substitute it silently for the search primitives' own cosine as a default distance; use it explicitly where fractional-$p$ contrast at high dimensionality is wanted, such as high-dimensional genomic or embedding similarity (L1 preserves contrast that cosine loses at dimensionality `d >= 1024`).

```sql
SELECT fractal_vector_lp_distance('[1,0,0]', '[0.9,0.1,0]', 2.0);
```

### `fractal_vector_quantize_int8` / `fractal_vector_quantize_binary` / `fractal_vector_hamming_distance`
**Per-Vector Quantization**

- `fractal_vector_quantize_int8(vec TEXT) RETURNS TEXT` → `{"scale":..,"values":[..]}`: symmetric int8 quantization, 4x compression. `values` is one signed byte per dimension, `scale` lets the caller dequantize `v[i] ≈ values[i] * scale`.
- `fractal_vector_quantize_binary(vec TEXT) RETURNS TEXT` → JSON array of packed bytes: 1-bit quantization, up to 32x compression. Bit $i$ is 1 if `v[i] >= 0`, packed MSB-first.
- `fractal_vector_hamming_distance(a_bytes TEXT, b_bytes TEXT) RETURNS INTEGER`: Hamming distance between two `fractal_vector_quantize_binary` outputs (equal byte counts required), for cheap candidate filtering ahead of a full-precision cosine/L2 re-rank.

```sql
SELECT fractal_vector_quantize_binary('[1,-2,3]') AS binary_a,
       fractal_vector_quantize_binary('[1,2,3]')  AS binary_b;
SELECT fractal_vector_hamming_distance(
    fractal_vector_quantize_binary('[1,-2,3]'),
    fractal_vector_quantize_binary('[1,2,3]'));
```
