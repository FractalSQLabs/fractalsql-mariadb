-- demo/demo-vertical-smart-cities-iot.sql
--
-- Industry vertical: Smart Cities & IoT Sensor Grids.
--
-- A 400-sensor city grid (traffic/air-quality/noise, jittered 20x20
-- placement) for spatial coverage-complexity analysis, one sensor's
-- reading series carrying a deliberate regime shift (an air-quality
-- event) for DFA/drift detection, and diverse representative-zone
-- sampling across the grid.
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- full account):
--   - every fractal_agent_* engine is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field');`
--   - fractal_agent_network_coverage_alert and fractal_agent_regime_triage
--     take no table/id-column arguments at all: the point cloud, the
--     drift series, and the plain series go straight in as JSON args
--     (see sql/install_agents.sql).
--   - fractal_agent_recommend_diverse's signature has no id_col
--     arg either: the catalog table's own PRIMARY KEY is returned
--     directly as item_id.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_network_coverage_alert,
--      fractal_agent_regime_triage, fractal_agent_recommend_diverse --
--      sections 0-1 need nothing else)
--   3. Reasoning configured (see docs/COOKBOOK.md) -- Sections 2 and 3's
--      presets call fractal_reason internally. Confirm before running:
--        SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation');
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-smart-cities-iot.sql
--
-- Safe to re-run: vsc_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() here is
-- unseeded, so exact values differ run to run -- the demo's narrative
-- points, like the sensor grid's deliberate air-quality event, are
-- still deterministic). Section markers below are plain comments, not
-- executed statements.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 400 sensors: a jittered 20x20 grid placement (lat/lon-style x,y
-- position) plus a 3-dim reading vector [traffic, air_quality, noise].
-- A grid-like layout, not sparse random scatter, is what the box-
-- counting-based functions below need to find enough occupied-cell
-- structure across eps scales (same requirement
-- demo/demo-vertical-sovereign-edge-ai.sql's facility-grid section documents).
-- ------------------------------------------------------------------
-- === 1. 400 sensors: jittered 20x20 city grid + readings ===

DROP TABLE IF EXISTS vsc_sensors;
CREATE TABLE vsc_sensors (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    sensor_id VARCHAR(32),
    -- pos stays a flat 2-element JSON array deliberately -- it's
    -- unnested below (via a correlated JSON_TABLE cross join, the same
    -- idiom demo/benchmark.sql's own bt_bench_corpus section already
    -- uses to reach into an outer table's JSON column) into flat
    -- point-cloud input for fractal_dimension_boxcount/
    -- fractal_morphological_complexity, not read as a vector_col search
    -- corpus.
    pos       JSON,   -- [x, y] placement
    -- reading is a plain JSON vector -- it's read as a vector_col
    -- search corpus by fractal_agent_recommend_diverse below
    -- (fractal_search_telemetry's own table/column scan already reads
    -- a JSON column transparently), a fixed-width
    -- [traffic, air_quality, noise] vector.
    reading   JSON
);

-- MariaDB 11.4 has no LATERAL derived tables (confirmed live, see
-- demo-agents.sql's own note) and no generate_series(). A cross join of
-- two inline JSON_TABLE row/col ranges replaces
-- generate_series(0,19) r CROSS JOIN generate_series(0,19) c -- the
-- same idiom demo-agents.sql's own fractal_agent_network_coverage_alert
-- section (16) already uses for its 20x20 grid.
INSERT INTO vsc_sensors (sensor_id, pos, reading)
SELECT CONCAT('SENSOR-', rr.r0 * 20 + cc.c0 + 1),
       JSON_ARRAY(rr.r0 + (RAND() - 0.5) * 0.3, cc.c0 + (RAND() - 0.5) * 0.3),
       JSON_ARRAY(RAND() * 2 - 1, RAND() * 2 - 1, RAND() * 2 - 1)
  FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
 CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc;

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount / fractal_morphological_complexity over
-- the sensor grid's spatial layout -- coverage-density diagnostics
-- (dimension near 2.0 + moderate lacunarity means even, gap-free
-- coverage; a lower dimension or high lacunarity would flag sparse or
-- clustered deployment).
-- ------------------------------------------------------------------
-- === 2. Sensor grid spatial coverage: dimension + morphological complexity ===

-- Flatten each row's [x,y] pos into one big row-major point-cloud
-- array, ordered by sensor id then x/y. JSON_TABLE(s.pos, ...)
-- correlated to the outer table s needs no LATERAL keyword here (same
-- pattern demo/benchmark.sql's
-- own bt_bench_corpus section already confirms works).
SELECT fractal_dimension_boxcount(
    (SELECT CONCAT('[', GROUP_CONCAT(jt.v ORDER BY s.id, jt.ord SEPARATOR ','), ']')
       FROM vsc_sensors s
       CROSS JOIN JSON_TABLE(s.pos, '$[*]' COLUMNS (ord FOR ORDINALITY, v DOUBLE PATH '$')) AS jt),
    2
) AS coverage_dimension;

-- Blueprint (raw primitive): the sensor grid's morphological complexity
-- (box-counting dimension + lacunarity). Generalized below by the shipped
-- fractal_agent_network_coverage_alert preset, which folds this together
-- with the telemetry drift series and a reasoning step.
-- SELECT fractal_morphological_complexity(
--     (SELECT CONCAT('[', GROUP_CONCAT(jt.v ORDER BY s.id, jt.ord SEPARATOR ','), ']')
--        FROM vsc_sensors s
--        CROSS JOIN JSON_TABLE(s.pos, '$[*]' COLUMNS (ord FOR ORDINALITY, v DOUBLE PATH '$')) AS jt),
--     2
-- ) AS coverage_complexity;

-- Productized preset: the shipped engine returns the real morphological
-- dimension + lacunarity (fractal_morphological_complexity over the grid's
-- pos point-cloud, the 400-pt 20x20 grid this function needs) and the real
-- drift_detected flag (fractal_dimension_drift over the air-quality event
-- series -- |drift| > 0.5), plus a real rationale. The coverage boxcount
-- above stays raw (no engine home -- boxcount-only, no drift/reason step).
-- No table/id-col args at all here: the point cloud and drift series
-- go straight in, see this file's header.
-- --- Preset: fractal_agent_network_coverage_alert (raw morphological form preserved above) ---
CALL fractal_agent_network_coverage_alert(
    (SELECT CONCAT('[', GROUP_CONCAT(jt.v ORDER BY s.id, jt.ord SEPARATOR ','), ']')
       FROM vsc_sensors s
       CROSS JOIN JSON_TABLE(s.pos, '$[*]' COLUMNS (ord FOR ORDINALITY, v DOUBLE PATH '$')) AS jt),
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        SELECT t, SUM(step) OVER (ORDER BY t) AS cum
          FROM (
              WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 240)
              SELECT t, CASE WHEN t <= 150 THEN (RAND() - 0.5) * 0.02
                             ELSE (RAND() - 0.5) * 0.16 END AS step
                FROM seq
          ) s
    ) c),
    2, 48, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.morph_dimension') AS morph_dimension,
       JSON_VALUE(@r, '$.lacunarity') AS lacunarity,
       JSON_VALUE(@r, '$.drift_detected') AS drift_detected,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 3. fractal_dimension_dfa / fractal_dimension_drift: a sensor's
-- air-quality reading series carries a deliberate regime shift (an
-- event) at t=150 of 240 samples.
-- ------------------------------------------------------------------
-- === 3. fractal_dimension_dfa/_drift: air-quality event detection ===

-- Blueprint (raw primitives): the air-quality series' long-range-
-- correlation exponent (DFA) and its regime-change drift report.
-- Generalized below by the shipped fractal_agent_regime_triage preset,
-- which runs both over the same series and reasons.
-- SELECT fractal_dimension_dfa(
--     (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
--         SELECT t, SUM(step) OVER (ORDER BY t) AS cum
--           FROM (
--               WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 240)
--               SELECT t, CASE WHEN t <= 150 THEN (RAND() - 0.5) * 0.02
--                              ELSE (RAND() - 0.5) * 0.16 END AS step
--                 FROM seq
--           ) s
--     ) c)
-- ) AS whole_series_alpha;
--
-- SELECT fractal_dimension_drift(
--     (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
--         SELECT t, SUM(step) OVER (ORDER BY t) AS cum
--           FROM (
--               WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 240)
--               SELECT t, CASE WHEN t <= 150 THEN (RAND() - 0.5) * 0.02
--                              ELSE (RAND() - 0.5) * 0.16 END AS step
--                 FROM seq
--           ) s
--     ) c),
--     48
-- ) AS drift_report;

