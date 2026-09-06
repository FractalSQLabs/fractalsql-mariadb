<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Analytics API Reference

The Analytics tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into structural insights.

MariaDB has no `float8[]`/`int4[]` array types and no `DEFAULT`-argument syntax for `CREATE FUNCTION`. Every argument that would be a postgres array here is a CSV-or-bracketed-JSON-array **string** instead (the same convention `fractal_search`'s own `vector_csv`/`query_csv` arguments already use: `'1,2,3'` or `'[1,2,3]'`), and every postgres trailing-`DEFAULT` scalar argument is bundled into one trailing JSON `params` string instead. `jsonb` return types become JSON-valid `STRING` results.

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

> The Enterprise-tier variants `fractal_optimize_portfolio_multimodal`/`_multimodal_pareto` and the Named Feature Store (`fractal_store_morphology`/`fractal_mine_topology_negatives`) are not available in this edition. See [`enterprise.md`](enterprise.md) for what the Enterprise tier actually covers here (ledger/audit gating, not additional Analytics-tier search variants).
