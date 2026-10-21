-- demo/demo-vertical-climatech-risk-exposure.sql
--
-- Industry vertical: Climate Tech -- physical climate-risk exposure
-- monitoring for insurers and asset managers (wildfire, flood, drought
-- hazard sensor grids).  DOMAIN kit built on one installed agent,
-- fractal_agent_network_coverage_alert, reused verbatim: spatial
-- morphology (box-counting dimension + lacunarity) of the hazard grid
-- plus drift of a telemetry series, closing with a risk-exposure
-- narrative.  The kit is shaped like the smart-cities kit's sensor grid,
-- over climate-hazard readings instead of urban IoT sensors.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_network_coverage_alert is a PROCEDURE with a trailing
--     OUT result JSON param: `CALL ...(point_cloud, drift_series,
--     boxcount_dim, drift_win, drift_threshold, context, @r)`.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent and Section 4 call fractal_reason.  The hand-composed
--      morphology needs no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-climatech-risk-exposure.sql
--
-- Safe to re-run: cre_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from integer
--     arithmetic and an LCG in recursive CTEs, not RAND().
--   * A 20 x 20 sensor grid (400 cells).  A cell is "high hazard" when its
--     fuel-moisture deficit index exceeds 0.40 in the dry season (0.25 in
--     the wet season, where the index runs about half as high).  In the
--     dry season the high-hazard region is large and clumped toward the
--     south-west; in the wet season it is smaller.  The point cloud handed
--     to the morphology estimator is the set of high-hazard cell centers
--     (flat interleaved x,y); it needs a couple of hundred points for a
--     stable estimate, which is why the dry-season cloud is the one the
--     shipped agent is run on.
--   * The drift series is the regional fuel-moisture telemetry: stable
--     for 48 days, then a rapid oscillation as a heat wave begins.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Hazard grid: a fuel-moisture deficit index per cell for the dry
-- and wet seasons.
-- ------------------------------------------------------------------
-- === 1. 20 x 20 hazard grid, dry vs wet season ===

DROP TABLE IF EXISTS cre_grid;
CREATE TABLE cre_grid (
    r INT, c INT,
    dry_index DOUBLE,
    wet_index DOUBLE
);
INSERT INTO cre_grid (r, c, dry_index, wet_index)
WITH RECURSIVE g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END
      FROM g WHERE NOT (r = 19 AND c = 19))
SELECT r, c,
       (19 - r) / 19.0 * 0.5 + (19 - c) / 19.0 * 0.3 + MOD(r * 5 + c * 3, 7) / 70.0 + 0.05,
       ((19 - r) / 19.0 * 0.5 + (19 - c) / 19.0 * 0.3 + MOD(r * 5 + c * 3, 7) / 70.0) * 0.55
  FROM g;

SELECT SUM(dry_index > 0.40) AS high_hazard_cells_dry,
       SUM(wet_index > 0.25) AS elevated_cells_wet
  FROM cre_grid;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of the elevated-hazard region in each
-- season (dry: index > 0.40; wet: index > 0.25, since the wet-season
-- index runs about half as high).  The dry-season region is large and
-- compact; the wet-season region is smaller and gappier.
-- ------------------------------------------------------------------
-- === 2. Morphology of the high-hazard region ===

SET @cre_dry = fractal_morphological_complexity(
    (SELECT CONCAT('[', GROUP_CONCAT(CONCAT(c, ',', r) ORDER BY r, c), ']')
       FROM cre_grid WHERE dry_index > 0.40), 2);
SET @cre_wet = fractal_morphological_complexity(
    (SELECT CONCAT('[', GROUP_CONCAT(CONCAT(c, ',', r) ORDER BY r, c), ']')
       FROM cre_grid WHERE wet_index > 0.25), 2);

SELECT 'dry season' AS season,
       ROUND(JSON_VALUE(@cre_dry, '$.dimension'), 3)  AS dimension,
       ROUND(JSON_VALUE(@cre_dry, '$.lacunarity'), 3) AS lacunarity
UNION ALL
SELECT 'wet season',
       ROUND(JSON_VALUE(@cre_wet, '$.dimension'), 3),
       ROUND(JSON_VALUE(@cre_wet, '$.lacunarity'), 3);

-- ------------------------------------------------------------------
-- 3. The shipped agent on the dry season: morphology + fuel-moisture
-- drift + a reasoned exposure alert (reasoning plugin).
-- ------------------------------------------------------------------
-- === 3. fractal_agent_network_coverage_alert (dry-season exposure) ===

CALL fractal_agent_network_coverage_alert(
    (SELECT CONCAT('[', GROUP_CONCAT(CONCAT(c, ',', r) ORDER BY r, c), ']')
       FROM cre_grid WHERE dry_index > 0.40),
    (SELECT CONCAT('[', GROUP_CONCAT(ROUND(v, 4) ORDER BY t), ']')
       FROM (WITH RECURSIVE n(t, x) AS (
                    SELECT 1, 2718 UNION ALL
                    SELECT t + 1, MOD(x * 1103515245 + 12345, 2147483648) FROM n WHERE t < 96)
             SELECT t,
                    CASE WHEN t < 49
                         THEN 4.0 + 1.5 * SIN(t * 0.31) + (MOD(x DIV 65536, 1000) - 500) / 1250.0
                         ELSE 4.0 + 3.0 * SIN(t * 1.4)  + (MOD(x DIV 65536, 1000) - 500) / 2500.0
                    END AS v FROM n) s),
    2, 48, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.morph_dimension') AS morph_dimension,
       JSON_VALUE(@r, '$.lacunarity')      AS lacunarity,
       JSON_VALUE(@r, '$.drift_detected')  AS drift_detected,
       JSON_VALUE(@r, '$.rationale')       AS rationale;

-- ------------------------------------------------------------------
-- 4. Reasoning: the risk-exposure narrative (needs the reasoning
-- plugin).
-- ------------------------------------------------------------------
-- === 4. Reasoning: risk-exposure narrative ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line physical-climate-risk exposure narrative for an insured portfolio in this region',
    JSON_EXTRACT(@cre_dry, '$')) AS narrative;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE cre_grid;