-- Productized preset: the shipped engine returns the real DFA exponent,
-- the real drift_detected flag (|drift| > 0.5), and the real
-- recent_alpha/baseline_alpha, plus a real rationale.
-- --- Preset: fractal_agent_regime_triage (raw dfa+drift form preserved above) ---
CALL fractal_agent_regime_triage(
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        SELECT t, SUM(step) OVER (ORDER BY t) AS cum
          FROM (
              WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 240)
              SELECT t, CASE WHEN t <= 150 THEN (RAND() - 0.5) * 0.02
                             ELSE (RAND() - 0.5) * 0.16 END AS step
                FROM seq
          ) s
    ) c),
    64, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.drift_detected') AS drift_detected,
       JSON_VALUE(@r, '$.recent_alpha') AS recent_alpha,
       JSON_VALUE(@r, '$.baseline_alpha') AS baseline_alpha,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 4. Scout Discovery: diverse representative sample of reading
-- profiles across the grid -- "what KINDS of zones do we actually
-- have" (quiet-residential vs. high-traffic-commercial vs. ...) rather
-- than scanning all 400 sensors by hand.
-- ------------------------------------------------------------------
-- === 4. fractal_explore / recommend_diverse: diverse zone reading-profiles ===
-- --- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---

-- Blueprint (raw primitive): returns a diverse representative set of
-- reading-profile embeddings -- "what KINDS of zones do we have".
-- fractal_explore(corpus, query, params) takes the corpus inline
-- rather than as a table/column reference, so the corpus has to be
-- assembled first, same approach as demo-business-intelligence.sql's
-- own Scout Discovery section.
-- SET @corpus = (SELECT JSON_ARRAYAGG(reading) FROM vsc_sensors);
-- SELECT fractal_explore(@corpus, '[0,0,0]',
--     '{"population_size": 6, "iterations": 8, "walk": 0}') AS p;

