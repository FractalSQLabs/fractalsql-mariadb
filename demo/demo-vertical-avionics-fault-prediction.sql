-- demo/demo-vertical-avionics-fault-prediction.sql
--
-- Industry vertical: aerospace -- avionics and flight-path fault
-- prediction across a fleet.  DOMAIN kit built on one installed agent,
-- fractal_agent_track_anomaly, which generalizes directly from the
-- maritime-defense kit's 2D tracks to 3D flight paths: same agent, same
-- contract (trajectory deviation search + heading-change DFA exponent),
-- closing with a reasoned classification of the deviation.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_track_anomaly is a PROCEDURE with a trailing OUT
--     result JSON param and no id-column argument: the nearest fleet
--     member comes back as the table's own PRIMARY KEY.  Its signature is
--     (track_table, emb_col, baseline_vec, current_vec, heading_series,
--     OUT p_result).
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent and Section 5 call fractal_reason.  Sections 1-3 need no
--      model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-avionics-fault-prediction.sql
--
-- Safe to re-run: afp_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: heading noise comes from an integer
--     LCG in a recursive CTE, not RAND().
--   * Each flight carries a planned-path vector and its latest-state
--     vector, [x_km, y_km, altitude_km] as JSON arrays guarded by a CHECK
--     on their length.  Flight AC-09 has a stuck control surface: its
--     path has drifted off plan and its heading changes become erratic for
--     a stretch of the flight.
--   * DFA needs a reasonable series length (a few dozen points at
--     minimum); the heading series here is 120 samples.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. A 12-aircraft fleet: planned path vs current state in 3D.  Eleven
-- are on plan to within small offsets; AC-09 has drifted far off plan
-- (lateral and vertical).
-- ------------------------------------------------------------------
-- === 1. Fleet: planned path vs current state (3D) ===

DROP TABLE IF EXISTS afp_flights;
CREATE TABLE afp_flights (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    flight      VARCHAR(8),
    baseline    JSON,
    current_pos JSON,
    CONSTRAINT afp_baseline_dims CHECK (JSON_LENGTH(baseline) = 3),
    CONSTRAINT afp_current_dims  CHECK (JSON_LENGTH(current_pos) = 3)
);

INSERT INTO afp_flights (flight, baseline, current_pos)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 12)
SELECT CONCAT('AC-', LPAD(g, 2, '0')),
       JSON_ARRAY(0.20 + 0.05 * g, 0.40 + 0.02 * MOD(g, 4), 0.80),
       JSON_ARRAY(0.20 + 0.05 * g + 0.004 * MOD(g, 3),
                  0.40 + 0.02 * MOD(g, 4) + 0.003 * MOD(g, 2),
                  0.80 - 0.002 * MOD(g, 3))
  FROM gs;

-- AC-09: far off plan.
UPDATE afp_flights SET current_pos = '[0.900, 1.400, 0.350]' WHERE flight = 'AC-09';

SELECT flight, baseline, current_pos FROM afp_flights WHERE flight IN ('AC-01', 'AC-09');

-- ------------------------------------------------------------------
-- 2. Heading-change series: a steady transit (small noise) vs AC-09's
-- erratic stretch (large swings between samples 60 and 90).  The
-- running sum is the heading walk the DFA exponent is computed on.
-- ------------------------------------------------------------------
-- === 2. DFA of the heading walk: steady flight vs AC-09 ===

SELECT 'steady flight' AS series,
       ROUND(fractal_dimension_dfa(CONCAT('[', GROUP_CONCAT(ROUND(s, 6) ORDER BY t), ']')), 3) AS dfa_alpha
  FROM (WITH RECURSIVE n(t, x) AS (
               SELECT 1, 7919 UNION ALL
               SELECT t + 1, MOD(x * 1103515245 + 12345, 2147483648) FROM n WHERE t < 120)
        SELECT t, SUM((MOD(x DIV 65536, 1000) - 500) / 1000.0 * 0.03) OVER (ORDER BY t) AS s FROM n) w
UNION ALL
SELECT 'AC-09 erratic stretch',
       ROUND(fractal_dimension_dfa(CONCAT('[', GROUP_CONCAT(ROUND(s, 6) ORDER BY t), ']')), 3)
  FROM (WITH RECURSIVE n(t, x) AS (
               SELECT 1, 7919 UNION ALL
               SELECT t + 1, MOD(x * 1103515245 + 12345, 2147483648) FROM n WHERE t < 120)
        SELECT t, SUM((MOD(x DIV 65536, 1000) - 500) / 1000.0
                      * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) OVER (ORDER BY t) AS s FROM n) w;

-- ------------------------------------------------------------------
-- 3. Hand-composed: trajectory deviation of AC-09 -- the fleet members
-- nearest to its planned path and to where it is now.
-- ------------------------------------------------------------------
-- === 3. AC-09 baseline -> current trajectory search ===

CALL fractal_search_trajectory(
    'afp_flights', 'current_pos',
    (SELECT baseline    FROM afp_flights WHERE flight = 'AC-09'),
    (SELECT current_pos FROM afp_flights WHERE flight = 'AC-09'),
    5, @afp_traj);

SELECT f.flight, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@afp_traj, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN afp_flights f ON f.id = jt.doc_id
 ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 4. The shipped agent: trajectory deviation + heading DFA + a reasoned
-- classification in one call (reasoning plugin).
-- ------------------------------------------------------------------
-- === 4. fractal_agent_track_anomaly (3D flight path) ===

CALL fractal_agent_track_anomaly(
    'afp_flights', 'current_pos',
    (SELECT baseline    FROM afp_flights WHERE flight = 'AC-09'),
    (SELECT current_pos FROM afp_flights WHERE flight = 'AC-09'),
    (SELECT CONCAT('[', GROUP_CONCAT(ROUND(s, 6) ORDER BY t), ']')
       FROM (WITH RECURSIVE n(t, x) AS (
                   SELECT 1, 7919 UNION ALL
                   SELECT t + 1, MOD(x * 1103515245 + 12345, 2147483648) FROM n WHERE t < 120)
             SELECT t, SUM((MOD(x DIV 65536, 1000) - 500) / 1000.0
                           * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END)
                       OVER (ORDER BY t) AS s FROM n) w),
    5, @r);
SELECT JSON_VALUE(@r, '$.nearest_fleet_id')    AS nearest_fleet_id,
       JSON_VALUE(@r, '$.trajectory_distance') AS trajectory_distance,
       JSON_VALUE(@r, '$.dfa_exponent')        AS dfa_exponent,
       JSON_VALUE(@r, '$.rationale')           AS rationale;

-- ------------------------------------------------------------------
-- 5. Reasoning: classify the deviation (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: classify the deviation ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line classification of this flight-path deviation: sensor fault, control-surface fault, or weather',
    JSON_OBJECT('trajectory', JSON_EXTRACT(@afp_traj, '$'))) AS classification;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE afp_flights;
