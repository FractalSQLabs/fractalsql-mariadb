-- demo/demo-vertical-maritime-defense.sql
--
-- Industry vertical: Maritime, Aviation & Defense (AIS & Radar Tracking).
--
-- A synthetic AIS-style vessel fleet (30 vessels, lat/lon/speed/heading
-- track vectors) with one vessel given a deliberate course deviation --
-- fractal_search_trajectory's "current vs. baseline" delta search is a
-- direct fit for track-deviation detection ("what changed"), and DFA's
-- scaling exponent on a heading-change series is a real fit for
-- maneuvering-pattern irregularity (smooth transit vs. erratic track).
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- full account):
--   - every fractal_agent_* engine is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field');`
--   - fractal_search_telemetry/fractal_search_trajectory/
--     fractal_agent_track_anomaly all return REAL vmd_vessels.id values
--     as doc_id, so no remap is needed anywhere in this file, even
--     though vessel 7's deviation UPDATE relocates its row.
--   - fractal_agent_track_anomaly's real signature ends right after the
--     heading series: (track_table, emb_col, baseline_vec, current_vec,
--     heading_series, OUT p_result) -- no trailing k or id_col.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_track_anomaly,
--      fractal_agent_recommend_diverse -- sections 0-4 need nothing else)
--   3. Reasoning configured (see docs/COOKBOOK.md) -- Section 4's
--      fractal_agent_track_anomaly preset calls fractal_reason internally.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-maritime-defense.sql
--
-- Safe to re-run: vmd_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() here is
-- unseeded, so exact values differ run to run -- the demo's narrative
-- points, like vessel 7's deliberate deviation, are still deterministic).
-- Section markers below are plain comments, not executed statements.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 30 vessels, each with a BASELINE track vector (their filed/typical
-- route: [lat_norm, lon_norm, speed_norm, heading_norm]) and a CURRENT
-- track vector. Vessel 7 gets a deliberate large deviation (course
-- change + speed drop -- a classic "gone dark then reappeared off
-- track" pattern); everyone else's current stays close to baseline
-- (normal transit noise).
-- ------------------------------------------------------------------
-- === 1. 30 vessels: baseline vs. current AIS track vectors ===

DROP TABLE IF EXISTS vmd_vessels;
CREATE TABLE vmd_vessels (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    mmsi        VARCHAR(32),
    -- JSON, not a fixed-width vector column: MariaDB's vector storage
    -- convention (see sql/install_udf.sql's "REPRESENTATION" note) is
    -- a JSON-array-of-numbers string holding the fixed-width AIS track
    -- state ([lat_norm, lon_norm, speed_norm, heading_norm]), without
    -- a distinct column type for it.
    -- "current" is renamed "current_pos": same convention
    -- demo-agents.sql's own agents_demo_tracks table already uses for
    -- this exact maritime/track-anomaly domain.
    baseline    JSON,
    current_pos JSON
);

-- MariaDB 11.4 has no LATERAL derived tables (confirmed live in this
-- repo, see demo-agents.sql's own note on agents_demo_vehicles/
-- agents_demo_tracks) and no generate_series(). A recursive CTE
-- replaces generate_series(1,30); baseline is built from 4 independent
-- RAND() calls per row (fine -- a row's own 4 components don't need to
-- correlate with EACH OTHER, only baseline needs to correlate with
-- that SAME row's current_pos, which the follow-up UPDATE handles via
-- JSON_EXTRACT off the just-inserted baseline -- same technique
-- demo-agents.sql already uses for agents_demo_vehicles/agents_demo_tracks).
INSERT INTO vmd_vessels (mmsi, baseline)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 30
)
SELECT CONCAT('MMSI-', 100000000 + gs),
       JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM seq;

UPDATE vmd_vessels
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline,'$[0]') + (RAND()-0.5)*0.05,
        JSON_EXTRACT(baseline,'$[1]') + (RAND()-0.5)*0.05,
        JSON_EXTRACT(baseline,'$[2]') + (RAND()-0.5)*0.1,
        JSON_EXTRACT(baseline,'$[3]') + (RAND()-0.5)*0.1);

-- Vessel 7's deliberate deviation: large heading/speed change from
-- baseline. JSON_EXTRACT reads the per-element value directly (no
-- fractal_vector [n] subscript operator to work around here at all).
UPDATE vmd_vessels
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline,'$[0]') + 0.6, JSON_EXTRACT(baseline,'$[1]') - 0.5,
        JSON_EXTRACT(baseline,'$[2]') - 0.9, JSON_EXTRACT(baseline,'$[3]') + 0.8)
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. fractal_search_trajectory: current vs. baseline DELTA for the
-- flagged vessel -- which stored tracks does this deviation most
-- resemble? "What changed", not "what's closest" -- see that
-- procedure's own doc comment in sql/install_udf.sql.
-- ------------------------------------------------------------------
-- doc_id in the JSON result is already vmd_vessels' real `id` column
-- (fractal_search_trajectory resolves the table's own PRIMARY KEY
-- internally), so no remap is needed here even though vessel 7's
-- deviation UPDATE relocated its row.
-- === 2. fractal_search_trajectory: vessel 7's deviation vs. the fleet ===