-- Productized preset: the shipped engine returns real sensor ids
-- (item_id) + scores (1 - cosine_distance) with session-global
-- repulsion enabled, then we restore the session (the engine leaves
-- diversify on -- the caller owns that policy) so later sections see
-- the same diversify-off state as before. The blueprint's zero query
-- is query-agnostic (explore samples the space); recommend_diverse is
-- query-anchored (nearest-neighbor top-k), so anchor on the first
-- sensor's own reading -- the nearest result is itself (score 1) and
-- the rest are a repulsion-diverse spread. No id_col arg: the catalog
-- table's own PRIMARY KEY is returned directly, see this file's header.
CALL fractal_agent_recommend_diverse(
    'vsc_sensors', 'reading',
    (SELECT reading FROM vsc_sensors ORDER BY id LIMIT 1),
    6, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
 ORDER BY score DESC;
SELECT fractal_diversify_disable(CONNECTION_ID());

-- ------------------------------------------------------------------
-- 5. Reasoning: the city-ops narrative over coverage + drift is now
-- produced by the fractal_agent_network_coverage_alert preset's
-- rationale column in Section 2 (the same coverage morphological
-- complexity + air-quality drift, folded into one reasoning step).
-- ------------------------------------------------------------------
-- === 5. Reasoning: absorbed into the Section 2 network_coverage_alert rationale ===

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vsc_sensors;
