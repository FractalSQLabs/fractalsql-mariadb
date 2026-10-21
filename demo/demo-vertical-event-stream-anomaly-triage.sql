-- demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- Industry vertical: High-frequency event-stream latency and rate anomaly
-- triage. DOMAIN kit: Four endpoints x 96 one-minute intervals of request
-- latency; one endpoint (EP-C) develops an accelerating latency ramp (a
-- timeout cascade) and a second (EP-B) has a retry-storm oscillation in its
-- request rate. `fractal_agent_anomaly_triage` flags the latency regime
-- shift, `fractal_periodogram` finds the retry-storm period, and
-- `fractal_search_trajectory` finds which endpoints' success-rate / latency
-- / timeout / fill health has moved the same way EP-C's did.
--
--   1. fractal_dimension_drift / fractal_agent_anomaly_triage: which
--      endpoint's latency changed regime.
--   2. fractal_periodogram: the dominant period of each endpoint's request
--      rate (a retry loop shows as a sharp line).
--   3. fractal_search_trajectory: endpoints whose health moved like the
--      degraded one (baseline -> current).
--   4. A closing fractal_reason() writes the triage line.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- Safe to re-run: esa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Latency is a steady base with a small cycle; EP-C ramps quadratically
--     from interval 65.
--   * Request rate: EP-B carries a 12-interval oscillation; the others are
--     flat with a faint 7-interval ripple.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Event-stream telemetry: 4 endpoints x 96 intervals ===
DROP TABLE IF EXISTS esa_latency;
CREATE TABLE esa_latency (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO esa_latency (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p2) AS (
         SELECT 'EP-A', 42, 0
         UNION ALL SELECT 'EP-B', 55, 0
         UNION ALL SELECT 'EP-C', 48, 0.0024
         UNION ALL SELECT 'EP-D', 61, 0)
SELECT ent, g, base * (1.0 + 0.004 * (g % 8)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
  FROM s, gs;
DROP TABLE IF EXISTS esa_rate;
CREATE TABLE esa_rate (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO esa_rate (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p1, p2) AS (
         SELECT 'EP-A', 900, 0, 0
         UNION ALL SELECT 'EP-B', 800, 0.3, 0
         UNION ALL SELECT 'EP-C', 950, 0, 0
         UNION ALL SELECT 'EP-D', 700, 0, 0)
SELECT ent, g, base * (1.0 + 0.02 * sin(2 * pi() * g / 7.0) + p1 * sin(2 * pi() * g / 12.0))
  FROM s, gs;
SELECT ent, count(*) AS intervals FROM esa_latency GROUP BY ent ORDER BY ent;


-- === 2. Hand-composed: latency regime drift per endpoint ===
DROP TABLE IF EXISTS esa_lprof;
CREATE TABLE esa_lprof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, CAST(JSON_VALUE(a.dj, '$.drift') AS DOUBLE) AS drift, CAST(JSON_VALUE(a.dj, '$.recent_alpha') AS DOUBLE) AS recent_alpha, CAST(JSON_VALUE(a.dj, '$.baseline_alpha') AS DOUBLE) AS baseline_alpha
  FROM (SELECT ent, arr, fractal_dimension_drift(arr, 32) AS dj FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM esa_latency GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM esa_latency GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha, ROUND(drift, 4) AS drift, ROUND(recent_alpha, 4) AS recent_alpha, ROUND(baseline_alpha, 4) AS baseline_alpha
  FROM esa_lprof ORDER BY ent;


-- === 3. fractal_agent_anomaly_triage: degraded vs healthy endpoint ===
CALL fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-C', 32, @esa_tri0);
CALL fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-A', 32, @esa_tri1);
SELECT 'EP-C (degraded)' AS entity, JSON_VALUE(@esa_tri0, '$.threat_score') AS threat_score, JSON_VALUE(@esa_tri0, '$.anomaly_type') AS anomaly_type, JSON_VALUE(@esa_tri0, '$.triage_summary') AS triage_summary
UNION ALL SELECT 'EP-A (healthy)', JSON_VALUE(@esa_tri1, '$.threat_score'), JSON_VALUE(@esa_tri1, '$.anomaly_type'), JSON_VALUE(@esa_tri1, '$.triage_summary');


-- === 4. Retry-storm period: fractal_periodogram on the request rate ===
DROP TABLE IF EXISTS esa_rprof;
CREATE TABLE esa_rprof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, CAST(JSON_VALUE(a.pj, '$.freqs[0]') AS DOUBLE) AS freq
  FROM (SELECT ent, arr, fractal_periodogram(arr, 1) AS pj FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM esa_rate GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM esa_rate GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(freq, 4) AS top_freq, ROUND(1.0 / freq, 1) AS samples_per_cycle
  FROM esa_rprof ORDER BY ent;


-- === 5. Endpoint health trajectory: who moved like EP-C ===
DROP TABLE IF EXISTS esa_health;
CREATE TABLE esa_health (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT esa_health_dims CHECK (JSON_LENGTH(vec) = 4)
);
INSERT INTO esa_health (id, label, vec) VALUES
    (1, 'EP-01', '[0.05, -0.06, 0.03, -0.04]'),
    (2, 'EP-02', '[0.1, -0.02, 0.06, 0.02]'),
    (3, 'EP-03 (degraded)', '[1.4, 0.9, 1.1, 1.2]'),
    (4, 'EP-04', '[0.2, 0.06, 0, 0.14]'),
    (5, 'EP-05', '[0, 0.1, 0.03, 0.2]'),
    (6, 'EP-06', '[0.05, 0.14, 0.06, -0.1]'),
    (7, 'EP-07 (degraded)', '[1.4, 0.9, 1.1, 1.2]'),
    (8, 'EP-08', '[0.15, -0.06, 0, 0.02]'),
    (9, 'EP-09', '[0.2, -0.02, 0.03, 0.08]'),
    (10, 'EP-10', '[0, 0.02, 0.06, 0.14]'),
    (11, 'EP-11 (degraded)', '[1.4, 0.9, 1.1, 1.2]'),
    (12, 'EP-12', '[0.1, 0.1, 0, -0.1]'),
    (13, 'EP-13', '[0.15, 0.14, 0.03, -0.04]'),
    (14, 'EP-14', '[0.2, -0.1, 0.06, 0.02]'),
    (15, 'EP-15', '[0, -0.06, 0.09, 0.08]'),
    (16, 'EP-16', '[0.05, -0.02, 0, 0.14]');
CALL fractal_search_trajectory('esa_health', 'vec',
    '[0.05, 0, 0.03, 0]',    -- baseline
    '[1.4, 0.9, 1.1, 1.2]',    -- current
    5, @esa_t);
DROP TABLE IF EXISTS esa_traj;
CREATE TABLE esa_traj AS
SELECT ROW_NUMBER() OVER (ORDER BY jt.dist, w.id) AS rk, w.id, w.label AS label, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@esa_t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN esa_health w ON w.id = jt.doc_id;

SELECT rk, id, label, distance FROM esa_traj ORDER BY rk;


-- === 6. Reasoning: triage line ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line event-stream triage: which endpoint is degrading, since when, and the likely cause',
    JSON_OBJECT('worst_endpoint', (SELECT ent FROM esa_lprof ORDER BY drift DESC LIMIT 1), 'retry_storm_endpoint', (SELECT ent FROM esa_rprof ORDER BY freq DESC LIMIT 1), 'nearest_degraded_health', (SELECT label FROM esa_traj WHERE rk = 1))) AS narrative;


-- === 7. Headline check ===
SELECT CONCAT('HEADLINE kit=event-stream-anomaly-triage ', CASE WHEN (SELECT drift FROM esa_lprof WHERE ent = 'EP-C') > 0.5 AND (SELECT drift FROM esa_lprof WHERE ent = 'EP-A') < 0 AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') > 0.07 AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') < 0.10 AND (SELECT count(*) FROM esa_traj WHERE distance < 0.001) >= 3 THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj;