-- Blueprint (raw primitive): the current-vs-baseline DELTA search for
-- vessel 7's deviation. Generalized by the shipped
-- fractal_agent_track_anomaly preset in Section 4, which folds this
-- trajectory search together with the heading-change DFA exponent and
-- a reasoning step.
-- SET @flagged_baseline = (SELECT baseline FROM vmd_vessels WHERE id = 7);
-- SET @flagged_current  = (SELECT current_pos FROM vmd_vessels WHERE id = 7);
-- CALL fractal_search_trajectory(
--     'vmd_vessels', 'current_pos', @flagged_baseline, @flagged_current, 5, @t
-- );
-- SELECT v.mmsi, jt.dist AS distance
--   FROM JSON_TABLE(@t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
--   JOIN vmd_vessels v ON v.id = jt.doc_id
--  ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry / fractal_explore: nearest-track lookup
-- (who's near a contact-of-interest position) and diverse-track
-- clustering (representative traffic patterns across the whole fleet).
--
-- fractal_search_telemetry also returns real vmd_vessels.id values as
-- doc_id directly, so, same as Section 2, no ctid mapping is needed
-- here either, even for the plain (not cohort-filtered) table scan.
-- ------------------------------------------------------------------
-- === 3. Nearest vessels to a contact position, and diverse fleet traffic patterns ===

-- Nearest vessels to a contact-of-interest position:
CALL fractal_search_telemetry('vmd_vessels', 'current_pos',
                               '[0.2, 0.2, 0.5, 0.0]', 5, @t);
SELECT v.mmsi, jt.dist AS distance
  FROM JSON_TABLE(@t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN vmd_vessels v ON v.id = jt.doc_id
 ORDER BY jt.dist;

-- Diverse representative traffic patterns across the fleet:
-- --- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---

-- Blueprint (raw primitive): returns a diverse representative set of
-- the fleet's traffic-pattern embeddings. fractal_explore takes the
-- corpus inline rather than as a table/column reference, so the
-- corpus has to be assembled first, same approach as
-- demo-business-intelligence.sql's own Scout Discovery section.
-- SET @corpus = (SELECT JSON_ARRAYAGG(current_pos) FROM vmd_vessels);
-- SELECT fractal_explore(@corpus, '[0,0,0,0]',
--     '{"population_size": 6, "iterations": 8, "walk": 0}') AS p;

-- Productized preset: the shipped engine returns real vessel ids
-- (item_id) + scores (1 - cosine_distance) with session-global
-- repulsion enabled, then we restore the session (the engine leaves
-- diversify on -- the caller owns that policy) so later sections see
-- the same diversify-off state as before. The blueprint's zero query
-- is query-agnostic (explore samples the space); recommend_diverse is
-- query-anchored, so anchor on the first vessel's own current vector.
-- No id_col arg: the catalog table's own PRIMARY
-- KEY is returned directly, see this file's header.
CALL fractal_agent_recommend_diverse(
    'vmd_vessels', 'current_pos',
    (SELECT current_pos FROM vmd_vessels ORDER BY id LIMIT 1),
    6, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
 ORDER BY score DESC;
SELECT fractal_diversify_disable(CONNECTION_ID());

-- ------------------------------------------------------------------
-- 4. fractal_dimension_dfa: maneuvering-pattern irregularity. A smooth
-- transit heading series (vessel on a steady course) vs. vessel 7's
-- erratic heading series (evasive/anomalous maneuvering) -- DFA's
-- alpha separates the two: near-random-walk (smooth, ~1.3-1.5) vs.
-- much rougher/anti-persistent behavior for erratic maneuvering.
-- ------------------------------------------------------------------
-- === 4. fractal_dimension_dfa: heading-change series, normal vs. flagged vessel ===

-- Normal vessel (smooth heading drift over 120 samples):
SELECT fractal_dimension_dfa(
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        SELECT t, SUM(step) OVER (ORDER BY t) AS cum FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 120)
            SELECT t, (RAND() - 0.5) * 0.03 AS step FROM seq
        ) s
    ) c)
) AS normal_vessel_alpha;

-- Vessel 7 (erratic heading swings over the same window):
-- Blueprint (raw primitive): the flagged vessel's heading-change DFA
-- exponent. Generalized below by the fractal_agent_track_anomaly
-- preset, which folds this together with the Section 2 trajectory
-- search and a reasoning step. (The normal-vessel DFA above stays raw
-- -- a comparison baseline the engine, which takes a single heading
-- series, has no home for.)
-- SELECT fractal_dimension_dfa(
--     (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
--         SELECT t, SUM(step) OVER (ORDER BY t) AS cum FROM (
--             WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 120)
--             SELECT t, (RAND() - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step FROM seq
--         ) s
--     ) c)
-- ) AS flagged_vessel_alpha;

-- Productized preset: the shipped engine returns the real nearest
-- fleet vessel (fractal_search_trajectory over vessel 7's
-- baseline->current, its own PRIMARY KEY resolved internally), the
-- real trajectory_distance, the real heading-series DFA exponent, plus
-- a real rationale. No trailing k/id_col -- the call ends right after
-- heading_series (see this file's header).
-- --- Preset: fractal_agent_track_anomaly (raw trajectory+dfa form preserved above) ---
CALL fractal_agent_track_anomaly(
    'vmd_vessels', 'current_pos',
    (SELECT baseline FROM vmd_vessels WHERE id = 7),
    (SELECT current_pos FROM vmd_vessels WHERE id = 7),
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        SELECT t, SUM(step) OVER (ORDER BY t) AS cum FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 120)
            SELECT t, (RAND() - 0.5) * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS step FROM seq
        ) s
    ) c),
    @r);
SELECT JSON_VALUE(@r, '$.nearest_fleet_id') AS nearest_fleet_id,
       JSON_VALUE(@r, '$.trajectory_distance') AS trajectory_distance,
       JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 5. Reasoning: the "does vessel 7's track need attention?" narrative is
-- now produced by the fractal_agent_track_anomaly preset's rationale
-- column in Section 4 (the same trajectory deviation + heading DFA,
-- folded into one reasoning step).
-- ------------------------------------------------------------------
-- === 5. Reasoning: absorbed into the Section 4 track_anomaly rationale ===

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vmd_vessels;
