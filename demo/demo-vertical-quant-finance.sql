-- demo/demo-vertical-quant-finance.sql
--
-- Industry vertical: Quantitative Finance & Algorithmic Trading.
--
-- A cardinality-constrained portfolio problem (25 synthetic assets, a
-- 4-factor covariance model, optimize down to an 8-asset book) plus a
-- price series with a deliberate volatility regime change for DFA-based
-- regime detection -- a real, established DFA application (detecting
-- when a market series stops behaving like its own recent history).
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- full account):
--   - every fractal_agent_* engine is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field');`
--   - fractal_search_trajectory returns REAL vqf_allocation_snapshots.id
--     values as doc_id, so no remap is needed anywhere in this file.
--   - fractal_agent_rebalance_sibling's trailing args are (seed BIGINT,
--     context TEXT), see sql/install_agents.sql's own Engine K comment.
--   - fractal_optimize_portfolio takes mu/cov as JSON-array-string
--     arguments (cov: a flat, row-major n*n covariance array) plus a
--     JSON params object bundling seed/use_obl/diffusion_mode, rather
--     than trailing DEFAULT scalar arguments (MariaDB's CREATE
--     FUNCTION has no DEFAULT-argument syntax).
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_regime_triage,
--      fractal_agent_rebalance_sibling -- sections 0-2 need nothing else)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- Sections 3 and 4's
--      presets call fractal_reason internally.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-quant-finance.sql
--
-- Safe to re-run: vqf_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() here is
-- unseeded, so exact values differ run to run -- the demo's narrative
-- points, like the t=150 volatility regime change, are still
-- deterministic). Section markers below are plain comments, not
-- executed statements.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 25 synthetic assets, 4-factor covariance model (same construction
-- style as fractalsql-core's own portfolio-optimizer factor-model test
-- fixture): cov[i,j] = sum_f loadings[i,f]*loadings[j,f] + idio[i] on
-- the diagonal. mu is each asset's expected return.
-- ------------------------------------------------------------------
-- === 1. 25 synthetic assets, 4-factor covariance model ===

DROP TABLE IF EXISTS vqf_assets;
DROP TABLE IF EXISTS vqf_loadings;
CREATE TABLE vqf_assets (asset_id INT PRIMARY KEY, symbol VARCHAR(16), mu DOUBLE, idio DOUBLE);
CREATE TABLE vqf_loadings (asset_id INT, factor_id INT, loading DOUBLE, PRIMARY KEY (asset_id, factor_id));

-- generate_series(1, n) has no MariaDB equivalent; a recursive CTE
-- replaces it, the same idiom demo-agents.sql/demo-business-intelligence.sql
-- already use.
INSERT INTO vqf_assets (asset_id, symbol, mu, idio)
WITH RECURSIVE seq(a) AS (
    SELECT 1 UNION ALL SELECT a + 1 FROM seq WHERE a < 25
)
SELECT a, CONCAT('TICK', a), -0.02 + RAND() * 0.17, 0.02 + RAND() * 0.06
FROM seq;

INSERT INTO vqf_loadings (asset_id, factor_id, loading)
WITH RECURSIVE seq(f) AS (
    SELECT 1 UNION ALL SELECT f + 1 FROM seq WHERE f < 4
)
SELECT a.asset_id, seq.f, (RAND() - 0.5) * 0.6
FROM vqf_assets a
CROSS JOIN seq;

-- Flat, row-major n*n covariance array -- exactly what
-- fractal_optimize_portfolio(mu, cov, k, params) expects for cov.
DROP TEMPORARY TABLE IF EXISTS vqf_cov_flat;
CREATE TEMPORARY TABLE vqf_cov_flat AS
SELECT ai.asset_id AS i, aj.asset_id AS j,
       (SELECT SUM(li.loading * lj.loading)
          FROM vqf_loadings li, vqf_loadings lj
         WHERE li.asset_id = ai.asset_id AND lj.asset_id = aj.asset_id
           AND li.factor_id = lj.factor_id)
       + CASE WHEN ai.asset_id = aj.asset_id THEN ai.idio ELSE 0 END AS cov_ij
FROM vqf_assets ai
CROSS JOIN vqf_assets aj;

SELECT COUNT(*) AS assets, (SELECT COUNT(*) FROM vqf_cov_flat) AS cov_entries FROM vqf_assets;

