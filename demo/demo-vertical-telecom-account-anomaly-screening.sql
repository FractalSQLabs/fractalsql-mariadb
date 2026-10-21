-- demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- Industry vertical: telecom -- anomalous account-change screening (SIM
-- swap, port-out, plan change, unusual device or location changes).  A
-- general-purpose pre-commit safety check, not a fraud-specific product.
-- DOMAIN kit built on one installed agent,
-- fractal_agent_outlier_intercept, reused verbatim: it screens a
-- PROPOSED event against a history of known-anomalous change patterns,
-- exactly its designed contract (the same shape as the ADAS kit's
-- known-bad-state history, applied to account activity).
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_outlier_intercept and fractal_search_telemetry are
--     PROCEDUREs with a trailing OUT result JSON param.  The metric
--     argument is explicit ('cosine' or 'l2'); any other value is an
--     error, never a silent fallback.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent returns a reasoned `reason` and Section 5 calls
--      fractal_reason.  The hand-composed screen needs no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- Safe to re-run: taa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * Event vectors are [sim_change, port_out, new_device, geo_jump,
--     off_hours] intensities in 0..1, as JSON arrays guarded by a CHECK
--     on their length.
--   * Cosine distance (the default) compares the SHAPE of an event, not
--     its overall intensity: a faint version of a known pattern is
--     flagged too.  Use 'l2' when intensity should count (Section 4).

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. History of known-anomalous change patterns, and four proposed
-- account events awaiting commit.
-- ------------------------------------------------------------------
-- === 1. Known-anomalous patterns + proposed account events ===

DROP TABLE IF EXISTS taa_known_anomalous;
CREATE TABLE taa_known_anomalous (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    pattern VARCHAR(64),
    event   JSON,
    CONSTRAINT taa_known_dims CHECK (JSON_LENGTH(event) = 5)
);
INSERT INTO taa_known_anomalous (pattern, event) VALUES
    ('SIM swap + port-out + new device',      '[0.95, 0.90, 0.85, 0.10, 0.20]'),
    ('SIM swap from a distant location',      '[0.90, 0.05, 0.30, 0.95, 0.40]'),
    ('rapid plan changes off-hours',          '[0.05, 0.05, 0.10, 0.10, 0.95]'),
    ('new device + location jump + port-out', '[0.10, 0.80, 0.90, 0.85, 0.30]');

DROP TABLE IF EXISTS taa_proposed;
CREATE TABLE taa_proposed (
    id    INT AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(64),
    event JSON,
    CONSTRAINT taa_prop_dims CHECK (JSON_LENGTH(event) = 5)
);
INSERT INTO taa_proposed (label, event) VALUES
    ('E1 swap + port-out + new handset', '[0.92, 0.88, 0.80, 0.12, 0.18]'),
    ('E2 routine plan upgrade',          '[0.02, 0.00, 0.05, 0.00, 0.05]'),
    ('E3 new handset, same city',        '[0.00, 0.02, 0.70, 0.04, 0.05]'),
    ('E4 faint SIM swap, far away',      '[0.40, 0.02, 0.12, 0.42, 0.16]');

SELECT COUNT(*) AS known_patterns FROM taa_known_anomalous;

-- ------------------------------------------------------------------
-- 2. Hand-composed screen: nearest known-anomalous pattern per event,
-- threshold 0.10 (cosine).  One CALL per event.
-- ------------------------------------------------------------------
-- === 2. Hand-composed screen (cosine, threshold 0.10) ===

CALL fractal_search_telemetry('taa_known_anomalous', 'event', (SELECT event FROM taa_proposed WHERE id = 1), 1, @taa_t1);
CALL fractal_search_telemetry('taa_known_anomalous', 'event', (SELECT event FROM taa_proposed WHERE id = 2), 1, @taa_t2);
CALL fractal_search_telemetry('taa_known_anomalous', 'event', (SELECT event FROM taa_proposed WHERE id = 3), 1, @taa_t3);
CALL fractal_search_telemetry('taa_known_anomalous', 'event', (SELECT event FROM taa_proposed WHERE id = 4), 1, @taa_t4);

