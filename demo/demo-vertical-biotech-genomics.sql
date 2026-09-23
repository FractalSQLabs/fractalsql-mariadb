-- demo/demo-vertical-biotech-genomics.sql
--
-- Industry vertical: Biotech & Genomics (structural bioinformatics /
-- single-cell transcriptomics).
--
-- Two showcases for the newest primitives in this extension:
--   1. fractal_tda_persistence_diagram over a synthetic point cloud
--      standing in for a PCA/UMAP-reduced scRNA-seq trajectory that
--      loops back on itself (a cell-cycle progression: G1 -> S -> G2/M
--      -> G1) -- topological data analysis is a real, published
--      technique for detecting exactly this kind of cyclic structure
--      in single-cell data (Edelsbrunner, Letscher & Zomorodian 2002).
--   2. fractal_vector_lp_distance comparing two synthetic gene-expression
--      profile vectors under L1 (Manhattan) vs the extension's default
--      L2/cosine metrics -- L1 is the more standard choice in
--      genomics for comparing expression profiles because a handful of
--      strongly differentially-expressed genes (large per-component
--      deltas) should not be allowed to dominate the distance the way
--      squaring does under L2.
--
-- SCOPE NOTE (carried verbatim from sql/install_udf.sql's own
-- fractal_tda_persistence_diagram comment -- read this before treating
-- betti1 as a full topological invariant): h0_bars is an EXACT,
-- complete 0-dimensional persistence computation. betti1 (only
-- computed when max_dim=1) is a real, correctly-computed, but
-- DIFFERENT invariant than full simplicial H1: it is the bare
-- 1-skeleton graph's cycle rank, which over-counts true H1 whenever a
-- filled triangle exists in the data. A full TDA library (Ripser/GUDHI)
-- computes true H1 via boundary-matrix reduction; this does not attempt
-- that. Good enough to flag "this trajectory has a loop", not a
-- substitute for a real homology computation in a publication pipeline.
--
-- Structural notes:
--   - fractal_tda_persistence_diagram(points_csv, dim, max_dim,
--     max_thresh, max_h0_bars) takes a FLAT, row-major n_points x dim
--     CSV string (not JSON), same convention as
--     fractal_change_point_detect's series_csv argument. n_points is
--     capped at 512.
--   - fractal_vector_lp_distance(a, b, p) takes the extension's normal
--     JSON-array-of-numbers vector representation, like every other
--     fractal_vector_* distance function.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;   (the base UDF set -- sections 0-3
--      here need nothing else, no agent/reasoning layer involved)
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-biotech-genomics.sql
--
-- Safe to re-run: vbg_* tables are dropped and recreated each time.
--
-- NOTE: MariaDB has no session-wide random seed equivalent to
-- setseed(). RAND() here is unseeded, so exact jitter values differ
-- run to run -- the demo's narrative points (a real loop in Section 2,
-- L1 vs L2 disagreeing in Section 3) are still deterministic.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. A synthetic 24-point, 2-D pseudotime trajectory tracing a closed
-- loop (a circle with small jitter) -- standing in for a PCA-reduced
-- scRNA-seq cell-cycle trajectory (G1 -> S -> G2/M -> back to G1).
-- ------------------------------------------------------------------
-- === 1. 24-point synthetic cell-cycle pseudotime loop (2-D) ===

DROP TABLE IF EXISTS vbg_trajectory;
CREATE TABLE vbg_trajectory (id INT AUTO_INCREMENT PRIMARY KEY, cell_phase VARCHAR(16), x DOUBLE, y DOUBLE);

INSERT INTO vbg_trajectory (cell_phase, x, y)
WITH RECURSIVE seq(gs) AS (
    SELECT 0 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 23
)
SELECT CASE WHEN MOD(gs, 24) < 6 THEN 'G1'
            WHEN MOD(gs, 24) < 12 THEN 'S'
            WHEN MOD(gs, 24) < 18 THEN 'G2'
            ELSE 'M' END,
       COS(2 * PI() * gs / 24) + (RAND() - 0.5) * 0.08,
       SIN(2 * PI() * gs / 24) + (RAND() - 0.5) * 0.08
FROM seq;