-- ------------------------------------------------------------------
-- 2. Cardinality-constrained Sharpe-ratio optimization: pick the best
-- 8 of 25 assets. ~28x faster than scipy differential_evolution at
-- near-equal quality on this problem class (validated separately,
-- see fractalsql-core's optimizer work) -- the one place the SFS
-- engine has a proven edge.
-- ------------------------------------------------------------------
-- === 2. fractal_optimize_portfolio: best 8-of-25 asset book ===

-- Blueprint (raw primitive): the SFS cardinality-constrained Sharpe
-- maximizer (pick the best 8 of 25 assets). Generalized by the shipped
-- fractal_agent_rebalance_sibling preset in Section 4, which runs this
-- optimizer, finds the nearest historical allocation pattern
-- (fractal_search_trajectory over the Section 4 snapshot fixture), and
-- reasons -- so the preset call sits after that fixture is built.
-- SET @vqf_mu  = (SELECT JSON_ARRAYAGG(mu ORDER BY asset_id) FROM vqf_assets);
-- SET @vqf_cov = (SELECT JSON_ARRAYAGG(cov_ij ORDER BY i, j) FROM vqf_cov_flat);
-- SET @vqf_opt = fractal_optimize_portfolio(@vqf_mu, @vqf_cov, 8, '{"seed": 42}');
--
-- SELECT JSON_VALUE(@vqf_opt, '$.sharpe') AS sharpe;
-- SELECT a.symbol, w.weight
--   FROM JSON_TABLE(@vqf_opt, '$.weights[*]' COLUMNS (weight DOUBLE PATH '$', ord FOR ORDINALITY)) w
--   JOIN vqf_assets a ON a.asset_id = w.ord
--  WHERE w.weight > 1e-9
--  ORDER BY w.weight DESC;
-- (raw optimizer form preserved above; productized as fractal_agent_rebalance_sibling in Section 4)

-- ------------------------------------------------------------------
-- 3. A 300-point price series with a deliberate volatility regime
-- change at t=150 (low-vol -> high-vol) -- fractal_dimension_dfa's
-- self-check pattern (white noise ~0.5, random walk ~1.5) applied to
-- something with an actual regime change baked in, and
-- fractal_dimension_drift(series, win) to detect it automatically
-- rather than eyeballing the exponent.
-- ------------------------------------------------------------------
-- === 3. Price series with a volatility regime change at t=150 ===

DROP TEMPORARY TABLE IF EXISTS vqf_price_series;
CREATE TEMPORARY TABLE vqf_price_series (series JSON);
INSERT INTO vqf_price_series (series)
SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']')
FROM (
    SELECT t, SUM(step) OVER (ORDER BY t) AS cum
    FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 300)
        SELECT t, CASE WHEN t <= 150 THEN (RAND() - 0.5) * 0.02
                       ELSE                (RAND() - 0.5) * 0.14 END AS step
        FROM seq
    ) s
) c;

-- Blueprint (raw primitives): the price series' DFA exponent (long-range
-- correlation) and its drift report (regime-change detection). Generalized
-- below by the shipped fractal_agent_regime_triage preset, which runs both
-- over the same series and reasons.
-- SELECT fractal_dimension_dfa((SELECT series FROM vqf_price_series)) AS whole_series_alpha;
-- SELECT fractal_dimension_drift((SELECT series FROM vqf_price_series), 64) AS drift_report;

