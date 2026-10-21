-- demo/demo-vertical-ev-battery-lifecycle.sql
--
-- Industry vertical: Electric-vehicle fleet battery lifecycle -- state-of-
-- health (SoH) and thermal-regime monitoring.  AGENTIC kit: two installed
-- agents are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_patient_deterioration_triage -- cohort search plus
--      baseline-vs-current trajectory drift.  Its contract is domain-
--      neutral (a vehicle's intake baseline plays the patient's admission
--      baseline), so the kit only supplies different columns.
--   2. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      vehicle's temperature series, flagging a shift into a new regime
--      (pre-thermal-runaway) independently of the SoH comparison.
--   3. A closing fractal_reason() synthesizes both signals into one
--      maintenance / safety recommendation.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_* and fractal_search_trajectory are PROCEDUREs with a
--     trailing OUT result JSON param: `CALL x(...args, @r); SELECT
--     JSON_VALUE(@r, '$.field');`.  Their doc_ids are the table's real
--     PRIMARY KEY values, so no remapping is needed.
--   - cohort_doc_ids is a JSON array of real `id` values, computed with
--     ordinary SQL.
--   - fractal_reason takes the session id (CONNECTION_ID()) first.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agents and Section 5 call fractal_reason internally.  Sections 1-4's
--      hand-composed steps need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-ev-battery-lifecycle.sql
--
-- Safe to re-run: ebl_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: built from a recursive CTE with fixed
--     wobble, no RAND(), so every run returns the same numbers.
--   * state is a JSON array [soh, temp_z, volt_z, fade_rate], guarded by
--     a CHECK on its length so a malformed telematics write fails loudly.
--   * The temperature series needs >= 48 points per vehicle for the 32-
--     point drift window (DFA needs the recent window large enough).  The
--     fault is an accelerating ramp, not a level shift: DFA removes a
--     constant offset, so only a change in the series' dynamics registers.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Fleet telemetry: 3 vehicles x 96 readings.  EV-101 and EV-102 age
-- gently.  EV-203 develops a fault at reading 65: an accelerating
-- (quadratic) thermal ramp, a voltage sag and an accelerating SoH fade.
-- ------------------------------------------------------------------
-- === 1. Fleet telemetry: 3 vehicles x 96 readings ===

DROP TABLE IF EXISTS ebl_telemetry;
CREATE TABLE ebl_telemetry (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    vin        VARCHAR(16),
    model_year INT,
    seq        INT,              -- reading order within the vehicle
    soh        DOUBLE,           -- state of health, fraction of nominal capacity
    temp_c     DOUBLE,           -- pack temperature
    volt       DOUBLE,           -- mean cell voltage under load
    state      JSON,
    CONSTRAINT ebl_state_dims CHECK (JSON_LENGTH(state) = 4)
);

INSERT INTO ebl_telemetry (vin, model_year, seq, soh, temp_c, volt, state)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     v(vi, vin, my) AS (
         SELECT 1, 'EV-101', 2024 UNION ALL SELECT 2, 'EV-102', 2024 UNION ALL SELECT 3, 'EV-203', 2023),
     r AS (
         SELECT vi, vin, my, g,
                0.99 - 0.0004 * g
                  - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.004 * (g - 64) ELSE 0 END AS soh,
                31.0 + MOD(g, 8) * 0.6
                  + CASE WHEN vin = 'EV-203' AND g > 64
                         THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END AS temp_c,
                3.72 - MOD(g, 5) * 0.004
                  - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.09 ELSE 0 END AS volt
           FROM v, gs)
SELECT vin, my, g, soh, temp_c, volt,
       JSON_ARRAY(ROUND(soh, 4), ROUND((temp_c - 35.0) / 10.0, 4),
                  ROUND((volt - 3.70) / 0.10, 4), ROUND((0.99 - soh) / g, 6))
  FROM r
 ORDER BY vi, g;

