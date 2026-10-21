-- demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- Industry vertical: heavy machinery and fleet predictive maintenance --
-- commercial marine vessels, construction / mining equipment, industrial
-- powertrains, hull and structural sensor networks.  AGENTIC kit: two
-- installed agents are chained, shown hand-composed first and then as the
-- shipped one-call agents.
--
--   1. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      asset's vibration series, flagging a shift into a new (pre-
--      failure) regime.
--   2. fractal_agent_patient_deterioration_triage -- baseline-vs-current
--      trajectory drift against the asset's intake baseline, with a
--      same-class cohort search (an asset plays the patient).
--   3. A closing fractal_reason() produces a maintenance-window
--      recommendation.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - Agents and fractal_search_trajectory are PROCEDUREs with a trailing
--     OUT result JSON param.  doc_ids are the table's real PRIMARY KEY
--     values; cohort_doc_ids is a JSON array of real `id` values.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agents and Section 4 call fractal_reason.  The hand-composed steps
--      need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- Safe to re-run: hpm_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * State vectors are [vib_rms_z, kurtosis_z, bearing_temp_z, order1_amp_z]
--     as JSON arrays, guarded by a CHECK on their length.
--   * The drift window is 32 points, so each asset needs >= 48 readings.
--     The failure signature is an ACCELERATING vibration ramp (a growing
--     bearing defect), not a level shift: DFA removes a constant offset,
--     so only a change in the series' dynamics moves the exponent.
--   * This is the WEAR / LIFECYCLE half of heavy-industry monitoring.  A
--     CAD / structural-defect (3D mesh) kit is a separate topic.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Four pumps / drives x 96 readings.  PUMP-07 develops a bearing
-- defect at reading 65 (accelerating vibration, rising temperature);
-- the others age gently.  'class' groups comparable assets.
-- ------------------------------------------------------------------
-- === 1. Asset telemetry: 4 assets x 96 readings ===

DROP TABLE IF EXISTS hpm_readings;
CREATE TABLE hpm_readings (
    id     INT AUTO_INCREMENT PRIMARY KEY,
    asset  VARCHAR(16),
    class  VARCHAR(16),
    seq    INT,
    vib    DOUBLE,              -- vibration RMS, mm/s
    temp_c DOUBLE,              -- bearing temperature
    state  JSON,
    CONSTRAINT hpm_state_dims CHECK (JSON_LENGTH(state) = 4)
);

INSERT INTO hpm_readings (asset, class, seq, vib, temp_c, state)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     a(ai, asset, class) AS (
         SELECT 1, 'PUMP-03', 'centrifugal' UNION ALL SELECT 2, 'PUMP-05', 'centrifugal'
         UNION ALL SELECT 3, 'PUMP-07', 'centrifugal' UNION ALL SELECT 4, 'DRIVE-12', 'gearbox'),
     r AS (
         SELECT ai, asset, class, g,
                2.1 + MOD(g, 8) * 0.05
                  + CASE WHEN asset = 'PUMP-07' AND g > 64
                         THEN 0.004 * (g - 64) * (g - 64) ELSE 0 END AS vib,
                58.0 + MOD(g, 6) * 0.4
                  + CASE WHEN asset = 'PUMP-07' AND g > 64 THEN 0.35 * (g - 64) ELSE 0 END AS temp_c
           FROM a, gs)
SELECT asset, class, g, vib, temp_c,
       JSON_ARRAY(ROUND((vib - 2.3) / 1.0, 4),
                  ROUND((MOD(g, 8) * 0.05 + CASE WHEN asset = 'PUMP-07' AND g > 64
                                                 THEN 0.08 * (g - 64) ELSE 0 END) - 0.2, 4),
                  ROUND((temp_c - 60.0) / 10.0, 4),
                  ROUND((vib - 2.1) * 0.5, 4))
  FROM r ORDER BY ai, g;

SELECT asset, class, COUNT(*) AS readings, ROUND(MAX(vib), 2) AS max_vib_mm_s,
       ROUND(MAX(temp_c), 1) AS max_bearing_temp_c
  FROM hpm_readings GROUP BY asset, class ORDER BY asset;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: vibration-regime drift per asset.  The
-- healthy assets sit near zero; PUMP-07's accelerating ramp pushes its
-- recent-window exponent far above its baseline.
-- ------------------------------------------------------------------
-- === 2. Step 1 (hand-composed): vibration drift per asset ===

SELECT asset,
       ROUND(JSON_VALUE(d, '$.drift'), 4)          AS drift,
       ROUND(JSON_VALUE(d, '$.recent_alpha'), 4)   AS recent_alpha,
       ROUND(JSON_VALUE(d, '$.baseline_alpha'), 4) AS baseline_alpha
  FROM (SELECT asset,
               fractal_dimension_drift(
                   CONCAT('[', GROUP_CONCAT(ROUND(vib, 4) ORDER BY seq), ']'), 32) AS d
          FROM hpm_readings GROUP BY asset) x
 ORDER BY asset;

-- --- the shipped agent: same composition, one call (reasoning plugin) ---
CALL fractal_agent_anomaly_triage('hpm_readings', 'vib', 'seq', 'asset', 'PUMP-07', 32, @r);
SELECT JSON_VALUE(@r, '$.threat_score')   AS threat_score,
       JSON_VALUE(@r, '$.anomaly_type')   AS anomaly_type,
       JSON_VALUE(@r, '$.triage_summary') AS vibration_triage;

-- ------------------------------------------------------------------
-- 3. Step 2, hand-composed: PUMP-07's intake baseline vs its latest
-- state.  The nearest fleet readings show where in the fleet's history
-- the pump now sits.
-- ------------------------------------------------------------------
-- === 3. Step 2 (hand-composed): PUMP-07 baseline -> current trajectory ===

CALL fractal_search_trajectory(
    'hpm_readings', 'state',
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    5, @hpm_traj);

SELECT h.asset, h.seq, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@hpm_traj, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN hpm_readings h ON h.id = jt.doc_id
 ORDER BY jt.dist;

-- --- the shipped agent: cohort = same-class (centrifugal) assets (reasoning plugin) ---
CALL fractal_agent_patient_deterioration_triage(
    'hpm_readings', 'state',
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']') FROM hpm_readings WHERE class = 'centrifugal'),
    5, @r2);
SELECT JSON_VALUE(@r2, '$.nearest_cohort_id') AS nearest_cohort_id,
       JSON_VALUE(@r2, '$.cohort_distance')   AS cohort_distance,
       JSON_VALUE(@r2, '$.drift_distance')    AS drift_distance,
       JSON_VALUE(@r2, '$.rationale')         AS baseline_triage;

-- ------------------------------------------------------------------
-- 4. Reasoning: the maintenance-window recommendation (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
-- === 4. Reasoning: maintenance-window recommendation for PUMP-07 ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line maintenance-window recommendation for a pump showing an accelerating '
    'vibration regime shift and drift from its intake baseline',
    JSON_OBJECT(
        'vibration_drift', JSON_COMPACT(fractal_dimension_drift(
            (SELECT CONCAT('[', GROUP_CONCAT(ROUND(vib, 4) ORDER BY seq), ']')
               FROM hpm_readings WHERE asset = 'PUMP-07'), 32)),
        'baseline_trajectory', JSON_EXTRACT(@hpm_traj, '$'))) AS recommendation;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE hpm_readings;
