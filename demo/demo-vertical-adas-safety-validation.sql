-- demo/demo-vertical-adas-safety-validation.sql
--
-- Industry vertical: ADAS / autonomous-driving safety validation --
-- edge-case interception before a maneuver is committed.  AGENTIC kit:
-- two signals are composed, shown hand-composed first and then as the
-- shipped one-call agent.
--
--   1. fractal_agent_outlier_intercept -- a pre-commit safety barrier:
--      screens a PROPOSED vehicle state vector against a history of
--      known-bad states (prior disengagements and near-misses), exactly
--      its designed contract.
--   2. fractal_search_trajectory -- flags when the vehicle's current
--      routing vector has moved away from the fleet baseline.
--   3. A closing fractal_reason() turns both signals into one verdict.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_outlier_intercept, fractal_search_telemetry and
--     fractal_search_trajectory are PROCEDUREs with a trailing OUT result
--     JSON param: `CALL x(...args, @r); SELECT JSON_VALUE(@r, ...)`.
--     doc_ids are the table's real PRIMARY KEY values.
--   - the metric argument of outlier_intercept is explicit ('cosine' or
--     'l2'); any other value is an error, never a silent fallback.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      outlier_intercept agent returns a reasoned `reason`, and Section 5
--      calls fractal_reason.  The hand-composed steps need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-adas-safety-validation.sql
--
-- Safe to re-run: asv_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * State vectors are [speed_z, lateral_accel_z, brake_z, steer_rate_z]
--     as JSON arrays.  The intercept distance is COSINE by default, which
--     ignores magnitude: a mild maneuver in the same direction as a known-
--     bad one is intercepted too.  Pass 'l2' when magnitude should count
--     (Section 3).

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Known-bad state history and three proposed maneuvers.
-- ------------------------------------------------------------------
-- === 1. Known-bad history + proposed maneuvers ===

DROP TABLE IF EXISTS asv_known_bad;
CREATE TABLE asv_known_bad (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    scenario VARCHAR(64),
    state    JSON,
    CONSTRAINT asv_bad_dims CHECK (JSON_LENGTH(state) = 4)
);
INSERT INTO asv_known_bad (scenario, state) VALUES
    ('hard brake at highway speed',   '[0.90, 0.10, 0.95, 0.10]'),
    ('evasive swerve',                '[0.50, 0.90, 0.20, 0.95]'),
    ('late brake approaching a stop', '[0.40, 0.05, 0.90, 0.05]'),
    ('lane drift under load',         '[0.70, 0.60, 0.05, 0.30]');

DROP TABLE IF EXISTS asv_proposed;
CREATE TABLE asv_proposed (
    id    INT AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(64),
    state JSON,
    CONSTRAINT asv_prop_dims CHECK (JSON_LENGTH(state) = 4)
);
INSERT INTO asv_proposed (label, state) VALUES
    ('P1 firm brake, high speed',   '[0.88, 0.12, 0.90, 0.15]'),
    ('P2 steady cruise',            '[0.55, 0.02, 0.02, 0.01]'),
    ('P3 gentle lane change',       '[0.45, 0.35, 0.05, 0.30]');

SELECT COUNT(*) AS known_bad_states FROM asv_known_bad;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: nearest known-bad state per proposal,
-- threshold 0.15 (cosine).  One CALL per proposal.
-- ------------------------------------------------------------------
-- === 2. Step 1 (hand-composed): nearest known-bad state, threshold 0.15 ===

CALL fractal_search_telemetry('asv_known_bad', 'state',
    (SELECT state FROM asv_proposed WHERE id = 1), 1, @asv_t1);
CALL fractal_search_telemetry('asv_known_bad', 'state',
    (SELECT state FROM asv_proposed WHERE id = 2), 1, @asv_t2);
CALL fractal_search_telemetry('asv_known_bad', 'state',
    (SELECT state FROM asv_proposed WHERE id = 3), 1, @asv_t3);

