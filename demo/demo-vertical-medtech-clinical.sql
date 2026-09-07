-- demo/demo-vertical-medtech-clinical.sql
--
-- Industry vertical: MedTech, Clinical Telemetry & Patient Monitoring.
--
-- Synthetic patient vitals + telemetry (cohort-filtered search, current-
-- vs-baseline drift) plus the four domain-specific geometry functions on
-- small, pre-extracted geometric fixtures (a vessel graph, a triangulated
-- mesh, a nerve fiber skeleton) -- these take PRE-EXTRACTED geometry, not
-- raw imaging data (see fractal_vascular_network/_cortical_folding/
-- _nerve_plexus_metric's own doc comments in sql/install_udf.sql for that
-- scope boundary).
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- full account):
--   - fractal_agent_patient_deterioration_triage is a PROCEDURE with a
--     trailing OUT p_result JSON param, not a RETURNS TABLE function,
--     invoked as `CALL fractal_agent_x(...args, @r); SELECT
--     JSON_VALUE(@r,'$.field');`. Its signature is (patient_table,
--     vec_col, query_vec, baseline_vec, current_vec, cohort_doc_ids,
--     k, OUT p_result): k is the last IN arg, no trailing id_col.
--   - fractal_hybrid_clinical_search / fractal_search_trajectory also
--     return REAL vmc_patients.id values as doc_id directly, so no
--     remap is needed anywhere in this file.
--   - cohort_doc_ids is a JSON array of the cohort's real `id` values
--     (age > 65 AND condition = 'sepsis'), computed with ordinary SQL,
--     never a raw SQL predicate string, matching
--     sql/install_udf.sql's own doc comment on fractal_hybrid_clinical_search.
--   - The result now also carries cohort_matches: the same ranked
--     cohort hits fractal_hybrid_clinical_search found, re-keyed as
--     {"id":..,"distance":..} objects, extracted below via
--     JSON_EXTRACT (a JSON array, not a scalar).
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_patient_deterioration_triage
--      -- sections 0-6 need nothing else)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- Section 3's
--      fractal_agent_patient_deterioration_triage preset calls
--      fractal_reason internally.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-medtech-clinical.sql
--
-- Safe to re-run: vmc_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() here is
-- unseeded, so exact values differ run to run -- the demo's narrative
-- points, like the forced sepsis-watch cohort rows, are still
-- deterministic). Section markers below are plain comments, not
-- executed statements.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 40 synthetic patients with a demographic/condition cohort and a
-- 5-dim current-vitals vector (heart rate, SpO2, systolic, diastolic,
-- temperature, each roughly normalized). One flagged "sepsis-watch"
-- cohort (age > 65 AND condition = 'sepsis') for Section 2.
-- ------------------------------------------------------------------
-- === 1. 40 synthetic patients: demographics + current vitals ===

