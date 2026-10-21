-- demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- Industry vertical: Climate Tech -- industrial emissions and utility-
-- leak detection (methane / CO2 sensor networks, water-distribution
-- pressure and flow monitoring).  DOMAIN kit built on one installed
-- agent, fractal_agent_anomaly_triage, reused verbatim: the drift
-- exponent of a single sensor's series flags a shift into a new
-- (leak / over-emission) regime, closing with a reasoned narrative.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_anomaly_triage is a PROCEDURE with a trailing OUT
--     result JSON param: `CALL fractal_agent_anomaly_triage(log_table,
--     metric_col, time_col, filter_col, filter_val, window, @r)`.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent and Section 4 call fractal_reason.  The hand-composed drift
--      needs no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- Safe to re-run: cem_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * Each sensor has a baseline reading; the drift window is 32 points,
--     so each sensor needs >= 48 readings.  A leak is an ACCELERATING
--     concentration ramp downstream of the source, not a level shift:
--     DFA removes a constant offset, so only a change in the series'
--     dynamics moves the exponent.
--   * The network mixes gases and a pipeline-pressure sensor (PRS-07): the
--     agent is indifferent to the physical quantity, so the same call
--     screens a water-distribution pressure series for leaks.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Four sensors x 96 readings.  CH4-02 (methane, downstream of a
-- compressor) starts leaking at reading 65: concentration ramps up
-- quadratically.  CH4-01 and CO2-01 are steady; PRS-07 is a pipeline
-- pressure sensor, steady here.
-- ------------------------------------------------------------------
-- === 1. Sensor network: 4 sensors x 96 readings ===

DROP TABLE IF EXISTS cem_readings;
CREATE TABLE cem_readings (
    sensor   VARCHAR(16),
    quantity VARCHAR(16),
    seq      INT,
    value    DOUBLE,
    baseline DOUBLE
);
INSERT INTO cem_readings (sensor, quantity, seq, value, baseline)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(sensor, quantity, base) AS (
         SELECT 'CH4-01', 'methane_ppm', 1.9 UNION ALL SELECT 'CH4-02', 'methane_ppm', 1.9
         UNION ALL SELECT 'CO2-01', 'co2_ppm', 412.0 UNION ALL SELECT 'PRS-07', 'pressure_kpa', 620.0)
SELECT sensor, quantity, g,
       base * (1.0 + 0.004 * MOD(g, 8))
         + CASE WHEN sensor = 'CH4-02' AND g > 64
                THEN 0.0045 * (g - 64) * (g - 64) ELSE 0 END,
       base
  FROM s, gs;

SELECT sensor, quantity, ROUND(MAX(value), 3) AS peak, MAX(baseline) AS baseline
  FROM cem_readings GROUP BY sensor, quantity ORDER BY sensor;

-- ------------------------------------------------------------------
-- 2. Hand-composed: emissions-regime drift per sensor.
-- ------------------------------------------------------------------
-- === 2. Hand-composed: regime drift per sensor ===

SELECT sensor,
       ROUND(JSON_VALUE(d, '$.drift'), 4)          AS drift,
       ROUND(JSON_VALUE(d, '$.recent_alpha'), 4)   AS recent_alpha,
       ROUND(JSON_VALUE(d, '$.baseline_alpha'), 4) AS baseline_alpha
  FROM (SELECT sensor,
               fractal_dimension_drift(
                   CONCAT('[', GROUP_CONCAT(ROUND(value, 5) ORDER BY seq), ']'), 32) AS d
          FROM cem_readings GROUP BY sensor) x
 ORDER BY sensor;

-- ------------------------------------------------------------------
-- 3. The shipped agent on the leaking sensor, and on a steady one for
-- contrast (reasoning plugin).
-- ------------------------------------------------------------------
-- === 3. fractal_agent_anomaly_triage: leaking vs steady sensor ===

CALL fractal_agent_anomaly_triage('cem_readings', 'value', 'seq', 'sensor', 'CH4-02', 32, @cem_leak);
CALL fractal_agent_anomaly_triage('cem_readings', 'value', 'seq', 'sensor', 'CH4-01', 32, @cem_steady);
SELECT 'CH4-02 (leaking)' AS sensor, JSON_VALUE(@cem_leak, '$.threat_score') AS threat_score,
       JSON_VALUE(@cem_leak, '$.anomaly_type') AS anomaly_type, JSON_VALUE(@cem_leak, '$.triage_summary') AS triage
UNION ALL
SELECT 'CH4-01 (steady)', JSON_VALUE(@cem_steady, '$.threat_score'),
       JSON_VALUE(@cem_steady, '$.anomaly_type'), JSON_VALUE(@cem_steady, '$.triage_summary');

-- ------------------------------------------------------------------
-- 4. Reasoning: the leak narrative (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 4. Reasoning: leak / over-emission narrative ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line leak-detection narrative and recommended field response for this sensor',
    JSON_COMPACT(fractal_dimension_drift(
        (SELECT CONCAT('[', GROUP_CONCAT(ROUND(value, 5) ORDER BY seq), ']')
           FROM cem_readings WHERE sensor = 'CH4-02'), 32))) AS narrative;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE cem_readings;