SELECT p.label, k.scenario AS nearest_bad, ROUND(jt.dist, 4) AS distance,
       (jt.dist < 0.15) AS intercepted
  FROM (SELECT 1 AS pid, @asv_t1 AS r UNION ALL SELECT 2, @asv_t2 UNION ALL SELECT 3, @asv_t3) q
  JOIN JSON_TABLE(q.r, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN asv_proposed p ON p.id = q.pid
  JOIN asv_known_bad k ON k.id = jt.doc_id
 ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent (its `reason` field is
-- reasoning-bearing).  Note P3: the cosine check intercepts it (same
-- direction as the known-bad lane drift, just gentler); exact Euclidean
-- distance lets it through because magnitude counts.
-- ------------------------------------------------------------------
-- === 3. Step 1 (shipped agent): fractal_agent_outlier_intercept ===

CALL fractal_agent_outlier_intercept(
    (SELECT state FROM asv_proposed WHERE id = 1), 'asv_known_bad', 'state', 0.15, 'cosine', @asv_o1);
CALL fractal_agent_outlier_intercept(
    (SELECT state FROM asv_proposed WHERE id = 2), 'asv_known_bad', 'state', 0.15, 'cosine', @asv_o2);
CALL fractal_agent_outlier_intercept(
    (SELECT state FROM asv_proposed WHERE id = 3), 'asv_known_bad', 'state', 0.15, 'cosine', @asv_o3);
SELECT 'P1 firm brake, high speed' AS label, JSON_VALUE(@asv_o1, '$.intercepted') AS intercepted,
       JSON_VALUE(@asv_o1, '$.nearest_distance') AS nearest_distance, JSON_VALUE(@asv_o1, '$.reason') AS reason
UNION ALL
SELECT 'P2 steady cruise', JSON_VALUE(@asv_o2, '$.intercepted'),
       JSON_VALUE(@asv_o2, '$.nearest_distance'), JSON_VALUE(@asv_o2, '$.reason')
UNION ALL
SELECT 'P3 gentle lane change', JSON_VALUE(@asv_o3, '$.intercepted'),
       JSON_VALUE(@asv_o3, '$.nearest_distance'), JSON_VALUE(@asv_o3, '$.reason');

-- --- same check under exact Euclidean distance (magnitude counts) ---
CALL fractal_agent_outlier_intercept(
    (SELECT state FROM asv_proposed WHERE id = 1), 'asv_known_bad', 'state', 0.30, 'l2', @asv_l1);
CALL fractal_agent_outlier_intercept(
    (SELECT state FROM asv_proposed WHERE id = 2), 'asv_known_bad', 'state', 0.30, 'l2', @asv_l2);
CALL fractal_agent_outlier_intercept(
    (SELECT state FROM asv_proposed WHERE id = 3), 'asv_known_bad', 'state', 0.30, 'l2', @asv_l3);
SELECT 'P1 firm brake, high speed' AS label, JSON_VALUE(@asv_l1, '$.intercepted') AS intercepted_l2
UNION ALL SELECT 'P2 steady cruise', JSON_VALUE(@asv_l2, '$.intercepted')
UNION ALL SELECT 'P3 gentle lane change', JSON_VALUE(@asv_l3, '$.intercepted');

-- ------------------------------------------------------------------
-- 4. Step 2: routing deviation from the fleet baseline.  40 fleet
-- vehicles on three lane/speed bands; vehicle V-17's routing vector
-- (lateral offset, heading, speed) is compared against the fleet
-- baseline.  The nearest fleet members to the baseline and to the
-- current vector show how far this vehicle has strayed.
-- ------------------------------------------------------------------
-- === 4. Step 2: routing deviation from the fleet baseline ===

DROP TABLE IF EXISTS asv_routes;
CREATE TABLE asv_routes (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    vehicle VARCHAR(16),
    route   JSON,
    CONSTRAINT asv_route_dims CHECK (JSON_LENGTH(route) = 3)
);
INSERT INTO asv_routes (vehicle, route)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 40)
SELECT CONCAT('V-', g),
       JSON_ARRAY(0.10 * MOD(g, 3) + 0.01 * MOD(g, 7),            -- lateral offset
                  0.05 * MOD(g, 4),                               -- heading error
                  0.60 + 0.05 * MOD(g, 3) + 0.004 * MOD(g, 5))    -- speed band
  FROM gs;

CALL fractal_search_trajectory('asv_routes', 'route',
    '[0.100, 0.050, 0.650]',      -- fleet baseline routing vector
    '[0.900, 0.800, 0.200]',      -- V-17 now: far off its lane/speed band
    3, @asv_route);

SELECT r.vehicle, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@asv_route, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN asv_routes r ON r.id = jt.doc_id
 ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 5. Reasoning: one go / no-go verdict over both signals (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: go / no-go verdict for proposal P1 ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line go/no-go safety verdict for this proposed ADAS maneuver',
    JSON_OBJECT('intercept', JSON_EXTRACT(@asv_o1, '$'),
                'routing_deviation', JSON_EXTRACT(@asv_route, '$'))) AS verdict;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE asv_known_bad, asv_proposed, asv_routes;
