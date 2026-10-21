-- demo/demo-vertical-satellite-constellation-coverage.sql
--
-- Industry vertical: space and satellite communications -- constellation
-- coverage monitoring.  DOMAIN kit built on two installed agents:
--
--   * fractal_agent_network_coverage_alert -- spatial morphology of the
--     constellation's footprint grid (box-counting dimension + lacunarity)
--     plus drift of a link-quality telemetry series, flagging coverage
--     gaps and dead zones.  This is the COVERAGE-GAP angle only; orbital
--     drift and collision detection are a different problem and are not
--     covered here.
--   * fractal_agent_schedule_workload -- a secondary branch that models
--     launch-manifest / payload-slot scheduling as a resource-allocation
--     problem (vector-refine + nearest-slot match).
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - The agents and fractal_search_telemetry are PROCEDUREs with a
--     trailing OUT result JSON param.  schedule_workload has no id-column
--     argument: the slot comes back as the table's own PRIMARY KEY.
--   - network_coverage_alert takes the footprint cloud as a flat
--     interleaved x,y array, the telemetry series, the box-counting
--     dimension, the drift window, the drift threshold and an optional
--     reasoning context.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agents and Section 5 call fractal_reason.  Section 2 and the
--      hand-composed nearest-slot match need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-satellite-constellation-coverage.sql
--
-- Safe to re-run: scc_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from integer
--     arithmetic and an LCG in recursive CTEs, not RAND().
--   * The footprint grid is a 20 x 20 lattice of footprint centers (400
--     points, flat interleaved x,y).  The morphology estimator needs a
--     few hundred points for a stable answer, which is why the grid is
--     this size.  The degraded constellation loses an 8 x 8 block of
--     footprints (a dead zone), which raises lacunarity (gappiness).
--   * The link-quality series is 96 samples with a regime change at 49:
--     a stable carrier followed by a fast oscillation as a relay degrades.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Footprint grids: a healthy 20 x 20 lattice and a degraded copy
-- missing an 8 x 8 block (rows 6-13, columns 6-13).
-- ------------------------------------------------------------------
-- === 1. Footprint lattices: healthy (400) vs degraded (336) ===

DROP TABLE IF EXISTS scc_footprints;
CREATE TABLE scc_footprints (
    r INT, c INT, x DOUBLE, y DOUBLE
);
INSERT INTO scc_footprints (r, c, x, y)
WITH RECURSIVE g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END
      FROM g WHERE NOT (r = 19 AND c = 19))
SELECT r, c, c + 0.06 * (MOD(r * 7 + c * 13, 10) - 5) / 5.0,
             r + 0.06 * (MOD(r * 11 + c * 3, 10) - 5) / 5.0
  FROM g;

SELECT COUNT(*) AS healthy_footprints,
       SUM(NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)) AS degraded_footprints
  FROM scc_footprints;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of each lattice.  The dead zone shows up
-- as higher lacunarity in the degraded constellation.
-- ------------------------------------------------------------------
-- === 2. Morphology: healthy vs degraded constellation ===

SET @scc_healthy = fractal_morphological_complexity(
    (SELECT CONCAT('[', GROUP_CONCAT(CONCAT(ROUND(x, 4), ',', ROUND(y, 4)) ORDER BY r, c), ']')
       FROM scc_footprints), 2);
SET @scc_degraded = fractal_morphological_complexity(
    (SELECT CONCAT('[', GROUP_CONCAT(CONCAT(ROUND(x, 4), ',', ROUND(y, 4)) ORDER BY r, c), ']')
       FROM scc_footprints WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)), 2);

SELECT 'healthy' AS constellation,
       ROUND(JSON_VALUE(@scc_healthy, '$.dimension'), 3)  AS dimension,
       ROUND(JSON_VALUE(@scc_healthy, '$.lacunarity'), 3) AS lacunarity
UNION ALL
SELECT 'degraded',
       ROUND(JSON_VALUE(@scc_degraded, '$.dimension'), 3),
       ROUND(JSON_VALUE(@scc_degraded, '$.lacunarity'), 3);

-- ------------------------------------------------------------------
-- 3. The shipped agent on the degraded constellation: morphology plus
-- link-quality drift plus a reasoned coverage alert (reasoning plugin).
-- ------------------------------------------------------------------
-- === 3. fractal_agent_network_coverage_alert (degraded constellation) ===

CALL fractal_agent_network_coverage_alert(
    (SELECT CONCAT('[', GROUP_CONCAT(CONCAT(ROUND(x, 4), ',', ROUND(y, 4)) ORDER BY r, c), ']')
       FROM scc_footprints WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)),
    (SELECT CONCAT('[', GROUP_CONCAT(ROUND(v, 4) ORDER BY t), ']')
       FROM (WITH RECURSIVE n(t, x) AS (
                    SELECT 1, 4242 UNION ALL
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
-- 4. Secondary branch: launch-manifest scheduling.  Each launch slot
-- has a capability vector [mass_margin, plane_A, plane_B, plane_C,
-- rideshare]; a replacement-satellite payload is placed on the nearest
-- slot.  Vector-refine + nearest-node match, one call.
-- ------------------------------------------------------------------
-- === 4. Launch-slot scheduling: fractal_agent_schedule_workload ===

DROP TABLE IF EXISTS scc_slots;
CREATE TABLE scc_slots (id INT PRIMARY KEY, capability JSON);
INSERT INTO scc_slots VALUES
    (1, '[0.9, 0.8, 0.0, 0.0, 0.1]'),    -- heavy lift, plane A
    (2, '[0.5, 0.0, 0.9, 0.1, 0.4]'),    -- medium lift, plane B
    (3, '[0.3, 0.0, 0.1, 0.9, 0.9]'),    -- rideshare, plane C
    (4, '[0.6, 0.1, 0.8, 0.1, 0.2]');    -- medium lift, plane B

-- --- hand-composed: nearest slot to the replacement payload ---
CALL fractal_search_telemetry('scc_slots', 'capability', '[0.5, 0.0, 0.85, 0.1, 0.35]', 1, @scc_t);
SELECT s.id AS assigned_slot, ROUND(1.0 / (1.0 + jt.dist), 4) AS confidence
  FROM JSON_TABLE(@scc_t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN scc_slots s ON s.id = jt.doc_id;

-- --- the shipped agent: same composition plus refinement, one call (reasoning plugin) ---
CALL fractal_agent_schedule_workload(
    '[0.5, 0.0, 0.85, 0.1, 0.35]', 'scc_slots', 'capability', 30, 50, 5, NULL, @r2);
SELECT JSON_VALUE(@r2, '$.assigned_node') AS assigned_slot,
       JSON_VALUE(@r2, '$.confidence')    AS confidence,
       JSON_VALUE(@r2, '$.rationale')     AS rationale;

-- ------------------------------------------------------------------
-- 5. Reasoning: the combined narrative (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: coverage gap and replacement-launch narrative ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line summary of this constellation coverage gap and the launch slot chosen to fill it',
    JSON_OBJECT('coverage', JSON_EXTRACT(@scc_degraded, '$'),
                'nearest_slot', JSON_EXTRACT(@scc_t, '$'))) AS narrative;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE scc_footprints, scc_slots;
