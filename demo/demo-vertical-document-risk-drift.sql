-- demo/demo-vertical-document-risk-drift.sql
--
-- Industry vertical: Document risk drift: clause-level drift detection and
-- compliance review. DOMAIN kit: Four agreements x 96 weekly clause-risk
-- reviews; one agreement's amended terms drift into a new regime (an
-- accelerating risk creep). `fractal_dimension_drift` (the regime-detection
-- recipe from the quant-finance kit, applied to document risk) finds it;
-- Scout (`fractal_search_explore`) pulls six deliberately different clause
-- variants out of the 24-clause corpus so the reviewer sees the spread
-- rather than six near-copies; and `fractal_agent_recommend_diverse`
-- proposes diverse approved replacement language.
--
--   1. fractal_dimension_drift per agreement: whose clause risk changed
--      regime.
--   2. fractal_agent_anomaly_triage: the shipped one-call triage for the
--      drifting agreement.
--   3. Scout: six different clause variants across the four clause
--      families.
--   4. fractal_agent_recommend_diverse: diverse approved replacement
--      clauses.
--   5. A closing fractal_reason() writes the reviewer-ready note.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-document-risk-drift.sql
--
-- Safe to re-run: drd_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Clause vector = [liability exposure, data-transfer scope, termination
--     rigidity, regulatory novelty].
--   * The drift exponent compares the recent window against the baseline
--     window of the same series.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Clause-risk telemetry: 4 agreements x 96 weekly reviews ===
DROP TABLE IF EXISTS drd_risk;
CREATE TABLE drd_risk (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO drd_risk (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p2) AS (
         SELECT 'DOC-A', 38, 0
         UNION ALL SELECT 'DOC-B', 52, 0
         UNION ALL SELECT 'DOC-C', 45, 0.0024
         UNION ALL SELECT 'DOC-D', 61, 0)
SELECT ent, g, base * (1.0 + 0.004 * (g % 8)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
  FROM s, gs;


-- === 2. Hand-composed: clause-risk regime drift per agreement ===
DROP TABLE IF EXISTS drd_prof;
CREATE TABLE drd_prof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, CAST(JSON_VALUE(a.dj, '$.drift') AS DOUBLE) AS drift, CAST(JSON_VALUE(a.dj, '$.recent_alpha') AS DOUBLE) AS recent_alpha, CAST(JSON_VALUE(a.dj, '$.baseline_alpha') AS DOUBLE) AS baseline_alpha
  FROM (SELECT ent, arr, fractal_dimension_drift(arr, 32) AS dj FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM drd_risk GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM drd_risk GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha, ROUND(drift, 4) AS drift, ROUND(recent_alpha, 4) AS recent_alpha, ROUND(baseline_alpha, 4) AS baseline_alpha
  FROM drd_prof ORDER BY ent;


-- === 3. fractal_agent_anomaly_triage: drifting vs stable agreement ===
CALL fractal_agent_anomaly_triage('drd_risk', 'val', 'seq', 'ent', 'DOC-C', 32, @drd_tri0);
CALL fractal_agent_anomaly_triage('drd_risk', 'val', 'seq', 'ent', 'DOC-A', 32, @drd_tri1);
SELECT 'DOC-C (drifting)' AS entity, JSON_VALUE(@drd_tri0, '$.threat_score') AS threat_score, JSON_VALUE(@drd_tri0, '$.anomaly_type') AS anomaly_type, JSON_VALUE(@drd_tri0, '$.triage_summary') AS triage_summary
UNION ALL SELECT 'DOC-A (stable)', JSON_VALUE(@drd_tri1, '$.threat_score'), JSON_VALUE(@drd_tri1, '$.anomaly_type'), JSON_VALUE(@drd_tri1, '$.triage_summary');


-- === 4. Scout: six different clause variants ===
DROP TABLE IF EXISTS drd_clauses;
CREATE TABLE drd_clauses (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    family VARCHAR(128),
    c1 DOUBLE,
    c2 DOUBLE,
    c3 DOUBLE,
    c4 DOUBLE,
    vec JSON,
    CONSTRAINT drd_clauses_dims CHECK (JSON_LENGTH(vec) = 4)
);
INSERT INTO drd_clauses (id, label, family, c1, c2, c3, c4, vec) VALUES
    (1, 'CL-01 data handling', 'data handling', 0.2013, 0.8387, 0.3313, 0.3687, '[0.2013, 0.8387, 0.3313, 0.3687]'),
    (2, 'CL-02 termination', 'termination', 0.3626, 0.2374, 0.8726, 0.5974, '[0.3626, 0.2374, 0.8726, 0.5974]'),
    (3, 'CL-03 scope limits', 'scope limits', 0.5739, 0.6361, 0.2639, 0.2261, '[0.5739, 0.6361, 0.2639, 0.2261]'),
    (4, 'CL-04 liability', 'liability', 0.9352, 0.1348, 0.2052, 0.8548, '[0.9352, 0.1348, 0.2052, 0.8548]'),
    (5, 'CL-05 data handling', 'data handling', 0.1465, 0.8335, 0.2465, 0.3335, '[0.1465, 0.8335, 0.2465, 0.3335]'),
    (6, 'CL-06 termination', 'termination', 0.3078, 0.2322, 0.9378, 0.5622, '[0.3078, 0.2322, 0.9378, 0.5622]'),
    (7, 'CL-07 scope limits', 'scope limits', 0.6691, 0.6309, 0.1791, 0.1909, '[0.6691, 0.6309, 0.1791, 0.1909]'),
    (8, 'CL-08 liability', 'liability', 0.8804, 0.1296, 0.2704, 0.8196, '[0.8804, 0.1296, 0.2704, 0.8196]'),
    (9, 'CL-09 data handling', 'data handling', 0.2417, 0.8283, 0.3117, 0.4483, '[0.2417, 0.8283, 0.3117, 0.4483]'),
    (10, 'CL-10 termination', 'termination', 0.253, 0.227, 0.853, 0.527, '[0.253, 0.227, 0.853, 0.527]'),
    (11, 'CL-11 scope limits', 'scope limits', 0.6143, 0.6257, 0.2443, 0.1557, '[0.6143, 0.6257, 0.2443, 0.1557]'),
    (12, 'CL-12 liability', 'liability', 0.9756, 0.1244, 0.1856, 0.7844, '[0.9756, 0.1244, 0.1856, 0.7844]'),
    (13, 'CL-13 data handling', 'data handling', 0.1869, 0.8231, 0.3769, 0.4131, '[0.1869, 0.8231, 0.3769, 0.4131]'),
    (14, 'CL-14 termination', 'termination', 0.3482, 0.2218, 0.9182, 0.6418, '[0.3482, 0.2218, 0.9182, 0.6418]'),
    (15, 'CL-15 scope limits', 'scope limits', 0.5595, 0.6205, 0.1595, 0.1205, '[0.5595, 0.6205, 0.1595, 0.1205]'),
    (16, 'CL-16 liability', 'liability', 0.9208, 0.1192, 0.2508, 0.7492, '[0.9208, 0.1192, 0.2508, 0.7492]'),
    (17, 'CL-17 data handling', 'data handling', 0.2821, 0.8179, 0.2921, 0.3779, '[0.2821, 0.8179, 0.2921, 0.3779]'),
    (18, 'CL-18 termination', 'termination', 0.2934, 0.2166, 0.9834, 0.6066, '[0.2934, 0.2166, 0.9834, 0.6066]'),
    (19, 'CL-19 scope limits', 'scope limits', 0.6547, 0.6153, 0.2247, 0.2353, '[0.6547, 0.6153, 0.2247, 0.2353]'),
    (20, 'CL-20 liability', 'liability', 0.866, 0.114, 0.166, 0.714, '[0.866, 0.114, 0.166, 0.714]'),
    (21, 'CL-21 data handling', 'data handling', 0.2273, 0.8127, 0.3573, 0.3427, '[0.2273, 0.8127, 0.3573, 0.3427]'),
    (22, 'CL-22 termination', 'termination', 0.3886, 0.2114, 0.8986, 0.5714, '[0.3886, 0.2114, 0.8986, 0.5714]'),
    (23, 'CL-23 scope limits', 'scope limits', 0.5999, 0.6101, 0.2899, 0.2001, '[0.5999, 0.6101, 0.2899, 0.2001]'),
    (24, 'CL-24 liability', 'liability', 0.9612, 0.1088, 0.2312, 0.8288, '[0.9612, 0.1088, 0.2312, 0.8288]');
SET @drd_scout = fractal_search_explore(
    (SELECT GROUP_CONCAT(CONCAT_WS(',', c1, c2, c3, c4) ORDER BY id SEPARATOR ';') FROM drd_clauses),
    '0.5,0.6,0.4,0.5',
    '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}');

DROP TABLE IF EXISTS drd_picks;
CREATE TABLE drd_picks AS
SELECT pt.ord, s.id, s.label, s.family
  FROM JSON_TABLE(JSON_EXTRACT(@drd_scout, '$.population'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, p1 DOUBLE PATH '$[0]', p2 DOUBLE PATH '$[1]', p3 DOUBLE PATH '$[2]', p4 DOUBLE PATH '$[3]')) pt
  JOIN drd_clauses s ON ABS(s.c1 - pt.p1) < 1e-6 AND ABS(s.c2 - pt.p2) < 1e-6 AND ABS(s.c3 - pt.p3) < 1e-6 AND ABS(s.c4 - pt.p4) < 1e-6;

SELECT ord, id, label, family FROM drd_picks ORDER BY ord;
-- --- coverage: clause families represented in the six picks ---
SELECT count(DISTINCT family) AS families_covered_of_4 FROM drd_picks;


-- === 5. Diverse approved replacement clauses ===
DROP TABLE IF EXISTS drd_approved;
CREATE TABLE drd_approved (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT drd_approved_dims CHECK (JSON_LENGTH(vec) = 3)
);
INSERT INTO drd_approved (id, label, vec) VALUES
    (1, 'APPROVED-01 data handling', '[0.1513, 0.8487, 0.2763]'),
    (2, 'APPROVED-02 termination', '[0.3026, 0.1474, 0.8776]'),
    (3, 'APPROVED-03 scope limits', '[0.5789, 0.5461, 0.6539]'),
    (4, 'APPROVED-04 liability', '[0.9302, 0.1448, 0.1552]'),
    (5, 'APPROVED-05 data handling', '[0.1065, 0.8435, 0.2065]'),
    (6, 'APPROVED-06 termination', '[0.2578, 0.1422, 0.9328]'),
    (7, 'APPROVED-07 scope limits', '[0.6591, 0.5409, 0.5841]'),
    (8, 'APPROVED-08 liability', '[0.8854, 0.1396, 0.2104]'),
    (9, 'APPROVED-09 data handling', '[0.1867, 0.8383, 0.2617]'),
    (10, 'APPROVED-10 termination', '[0.213, 0.137, 0.863]'),
    (11, 'APPROVED-11 scope limits', '[0.6143, 0.5357, 0.6393]'),
    (12, 'APPROVED-12 liability', '[0.9656, 0.1344, 0.1406]'),
    (13, 'APPROVED-13 data handling', '[0.1419, 0.8331, 0.3169]'),
    (14, 'APPROVED-14 termination', '[0.2932, 0.1318, 0.9182]'),
    (15, 'APPROVED-15 scope limits', '[0.5695, 0.5305, 0.5695]'),
    (16, 'APPROVED-16 liability', '[0.9208, 0.1292, 0.1958]'),
    (17, 'APPROVED-17 data handling', '[0.2221, 0.8279, 0.2471]'),
    (18, 'APPROVED-18 termination', '[0.2484, 0.1266, 0.9734]'),
    (19, 'APPROVED-19 scope limits', '[0.6497, 0.5253, 0.6247]'),
    (20, 'APPROVED-20 liability', '[0.876, 0.124, 0.126]');
CALL fractal_agent_recommend_diverse('drd_approved', 'vec', '[0.85, 0.2, 0.15]', 4, @drd_r);
DROP TABLE IF EXISTS drd_rec;
CREATE TABLE drd_rec AS
SELECT ROW_NUMBER() OVER (ORDER BY jt.score DESC, jt.item_id) AS rk, c.id AS item_id, c.label AS label,
       ROUND(jt.score, 4) AS score
  FROM JSON_TABLE(@drd_r, '$[*]' COLUMNS (item_id INT PATH '$.item_id', score DOUBLE PATH '$.score')) jt
  JOIN drd_approved c ON c.id = jt.item_id;

SELECT rk, item_id, label, score FROM drd_rec ORDER BY rk;
SELECT fractal_diversify_disable(CONNECTION_ID());


-- === 6. Reasoning: reviewer-ready note ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line reviewer-ready note: which agreement drifted, the exposure, and the replacement language to propose',
    JSON_OBJECT('drifting_agreement', (SELECT ent FROM drd_prof ORDER BY drift DESC LIMIT 1), 'replacement', (SELECT label FROM drd_rec WHERE rk = 1))) AS narrative;


-- === 7. Headline check ===
SELECT CONCAT('HEADLINE kit=document-risk-drift ', CASE WHEN (SELECT drift FROM drd_prof WHERE ent = 'DOC-C') > 0.5 AND (SELECT drift FROM drd_prof WHERE ent = 'DOC-A') < 0 AND (SELECT count(*) FROM drd_picks) = 6 AND (SELECT count(DISTINCT family) FROM drd_picks) >= 3 AND (SELECT count(*) FROM drd_rec) = 4 THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE drd_risk, drd_prof, drd_clauses, drd_picks, drd_approved, drd_rec;