-- Productized preset: the shipped engine returns the real DFA exponent,
-- the real drift_detected flag (|drift| > 0.5), and the real
-- recent_alpha/baseline_alpha, plus a real rationale.
-- --- Preset: fractal_agent_regime_triage (raw dfa+drift form preserved above) ---
CALL fractal_agent_regime_triage(
    (SELECT series FROM vqf_price_series), 64, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.drift_detected') AS drift_detected,
       JSON_VALUE(@r, '$.recent_alpha') AS recent_alpha,
       JSON_VALUE(@r, '$.baseline_alpha') AS baseline_alpha,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: which of 10 historical quarterly
-- rebalance snapshots does THIS rebalance (equal-weight baseline ->
-- the optimized book from Section 2) most resemble? "What changed",
-- not "what's closest" -- the natural query shape for drift.
-- ------------------------------------------------------------------
-- === 4. fractal_search_trajectory: nearest historical rebalance pattern ===

DROP TABLE IF EXISTS vqf_allocation_snapshots;
-- JSON, not a fixed-width vector column: MariaDB's vector storage
-- convention (see sql/install_udf.sql's "REPRESENTATION" note) is a
-- JSON-array-of-numbers string holding a fixed-width one-weight-per-
-- asset shape, without a distinct column type for it.
CREATE TABLE vqf_allocation_snapshots (id BIGINT AUTO_INCREMENT PRIMARY KEY, quarter VARCHAR(32), alloc JSON);

-- Flat CROSS JOIN, not a correlated subquery: an uncorrelated
-- subquery body (one that never references the outer per-snapshot row)
-- can get evaluated once and reused for every row in some query
-- planners, silently making every "quarter" identical despite RAND()
-- being volatile. A flat cross join has no nested subquery to hoist,
-- so every (snapshot, asset) pair gets its own RAND() call, provably.
DROP TEMPORARY TABLE IF EXISTS vqf_snapshot_raw;
CREATE TEMPORARY TABLE vqf_snapshot_raw AS
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 10
)
SELECT seq.gs AS snapshot_id, a.asset_id,
       CASE WHEN RAND() < 0.35 THEN RAND() ELSE 0 END AS raw_val
FROM seq
CROSS JOIN vqf_assets a;

DROP TEMPORARY TABLE IF EXISTS vqf_snapshot_sums;
CREATE TEMPORARY TABLE vqf_snapshot_sums AS
SELECT snapshot_id, GREATEST(SUM(raw_val), 1e-9) AS total
FROM vqf_snapshot_raw
GROUP BY snapshot_id;

INSERT INTO vqf_allocation_snapshots (quarter, alloc)
SELECT CONCAT('Q', r.snapshot_id, '-hist'),
       CONCAT('[', GROUP_CONCAT(r.raw_val / s.total ORDER BY r.asset_id), ']')
FROM vqf_snapshot_raw r
JOIN vqf_snapshot_sums s ON s.snapshot_id = r.snapshot_id
GROUP BY r.snapshot_id, s.total
ORDER BY r.snapshot_id;

-- Blueprint (raw primitive): the nearest historical rebalance pattern to
-- the optimized book (equal-weight baseline -> the Section 2 optimized
-- weights). Generalized below by the shipped fractal_agent_rebalance_sibling
-- preset, which runs the optimizer itself, finds this nearest pattern, and
-- reasons. doc_id in the result is already vqf_allocation_snapshots' real
-- `id` column (fractal_search_trajectory resolves the table's own PRIMARY
-- KEY internally), so no remap is needed here.
-- SET @vqf_baseline = (SELECT JSON_ARRAYAGG(1.0 / 25.0 ORDER BY asset_id) FROM vqf_assets);
-- CALL fractal_search_trajectory(
--     'vqf_allocation_snapshots', 'alloc', @vqf_baseline, @vqf_opt_weights, 3, @vqf_traj
-- );
-- SELECT snap.quarter, jt.dist AS distance
--   FROM JSON_TABLE(@vqf_traj, '$[*]' COLUMNS (doc_id BIGINT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
--   JOIN vqf_allocation_snapshots snap ON snap.id = jt.doc_id
--  ORDER BY jt.dist;

-- Productized preset: the shipped engine runs the SFS optimizer
-- (best 8-of-25), finds the nearest historical allocation pattern to the
-- equal-weight baseline -> optimized weights, resolves it to the real
-- snapshot id directly (no ctid/row_number remap, see above), and
-- reasons. sharpe/weights/nearest_alloc_id/nearest_distance are real;
-- rationale is the real fractal_reason output. Trailing args are (seed,
-- context), not (k, id_col) -- see this file's header.
-- --- Preset: fractal_agent_rebalance_sibling (raw optimizer+trajectory form preserved above) ---
CALL fractal_agent_rebalance_sibling(
    (SELECT JSON_ARRAYAGG(mu ORDER BY asset_id) FROM vqf_assets),
    (SELECT JSON_ARRAYAGG(cov_ij ORDER BY i, j) FROM vqf_cov_flat),
    8, 'vqf_allocation_snapshots', 'alloc',
    (SELECT JSON_ARRAYAGG(1.0 / 25.0 ORDER BY asset_id) FROM vqf_assets),
    42, NULL, @r);
SELECT JSON_VALUE(@r, '$.sharpe') AS sharpe,
       JSON_EXTRACT(@r, '$.weights') AS weights,
       JSON_VALUE(@r, '$.nearest_alloc_id') AS nearest_alloc_id,
       JSON_VALUE(@r, '$.nearest_distance') AS nearest_distance,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 5. Reasoning: the regime-shift + optimized-allocation narrative is now
-- split across two preset rationales -- fractal_agent_regime_triage
-- (Section 3, the market regime shift) and fractal_agent_rebalance_sibling
-- (Section 4, the optimized book + its nearest historical pattern).
-- ------------------------------------------------------------------
-- === 5. Reasoning: absorbed into the Section 3 + Section 4 preset rationales ===

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vqf_assets, vqf_loadings, vqf_allocation_snapshots;