SELECT COUNT(*) AS n_points FROM vbg_trajectory;

-- ------------------------------------------------------------------
-- 2. TDA persistence diagram over the trajectory: h0_bars confirms the
-- point cloud is a single connected component at a reasonable
-- Vietoris-Rips threshold (not several disjoint clusters), and betti1
-- picks up the cell-cycle loop structure -- exactly the closed-loop
-- signal a linear PCA-variance or clustering approach would miss
-- entirely (a circle has no "cluster centers").
-- ------------------------------------------------------------------
-- === 2. fractal_tda_persistence_diagram: cell-cycle loop detection ===

SET @vbg_points = (
    SELECT GROUP_CONCAT(v ORDER BY id, ord SEPARATOR ',')
      FROM (
          SELECT id, 1 AS ord, x AS v FROM vbg_trajectory
          UNION ALL
          SELECT id, 2 AS ord, y AS v FROM vbg_trajectory
      ) flat
);
-- max_thresh=0.40: adjacent-on-the-loop points sit ~0.26 apart (a
-- 24-point unit circle) plus up to ~0.08 jitter, so 0.40 connects real
-- ring neighbors without also connecting chords across the loop.
-- Verified empirically: a threshold much above this (e.g. 0.6) starts
-- connecting non-adjacent points across the circle, inflating betti1
-- into the dozens from spurious chords -- not a loop-detection result
-- at all, just a dense near-complete graph. This is a real, load-
-- bearing tuning choice for the Vietoris-Rips filtration, not
-- cosmetic.
SET @vbg_tda = fractal_tda_persistence_diagram(@vbg_points, 2, 1, 0.40, 16);

SELECT JSON_VALUE(@vbg_tda, '$.n_h0_bars') AS n_h0_bars,
       JSON_VALUE(@vbg_tda, '$.betti1')    AS betti1_cycle_rank;
-- betti1_cycle_rank > 0 here means the 1-skeleton graph at this
-- threshold has at least one independent cycle -- consistent with (not
-- formal proof of) a genuine closed trajectory in the underlying
-- biology, per the scope note above.

SELECT jt.birth, jt.death
  FROM JSON_TABLE(@vbg_tda, '$.h0_bars[*]' COLUMNS (
           birth DOUBLE PATH '$.birth',
           death DOUBLE PATH '$.death')) jt
 ORDER BY jt.death - jt.birth DESC
 LIMIT 5;

-- ------------------------------------------------------------------
-- 3. Two synthetic gene-expression profile vectors (12 marker genes),
-- one with a handful of strongly differentially-expressed genes --
-- L1 (Manhattan) vs the extension's default L2 distance disagree on
-- how much that handful of outlier deltas should dominate the overall
-- distance.
-- ------------------------------------------------------------------
-- === 3. fractal_vector_lp_distance: L1 vs L2 on an expression profile ===

SET @vbg_profile_a = '[0.10, 0.22, 0.05, 0.31, 0.44, 0.09, 0.18, 0.27, 0.15, 0.08, 0.36, 0.21]';
SET @vbg_profile_b = '[0.11, 4.80, 0.06, 0.30, 5.20, 0.10, 0.19, 0.26, 0.14, 0.09, 4.95, 0.20]';
-- profile_b: 10 of 12 genes barely move from profile_a; 3 genes (index
-- 1, 4, 10) spike hard -- a plausible differential-expression pattern.

SELECT fractal_vector_lp_distance(@vbg_profile_a, @vbg_profile_b, 1.0) AS l1_manhattan_distance,
       fractal_vector_lp_distance(@vbg_profile_a, @vbg_profile_b, 2.0) AS l2_euclidean_distance,
       fractal_vector_l2_distance(@vbg_profile_a, @vbg_profile_b)      AS default_l2_distance;
-- l2_euclidean_distance and default_l2_distance should match (p=2 is
-- mathematically the same metric as the extension's dedicated L2
-- function, though not bit-for-bit identical -- see this UDF's own
-- doc comment in sql/install_udf.sql). l1_manhattan_distance summing
-- absolute deltas linearly, rather than squaring them, is the more
-- interpretable "total expression change" figure for this use case.

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE vbg_trajectory;