DROP TABLE IF EXISTS vmc_patients;
CREATE TABLE vmc_patients (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    age       INT,
    -- Backtick-quoted -- same reserved-word-adjacent precedent
    -- demo-agents.sql's own agents_demo_patients table already uses
    -- for this exact column name.
    `condition` VARCHAR(32),
    -- JSON, not a fixed-width vector column: MariaDB's vector storage
    -- convention (see sql/install_udf.sql's "REPRESENTATION" note) is
    -- a JSON-array-of-numbers string holding the fixed, known-width
    -- [hr_z, spo2_z, systolic_z, diastolic_z, temp_z] vector, without
    -- a distinct column type for it.
    vitals    JSON
);

-- generate_series(1, 40) has no MariaDB equivalent -- a recursive CTE
-- replaces it. Otherwise unchanged: no LATERAL needed here (each row's
-- vitals components don't need to correlate with anything outside
-- their own row, unlike the maritime demo's baseline/current pair).
INSERT INTO vmc_patients (age, `condition`, vitals)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 40
)
SELECT
    CAST(ROUND(22 + (RAND() * 68)) AS SIGNED),
    CASE WHEN RAND() < 0.2 THEN 'sepsis'
         WHEN RAND() < 0.4 THEN 'post-op'
         ELSE 'routine' END,
    JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM seq;

-- Force at least a few real hits in the cohort filter below, deterministically.
UPDATE vmc_patients SET age = 70, `condition` = 'sepsis'
 WHERE id IN (3, 11, 27);

-- === 2. fractal_hybrid_clinical_search: cohort-restricted search ===
-- (cohort = age > 65 AND condition = sepsis, computed with ordinary SQL --
-- never a raw SQL predicate string, see fractal_hybrid_clinical_search's
-- own doc comment in sql/install_udf.sql. query stays a plain JSON
-- array here -- vitals being stored as JSON only changes how the
-- CORPUS is read, not this procedure's query argument shape.)

-- Blueprint (raw primitive): cohort-restricted hybrid search (the
-- age>65 AND condition='sepsis' sepsis-watch cohort). Generalized by
-- the shipped fractal_agent_patient_deterioration_triage preset in
-- Section 3, which folds this cohort search together with the
-- baseline->current drift search and a reasoning step. doc_ids here
-- are vmc_patients' own real `id` values, so no remap is needed even
-- though the Section 1 cohort-force UPDATE relocates rows.
-- SET @cohort = (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']')
--                  FROM vmc_patients WHERE age > 65 AND `condition` = 'sepsis');
-- CALL fractal_hybrid_clinical_search(
--     'vmc_patients', 'vitals', '[1, -1, 1, 1, 0.5]', @cohort, 5, @h);
-- SELECT jt.doc_id, jt.dist AS distance
--   FROM JSON_TABLE(@h, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt;

-- ------------------------------------------------------------------
-- 3. fractal_search_trajectory: one patient's CURRENT vitals vs their
-- own admission BASELINE -- "what changed", the natural query shape
-- for drift/trajectory monitoring (this procedure's own doc comment in
-- sql/install_udf.sql uses this exact patient-baseline example).
-- ------------------------------------------------------------------
-- === 3. fractal_search_trajectory: patient drift from admission baseline ===
-- (plain JSON-array literals here, not a distinct fractal_vector type --
-- vitals' JSON payload reads the same way for both the corpus scan and
-- these query-side literals.)

-- Blueprint (raw primitive): one patient's current vitals vs their
-- admission baseline -- the "what changed" drift search. Generalized
-- below by the shipped fractal_agent_patient_deterioration_triage
-- preset, which folds this trajectory search together with the
-- Section 2 cohort-restricted hybrid search and a reasoning step.
-- CALL fractal_search_trajectory(
--     'vmc_patients', 'vitals',
--     '[0.1,0.05,0.0,0.0,0.0]',   -- admission baseline
--     '[1.4,-1.1,0.9,0.7,1.2]',   -- current (deteriorating)
--     5, @t);
-- SELECT jt.doc_id, jt.dist AS distance
--   FROM JSON_TABLE(@t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt;

-- Productized preset: the shipped engine runs the cohort-restricted
-- hybrid search (nearest sepsis-watch cohort patient to the query
-- vitals, its own PRIMARY KEY resolved internally) and the
-- baseline->current drift search, then reasons. nearest_cohort_id/
-- cohort_distance/drift_distance/cohort_matches are real; rationale is
-- the real fractal_reason output. cohort_doc_ids is caller-built from
-- age>65 AND condition='sepsis' (the two-predicate cohort
-- fractal_agent_recall_hybrid's single filter can't express) -- plain
-- id order, no ctid mapping needed (see this file's header).
-- --- Preset: fractal_agent_patient_deterioration_triage (raw hybrid+trajectory form preserved above) ---
CALL fractal_agent_patient_deterioration_triage(
    'vmc_patients', 'vitals',
    '[1, -1, 1, 1, 0.5]',
    '[0.1, 0.05, 0.0, 0.0, 0.0]',
    '[1.4, -1.1, 0.9, 0.7, 1.2]',
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']')
       FROM vmc_patients WHERE age > 65 AND `condition` = 'sepsis'),
    5, @r);
SELECT JSON_VALUE(@r, '$.nearest_cohort_id') AS nearest_cohort_id,
       JSON_VALUE(@r, '$.cohort_distance') AS cohort_distance,
       JSON_VALUE(@r, '$.drift_distance') AS drift_distance,
       JSON_VALUE(@r, '$.rationale') AS rationale,
       JSON_EXTRACT(@r, '$.cohort_matches') AS cohort_matches;

-- ------------------------------------------------------------------
-- 4. fractal_vascular_network: a branching vessel graph -- a 28-node
-- centerline chain plus 2 branch leaves off node 10, node_coords in 3D
-- with real arc lengths from an upstream centerline trace. Needs >= 8
-- nodes AND enough of them for the internal box-counting dimension
-- estimator to find >= 3 valid eps-octaves (its own documented
-- "avg >= 3 points/occupied-cell" validity filter, same one
-- fractalsql-core's own boxcount unit tests calibrate against) -- a
-- too-small skeleton returns rc=-1, not a wrong number.
-- ------------------------------------------------------------------
-- === 4. fractal_vascular_network: vessel tortuosity/branch-density/dimension ===

-- fractal_vascular_network(node_coords_csv, edges_csv, edge_arc_length_csv)
-- takes CSV-or-JSON-array STRING arguments (see sql/install_udf.sql),
-- not a distinct array type. generate_series()+unnest()+WITH ORDINALITY
-- has no MariaDB equivalent -- a recursive CTE per column, flattened
-- via CONCAT/GROUP_CONCAT into the same bracketed-string shape,
-- replaces it. Each of nodes/edges/arcs is its own scalar subquery
-- (own recursive CTE, own row count), same "no LATERAL" workaround as
-- demo-agents.sql's agents_demo_vehicles/agents_demo_tracks tables.
DROP TABLE IF EXISTS vmc_vessel;
CREATE TEMPORARY TABLE vmc_vessel AS
SELECT
    -- 28-node chain (i=0..27) as flat (x,y,z) triples, x,y,z=(i,0,0),
    -- plus the 2 branch leaves off node 10: node 28=(10,1,0), node 29=(10,0,1).
    (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 27)
     SELECT CONCAT('[', GROUP_CONCAT(CONCAT(i, ',0,0') ORDER BY i SEPARATOR ','), ',10,1,0,10,0,1]')
       FROM seq) AS nodes,
    -- 27-edge centerline chain (i, i+1) for i=0..26, plus the 2 branch
    -- edges (10,28) and (10,29).
    (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 26)
     SELECT CONCAT('[', GROUP_CONCAT(CONCAT(i, ',', i + 1) ORDER BY i SEPARATOR ','), ',10,28,10,29]')
       FROM seq) AS edges,
    -- 29 edges total (27 chain + 2 branch), each a real arc length of 1.02.
    (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 28)
     SELECT CONCAT('[', GROUP_CONCAT('1.02' ORDER BY i SEPARATOR ','), ']')
       FROM seq) AS arcs;