SELECT vin, COUNT(*) AS readings, ROUND(MIN(soh), 3) AS min_soh,
       ROUND(MAX(temp_c), 1) AS max_temp_c
  FROM ebl_telemetry GROUP BY vin ORDER BY vin;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: baseline-vs-current trajectory search.
-- EV-203's intake baseline vs its latest reading; the nearest fleet
-- readings show where in the fleet's history the pack now sits.
-- ------------------------------------------------------------------
-- === 2. Step 1 (hand-composed): EV-203 baseline -> current trajectory ===

CALL fractal_search_trajectory(
    'ebl_telemetry', 'state',
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    5, @ebl_traj);

SELECT t.vin, t.seq, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@ebl_traj, '$[*]' COLUMNS (
           doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN ebl_telemetry t ON t.id = jt.doc_id
 ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent.  The cohort is caller-
-- built with ordinary SQL (model year 2023, the cohort EV-203 belongs
-- to); nearest_cohort_id / cohort_distance / drift_distance are real.
-- Reasoning-bearing: needs the plugin.
-- ------------------------------------------------------------------
-- === 3. Step 1 (shipped agent): fractal_agent_patient_deterioration_triage ===

CALL fractal_agent_patient_deterioration_triage(
    'ebl_telemetry', 'state',
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']')
       FROM ebl_telemetry WHERE model_year = 2023),
    5, @r);
SELECT JSON_VALUE(@r, '$.nearest_cohort_id') AS nearest_cohort_id,
       JSON_VALUE(@r, '$.cohort_distance')   AS cohort_distance,
       JSON_VALUE(@r, '$.drift_distance')    AS drift_distance,
       JSON_VALUE(@r, '$.rationale')         AS rationale;

-- ------------------------------------------------------------------
-- 4. Step 2, hand-composed then productized: temperature-regime drift.
-- fractal_dimension_drift on each vehicle's temperature series; the
-- healthy pair sits near zero (slightly negative), EV-203's accelerating
-- ramp pushes the recent-window exponent far above its baseline.  (DFA
-- measures how the series' fluctuation scales, so the regime change is a
-- change in dynamics -- a pure level shift would not move it.)
-- ------------------------------------------------------------------
-- === 4. Step 2 (hand-composed): temperature-regime drift per vehicle ===

SELECT vin,
       ROUND(JSON_VALUE(d, '$.drift'), 4)          AS drift,
       ROUND(JSON_VALUE(d, '$.recent_alpha'), 4)   AS recent_alpha,
       ROUND(JSON_VALUE(d, '$.baseline_alpha'), 4) AS baseline_alpha
  FROM (SELECT vin,
               fractal_dimension_drift(
                   CONCAT('[', GROUP_CONCAT(ROUND(temp_c, 4) ORDER BY seq), ']'), 32) AS d
          FROM ebl_telemetry GROUP BY vin) x
 ORDER BY vin;

-- --- the shipped agent: same composition, one call (reasoning plugin) ---
CALL fractal_agent_anomaly_triage(
    'ebl_telemetry', 'temp_c', 'seq', 'vin', 'EV-203', 32, @r);
SELECT JSON_VALUE(@r, '$.threat_score')   AS threat_score,
       JSON_VALUE(@r, '$.anomaly_type')   AS anomaly_type,
       JSON_VALUE(@r, '$.triage_summary') AS thermal_triage;

-- ------------------------------------------------------------------
-- 5. Reasoning: one maintenance / safety recommendation over BOTH
-- signals (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: maintenance / safety recommendation for EV-203 ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line maintenance and safety recommendation for an EV pack showing '
    'both an accelerating state-of-health fade and a thermal regime shift',
    JSON_OBJECT(
        'soh_trajectory', JSON_EXTRACT(@ebl_traj, '$'),
        'thermal_drift', JSON_COMPACT(fractal_dimension_drift(
            (SELECT CONCAT('[', GROUP_CONCAT(ROUND(temp_c, 4) ORDER BY seq), ']')
               FROM ebl_telemetry WHERE vin = 'EV-203'), 32)))) AS recommendation;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE ebl_telemetry;
