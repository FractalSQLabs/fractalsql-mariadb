-- demo/demo-vertical-hazmat-occupational-triage.sql
--
-- Industry vertical: occupational exposure monitoring -- hazardous-
-- materials response, chemical and nuclear plant crews, wearable-sensor
-- workforce safety.  DOMAIN kit built on one installed agent,
-- fractal_agent_patient_deterioration_triage, reused verbatim: its
-- contract (cohort vector search + baseline-vs-current trajectory drift)
-- is domain-neutral, so the kit only supplies exposure columns in place
-- of clinical vitals and a worker's pre-shift baseline in place of an
-- admission baseline.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - The agent and the search primitives are PROCEDUREs with a trailing
--     OUT result JSON param.  doc_ids are the table's real PRIMARY KEY
--     values; cohort_doc_ids is a JSON array of real `id` values.
--   - The cohort is caller-built with ordinary SQL (same work zone AND
--     same shift) -- the two-predicate cohort a single filter pair cannot
--     express.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent and Section 5 call fractal_reason.  Sections 1-3's hand-
--      composed steps need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-hazmat-occupational-triage.sql
--
-- Safe to re-run: hot_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * Exposure vectors are [dose_rate_z, body_temp_z, air_quality_z,
--     heart_rate_z] as JSON arrays guarded by a CHECK on their length: a
--     wrong-width write from a wearable integration fails loudly at write
--     time, not silently inside a worker record.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 36 synthetic workers across three work zones and two shifts.
-- Zone 'reactor-bay' on the night shift is the contaminated cohort:
-- workers 7, 15 and 31 show elevated dose rate, temperature and heart
-- rate.
-- ------------------------------------------------------------------
-- === 1. 36 workers: zone, shift and current exposure vector ===

DROP TABLE IF EXISTS hot_workers;
CREATE TABLE hot_workers (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    zone     VARCHAR(16),
    shift    VARCHAR(8),
    exposure JSON,
    CONSTRAINT hot_exposure_dims CHECK (JSON_LENGTH(exposure) = 4)
);

INSERT INTO hot_workers (zone, shift, exposure)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 36)
SELECT CASE MOD(g, 3) WHEN 0 THEN 'reactor-bay' WHEN 1 THEN 'fuel-handling' ELSE 'control-room' END,
       CASE WHEN MOD(g, 2) = 0 THEN 'night' ELSE 'day' END,
       JSON_ARRAY(0.05 * MOD(g, 5),            -- dose rate
                  0.04 * MOD(g, 7) - 0.10,     -- body temperature
                  0.03 * MOD(g, 4),            -- air quality
                  0.06 * MOD(g, 6) - 0.10)     -- heart rate
  FROM gs;

-- Force a deterministic contaminated cohort.
UPDATE hot_workers SET zone = 'reactor-bay', shift = 'night',
       exposure = '[1.40, 0.90, 1.10, 1.20]' WHERE id IN (7, 15, 31);

SELECT zone, shift, COUNT(*) AS workers FROM hot_workers
 GROUP BY zone, shift ORDER BY zone, shift;

-- ------------------------------------------------------------------
-- 2. Hand-composed: cohort-restricted search.  Nearest reactor-bay
-- night-shift workers to the exposure profile of the worker under
-- review.
-- ------------------------------------------------------------------
-- === 2. Cohort-restricted search: reactor-bay, night shift ===

CALL fractal_hybrid_clinical_search('hot_workers', 'exposure', '[1.40, 0.90, 1.10, 1.20]',
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']') FROM hot_workers
      WHERE zone = 'reactor-bay' AND shift = 'night'),
    5, @hot_h);

SELECT w.id AS worker_id, w.zone, w.shift, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@hot_h, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN hot_workers w ON w.id = jt.doc_id
 ORDER BY jt.dist, w.id;

-- ------------------------------------------------------------------
-- 3. Hand-composed: pre-shift baseline vs current exposure.
-- ------------------------------------------------------------------
-- === 3. Baseline -> current exposure trajectory ===

CALL fractal_search_trajectory('hot_workers', 'exposure',
    '[0.05, 0.00, 0.03, 0.00]',    -- pre-shift baseline
    '[1.40, 0.90, 1.10, 1.20]',    -- current (escalating)
    5, @hot_t);

SELECT w.id AS worker_id, w.zone, w.shift, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@hot_t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN hot_workers w ON w.id = jt.doc_id
 ORDER BY jt.dist, w.id;

-- ------------------------------------------------------------------
-- 4. The shipped agent: both searches plus a reasoned rationale in one
-- call (reasoning plugin).  The rationale is the countermeasure-
-- dispatch recommendation.
-- ------------------------------------------------------------------
-- === 4. fractal_agent_patient_deterioration_triage (exposure triage) ===

CALL fractal_agent_patient_deterioration_triage(
    'hot_workers', 'exposure', '[1.40, 0.90, 1.10, 1.20]',
    '[0.05, 0.00, 0.03, 0.00]', '[1.40, 0.90, 1.10, 1.20]',
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']') FROM hot_workers
      WHERE zone = 'reactor-bay' AND shift = 'night'),
    5, @r);
SELECT JSON_VALUE(@r, '$.nearest_cohort_id') AS nearest_cohort_id,
       JSON_VALUE(@r, '$.cohort_distance')   AS cohort_distance,
       JSON_VALUE(@r, '$.drift_distance')    AS drift_distance,
       JSON_VALUE(@r, '$.rationale')         AS rationale,
       JSON_EXTRACT(@r, '$.cohort_matches')  AS cohort_matches;

-- ------------------------------------------------------------------
-- 5. Reasoning: the medical-countermeasure dispatch recommendation
-- (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: countermeasure dispatch recommendation ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line medical-countermeasure dispatch recommendation for this exposed work crew',
    JSON_OBJECT('exposure_trajectory', JSON_EXTRACT(@hot_t, '$'))) AS recommendation;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE hot_workers;