SELECT fractal_vascular_network(nodes, edges, arcs) FROM vmc_vessel;

-- ------------------------------------------------------------------
-- 5. fractal_cortical_folding: a unit-cube surface mesh (8 vertices,
-- 12 triangular faces) -- a "smooth" (unfolded) reference case where
-- mesh area should closely match hull area (GI ~1.0), the same known-
-- answer sanity check fractalsql-core's own cortical.c unit tests use.
-- ------------------------------------------------------------------
-- === 5. fractal_cortical_folding: Gyrification Index on a reference mesh ===

-- fractal_cortical_folding(vertices_csv, faces_csv): plain
-- JSON-array-string literals (no computation involved here, just the
-- array-literal syntax).
SELECT fractal_cortical_folding(
    '[0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]',
    '[0,1,2, 0,2,3,   4,5,6, 4,6,7,   0,1,5, 0,5,4,
      3,2,6, 3,6,7,   0,3,7, 0,7,4,   1,2,6, 1,6,5]'
);

-- ------------------------------------------------------------------
-- 6. fractal_nerve_plexus_metric: an 80-fiber zigzag skeleton (corneal
-- confocal microscopy convention -- fiber length density, branch
-- density, box-counting dimension). Same box-counting-scale note as
-- Section 4 above -- 80 points is comfortably past the internal
-- estimator's minimum for a reliable answer.
-- ------------------------------------------------------------------
-- === 6. fractal_nerve_plexus_metric: corneal nerve fiber plexus ===

DROP TABLE IF EXISTS vmc_nerve;
CREATE TEMPORARY TABLE vmc_nerve AS
SELECT
    -- 80 points (i=0..79) as flat (x,y) pairs, x=i, y=0.05*sin(i) -- a
    -- gentle zigzag skeleton.
    (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 79)
     SELECT CONCAT('[', GROUP_CONCAT(CONCAT(i, ',', 0.05 * SIN(i)) ORDER BY i SEPARATOR ','), ']')
       FROM seq) AS coords,
    -- 79-edge chain (i, i+1) for i=0..78.
    (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 78)
     SELECT CONCAT('[', GROUP_CONCAT(CONCAT(i, ',', i + 1) ORDER BY i SEPARATOR ','), ']')
       FROM seq) AS edges;

SELECT fractal_nerve_plexus_metric(coords, 2, edges) FROM vmc_nerve;

-- ------------------------------------------------------------------
-- 7. Reasoning: the cohort-search + trajectory-drift clinical narrative
-- is now produced by the fractal_agent_patient_deterioration_triage
-- preset's rationale column in Section 3. The vessel/cortical/nerve
-- geometry primitives in Sections 4-6 stay raw (domain geometry with no
-- engine home) -- their own output columns are the showcase.
-- ------------------------------------------------------------------
-- === 7. Reasoning: absorbed into the Section 3 patient_deterioration_triage rationale ===

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vmc_patients;