SELECT p.label, k.pattern AS nearest_pattern, ROUND(jt.dist, 4) AS distance,
       (jt.dist < 0.10) AS intercepted
  FROM (SELECT 1 AS pid, @taa_t1 AS r UNION ALL SELECT 2, @taa_t2
        UNION ALL SELECT 3, @taa_t3 UNION ALL SELECT 4, @taa_t4) q
  JOIN JSON_TABLE(q.r, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN taa_proposed p ON p.id = q.pid
  JOIN taa_known_anomalous k ON k.id = jt.doc_id
 ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent (reasoning plugin for the `reason` field).
-- ------------------------------------------------------------------
-- === 3. fractal_agent_outlier_intercept (cosine) ===

CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 1), 'taa_known_anomalous', 'event', 0.10, 'cosine', @taa_o1);
CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 2), 'taa_known_anomalous', 'event', 0.10, 'cosine', @taa_o2);
CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 3), 'taa_known_anomalous', 'event', 0.10, 'cosine', @taa_o3);
CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 4), 'taa_known_anomalous', 'event', 0.10, 'cosine', @taa_o4);
SELECT 'E1 swap + port-out + new handset' AS label, JSON_VALUE(@taa_o1, '$.intercepted') AS intercepted,
       JSON_VALUE(@taa_o1, '$.nearest_distance') AS nearest_distance, JSON_VALUE(@taa_o1, '$.reason') AS reason
UNION ALL SELECT 'E2 routine plan upgrade', JSON_VALUE(@taa_o2, '$.intercepted'),
       JSON_VALUE(@taa_o2, '$.nearest_distance'), JSON_VALUE(@taa_o2, '$.reason')
UNION ALL SELECT 'E3 new handset, same city', JSON_VALUE(@taa_o3, '$.intercepted'),
       JSON_VALUE(@taa_o3, '$.nearest_distance'), JSON_VALUE(@taa_o3, '$.reason')
UNION ALL SELECT 'E4 faint SIM swap, far away', JSON_VALUE(@taa_o4, '$.intercepted'),
       JSON_VALUE(@taa_o4, '$.nearest_distance'), JSON_VALUE(@taa_o4, '$.reason');

-- ------------------------------------------------------------------
-- 4. When intensity should count: exact Euclidean distance.  E4 is a
-- faint SIM swap with a location jump -- the same shape as a known
-- pattern but at under half the intensity -- so cosine flags it while
-- l2 lets it through to a lower-severity review queue.
-- ------------------------------------------------------------------
-- === 4. Same screen under exact Euclidean distance (threshold 0.30) ===

CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 1), 'taa_known_anomalous', 'event', 0.30, 'l2', @taa_l1);
CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 2), 'taa_known_anomalous', 'event', 0.30, 'l2', @taa_l2);
CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 3), 'taa_known_anomalous', 'event', 0.30, 'l2', @taa_l3);
CALL fractal_agent_outlier_intercept((SELECT event FROM taa_proposed WHERE id = 4), 'taa_known_anomalous', 'event', 0.30, 'l2', @taa_l4);
SELECT 'E1 swap + port-out + new handset' AS label, JSON_VALUE(@taa_l1, '$.intercepted') AS intercepted_l2
UNION ALL SELECT 'E2 routine plan upgrade', JSON_VALUE(@taa_l2, '$.intercepted')
UNION ALL SELECT 'E3 new handset, same city', JSON_VALUE(@taa_l3, '$.intercepted')
UNION ALL SELECT 'E4 faint SIM swap, far away', JSON_VALUE(@taa_l4, '$.intercepted');

-- ------------------------------------------------------------------
-- 5. Reasoning: the justification an analyst sees next to the held
-- event (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: justification for holding E1 ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line justification for holding this account change for review',
    JSON_OBJECT('event', (SELECT label FROM taa_proposed WHERE id = 1),
                'screen', JSON_EXTRACT(@taa_t1, '$'))) AS justification;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE taa_known_anomalous, taa_proposed;
