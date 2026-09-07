-- demo/demo-vertical-fleet-logistics.sql
--
-- Industry vertical: Autonomous Fleet Management & Last-Mile Delivery.
--
-- A 40-vehicle delivery fleet with route-embedding vectors, one vehicle
-- running a deliberately-detouring route. Diverse depot-coverage
-- clustering, a cohort-restricted search (today's route-3 vehicles
-- only), current-vs-baseline detour detection, and GPS-trace
-- complexity via box-counting.
--
-- Structural details, confirmed against sql/install_udf.sql and
-- sql/install_agents.sql (see demo-agents.sql's own header for the
-- fuller account, not re-derived here):
--   - fractal_agent_recommend_diverse / fractal_agent_detour_classify
--     are PROCEDUREs with a trailing OUT p_result JSON param here, not
--     RETURNS TABLE functions, so every "SELECT ... FROM
--     fractal_agent_x(...)" below becomes
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r, ...)`.
--   - fractal_search_telemetry/_trajectory are PROCEDUREs too, and
--     already resolve + return each scanned table's own REAL
--     PRIMARY KEY value as "doc_id" (see sql/install_udf.sql's
--     _fractalsql_scan_corpus). There is no position-remapping step
--     anywhere in this file, and no doc_id = id - 1 shortcut either:
--     vehicle 5's UPDATE relocating its row, or a cohort filter's scan
--     order diverging from id order, has no effect on doc_id, since
--     doc_id is always the row's own primary key.
--   - fractal_explore(corpus, query, params) takes the corpus inline
--     as a JSON array rather than as a table/column reference (see
--     demo-business-intelligence.sql Section 6).
--   - There is no fixed-width vector column type here with a
--     write-time hard error on a dimension mismatch: this extension's
--     portable-path convention for these exact agents (see
--     demo-agents.sql's agents_demo_vehicles fixture) is a plain JSON
--     column populated via JSON_ARRAY()/JSON_EXTRACT() instead. Native
--     VECTOR(n) is 11.7+-only (see sql/install_udf.sql's own header on
--     the portable vs. native path) and not used for this fixture.
--
-- Prerequisites:
--   1. fractalsql-mariadb installed and `SOURCE sql/install_udf.sql;`
--      and `SOURCE sql/install_agents.sql;` already run against the
--      target database (sections 0-4 need nothing else).
--   2. Section 6 narrates that its reasoning step is folded into the
--      Section 5 fractal_agent_detour_classify preset rationale, which
--      calls fractal_reason() internally -- see docs/reasoning-setup.md for
--      reasoning setup.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-fleet-logistics.sql
--
-- Safe to re-run: vfl_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo: the mariadb CLI has no direct equivalent of
-- psql's \timing; use `SET profiling = 1; ... SHOW PROFILES;` if you
-- want per-statement timing. Section markers below are plain comments,
-- not executed statements (unlike psql's \echo, which prints even when
-- run non-interactively).
--
-- NOTE: MariaDB has no session-wide random seed equivalent to
-- setseed(). RAND(seed) reseeds per-call, not per-session, so results
-- here are not bit-reproducible run to run. Flagged as a known
-- limitation, not a silent omission.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 40 delivery vehicles across 4 routes, each with a BASELINE route
-- vector (planned stop sequence, embedded) and a CURRENT route vector
-- (today's actual telemetry). Vehicle 5 gets a deliberate large
-- detour; everyone else's current stays close to baseline (normal
-- traffic/timing noise).
-- ------------------------------------------------------------------
-- === 1. 40 delivery vehicles: baseline vs. current route vectors ===

DROP TABLE IF EXISTS vfl_vehicles;
CREATE TABLE vfl_vehicles (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    van_id      VARCHAR(16),
    route_no    INT,
    -- JSON, not a fixed-width vector column, see this file's header.
    -- A feature-extraction bug that silently changed the vector's
    -- width is not a hard write-time error here: this extension's
    -- portable JSON-column convention has no dimension enforcement
    -- built in.
    baseline    JSON,
    current_pos JSON
);

-- MariaDB 11.4 doesn't support LATERAL derived tables (confirmed live
-- in demo-agents.sql, both comma-join and JOIN LATERAL forms error).
-- Insert baseline only first (4 independent RAND() calls -- fine,
-- each row's 4 components don't need to correlate with EACH OTHER,
-- only baseline needs to correlate with that SAME row's current_pos),
-- then a follow-up UPDATE derives current_pos off the just-inserted
-- baseline via JSON_EXTRACT -- same technique demo-agents.sql already
-- uses for its own vehicle fixture.
INSERT INTO vfl_vehicles (van_id, route_no, baseline)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 40
)
SELECT CONCAT('VAN-', gs), MOD(gs - 1, 4) + 1,
       JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM seq;

UPDATE vfl_vehicles
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline, '$[0]') + (RAND()-0.5)*0.06,
        JSON_EXTRACT(baseline, '$[1]') + (RAND()-0.5)*0.06,
        JSON_EXTRACT(baseline, '$[2]') + (RAND()-0.5)*0.06,
        JSON_EXTRACT(baseline, '$[3]') + (RAND()-0.5)*0.06);

-- Vehicle 5's deliberate detour: current route vector far from its
-- plan. Overrides the ordinary-noise current_pos just set above for
-- id = 5.
UPDATE vfl_vehicles
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline, '$[0]') - 0.7, JSON_EXTRACT(baseline, '$[1]') + 0.6,
        JSON_EXTRACT(baseline, '$[2]') + 0.5, JSON_EXTRACT(baseline, '$[3]') - 0.4)
 WHERE id = 5;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse route/zone clustering across the fleet --
-- depot coverage planning ("what KINDS of routes are actually running
-- today") without scanning all 40 by hand.
-- ------------------------------------------------------------------
-- === 2. fractal_explore: diverse route/zone clustering ===
-- --- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---

-- Blueprint (raw primitive): returns a diverse representative set of
-- route/zone-cluster embeddings across the fleet. fractal_explore
-- takes its corpus inline (a JSON array), not a table/column pair.
-- SELECT fractal_explore(
--     (SELECT JSON_ARRAYAGG(current_pos) FROM vfl_vehicles), '[0,0,0,0]',
--     '{"population_size": 6, "iterations": 8, "walk": 0}');

-- Productized preset: the shipped engine returns real vehicle ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session so the section-3 cohort search below sees the same
-- diversify-off state as before (the engine leaves diversify on -- the
-- caller owns that policy). The blueprint's zero query is query-agnostic
-- (explore samples the space); recommend_diverse is query-anchored, so
-- anchor on the first vehicle's own current_pos vector. No id_col
-- argument and no ctid/row_number id-resolution step -- this engine
-- returns the table's own real PRIMARY KEY directly (see this file's
-- header).
CALL fractal_agent_recommend_diverse(
    'vfl_vehicles', 'current_pos',
    (SELECT current_pos FROM vfl_vehicles ORDER BY id LIMIT 1),
    6, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
ORDER BY score DESC;
SELECT fractal_diversify_disable(CONNECTION_ID());

-- ------------------------------------------------------------------
-- 3. Cohort-restricted search: "today's route-3 vehicles only" --
-- fractal_search_telemetry's table_name argument is a plain text table
-- name, so a cohort filter composes by searching a filtered table
-- instead (the same cohort-then-search shape
-- fractal_hybrid_clinical_search uses internally for its doc_ids
-- allowlist, without needing that clinically-named function here).
--
-- vfl_route3_cohort is created as an explicit column list with its own
-- PRIMARY KEY (id), not `CREATE TEMPORARY TABLE ... AS SELECT *`:
-- fractal_search_telemetry (sql/install_udf.sql's
-- _fractalsql_scan_corpus) requires the table it scans to carry
-- exactly one single-column PRIMARY KEY, and a plain AS SELECT copy
-- drops that constraint even though it copies the data.
--
-- It's a PERMANENT table, not TEMPORARY, even though it's scratch
-- data dropped/recreated on every run (confirmed against a live
-- server): MariaDB's information_schema -- which _fractalsql_scan_
-- corpus uses for BOTH the PRIMARY KEY check above and its vector_col
-- type lookup -- has no visibility into TEMPORARY tables at all
-- (SHOW CREATE TABLE reports the PK correctly; information_schema.
-- key_column_usage/columns return zero rows regardless). A
-- TEMPORARY table here fails scan_corpus's PK check even with an
-- explicit single-column PRIMARY KEY declared.
--
-- fractal_search_telemetry always resolves and returns the scanned
-- table's own real PRIMARY KEY value as doc_id, so a plain join on
-- id = doc_id is correct regardless of which rows are in the cohort
-- or what order they were inserted/updated in, even though vehicle 5
-- was UPDATEd (see this file's header, and
-- demo-vertical-cybersecurity-threat-detection.sql's Section 3/4 for
-- the same point).
-- ------------------------------------------------------------------
-- === 3. Cohort-restricted search: route-3 vehicles only ===

DROP TABLE IF EXISTS vfl_route3_cohort;
CREATE TABLE vfl_route3_cohort (
    id          INT PRIMARY KEY,
    van_id      VARCHAR(16),
    route_no    INT,
    baseline    JSON,
    current_pos JSON
);
INSERT INTO vfl_route3_cohort
SELECT * FROM vfl_vehicles WHERE route_no = 3;

CALL fractal_search_telemetry('vfl_route3_cohort', 'current_pos',
                               '[0.3, -0.3, 0.2, 0.1]', 5, @r);
SELECT v.van_id, jt.dist AS distance
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           doc_id INT    PATH '$.doc_id',
           dist   DOUBLE PATH '$.dist')) AS jt
  JOIN vfl_route3_cohort v ON v.id = jt.doc_id
ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for vehicle
-- 5 -- detour detection, "what changed" not "what's closest".
--
-- Unlike section 3, this scans the FULL vfl_vehicles table -- which
-- includes vehicle 5's own updated row. That's not a problem here:
-- fractal_search_trajectory
-- already returns real vehicle ids as doc_id, so a plain join on
-- id = doc_id is correct regardless of physical/insertion order (see
-- this file's header).
-- ------------------------------------------------------------------
-- === 4. fractal_search_trajectory: vehicle 5's detour vs. the fleet ===

-- Blueprint (raw primitive): the current-vs-baseline DELTA search for
-- vehicle 5's detour. Generalized by the shipped
-- fractal_agent_detour_classify preset in Section 5, which folds this
-- trajectory search together with the GPS-trace box-counting complexity
-- and a reasoning step.
-- CALL fractal_search_trajectory(
--     'vfl_vehicles', 'current_pos',
--     (SELECT baseline FROM vfl_vehicles WHERE id = 5),
--     (SELECT current_pos FROM vfl_vehicles WHERE id = 5),
--     5, @r);
-- SELECT v.van_id, jt.dist AS distance
--   FROM JSON_TABLE(@r, '$[*]' COLUMNS (
--            doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) AS jt
--   JOIN vfl_vehicles v ON v.id = jt.doc_id
-- ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 5. fractal_dimension_boxcount: GPS-trace complexity for vehicle 5's
-- detoured route (a 2D wandering path, 200 samples) -- a smooth planned
-- route would trace a near-straight path (dimension close to 1); a
-- detour with backtracking/wandering pushes it higher.
-- ------------------------------------------------------------------
-- === 5. fractal_dimension_boxcount: vehicle 5's GPS trace complexity ===

-- Blueprint (raw primitive): the GPS trace's box-counting complexity.
-- Generalized below by the fractal_agent_detour_classify preset, which
-- folds this together with the Section 4 trajectory search and a
-- reasoning step. MariaDB has no LATERAL (see this file's header), so
-- pairing the two ordinates uses a UNION ALL instead (same idiom
-- demo-agents.sql already uses for this exact agent's own fixture).
-- SELECT fractal_dimension_boxcount(
--     (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t, ord), ']') FROM (
--         SELECT t, ord, SUM(step) OVER (PARTITION BY ord ORDER BY t) AS cum
--           FROM (
--               WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 200)
--               SELECT t, 1 AS ord, (RAND()-0.5)*0.3 AS step FROM seq
--               UNION ALL
--               SELECT t, 2 AS ord, (RAND()-0.5)*0.3 AS step FROM seq
--           ) s
--     ) c),
--     2
-- ) AS gps_trace_dimension;

-- Productized preset: the shipped engine returns the real nearest fleet
-- vehicle (fractal_search_trajectory over vehicle 5's baseline->
-- current_pos, resolved via the table's real PRIMARY KEY, no
-- ctid/row_number needed), the real trajectory_distance, the real
-- GPS-trace box-counting complexity, plus a real rationale. Trailing
-- arg is boxcount_dim only, no k or id_col (see this file's header).
-- --- Preset: fractal_agent_detour_classify (raw trajectory+boxcount form preserved above) ---
CALL fractal_agent_detour_classify(
    'vfl_vehicles', 'current_pos',
    (SELECT baseline FROM vfl_vehicles WHERE id = 5),
    (SELECT current_pos FROM vfl_vehicles WHERE id = 5),
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t, ord), ']') FROM (
        SELECT t, ord, SUM(step) OVER (PARTITION BY ord ORDER BY t) AS cum
          FROM (
              WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 200)
              SELECT t, 1 AS ord, (RAND()-0.5)*0.3 AS step FROM seq
              UNION ALL
              SELECT t, 2 AS ord, (RAND()-0.5)*0.3 AS step FROM seq
          ) s
    ) c),
    2, @r);
SELECT JSON_VALUE(@r, '$.nearest_fleet_id') AS nearest_fleet_id,
       JSON_VALUE(@r, '$.trajectory_distance') AS trajectory_distance,
       JSON_VALUE(@r, '$.trace_complexity') AS trace_complexity,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 6. Reasoning: the dispatch narrative for vehicle 5 is now produced by
-- the fractal_agent_detour_classify preset's rationale column in
-- Section 5 (the same trajectory deviation + GPS-trace complexity,
-- folded into one reasoning step).
-- ------------------------------------------------------------------
-- === 6. Reasoning: absorbed into the Section 5 detour_classify rationale ===

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE vfl_vehicles, vfl_route3_cohort;
