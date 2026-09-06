-- demo/benchmark-api-reference.sql
--
-- Real, structural details worth knowing before reading this file:
--   - fractal_search_debug, fractal_store_morphology, and
--     fractal_mine_topology_negatives (Section 8, "Named feature
--     store") don't exist in this extension's function catalog. Those
--     calls are replaced with plain notices below, not fabricated.
--   - fractal_search_telemetry/_hybrid_clinical_search/
--     _search_trajectory/_cross_modal_search are PROCEDUREs with a
--     trailing OUT p_result JSON here (sql/install_udf.sql), not
--     scalar functions, so every "SELECT fractal_x(...)" below becomes
--     CALL fractal_x(..., @r) then a JSON_TABLE over @r. Their result
--     objects use the key "dist".
--
-- A coverage pass over every callable function in sql/install_udf.sql
-- (roughly 34 functions: 9 core, a 4-function vectorizer group, and 21
-- v2.x additions), grouped by area. Distinct from demo/benchmark.sql (a
-- narrower Sniper/Scout/vectorizer head-to-head), this one's job is
-- coverage, not comparison.
--
-- Fixtures are deliberately small and reused across sections. Reasoning-
-- dependent calls are wrapped the same way demo-business-intelligence.sql's
-- bi_safe_t2s() guards fractal_text_to_sql, so a missing/misconfigured
-- reasoning endpoint degrades that one row instead of aborting the rest.
--
-- Run: mariadb -u root -p <your_database> < demo/benchmark-api-reference.sql
--
-- Safe to re-run: bmk_* tables are dropped and recreated each time.
--
-- NOTE: MariaDB has no session-wide random seed equivalent to setseed().
-- RAND(seed) reseeds per-call, not per-session, so results here are not
-- bit-reproducible run to run. Not fixed here (would require plumbing a
-- seed through every RAND() call below); flagged as a known limitation,
-- not a silent omission.

-- bmk_safe_call: takes the risky call as a dynamic-SQL TEXT expression
-- and EXECUTEs it inside its own procedure body (PREPARE/EXECUTE INTO a
-- session variable), the same reasoning as bi_safe_t2s(): an ordinary
-- `bmk_safe_call(label, fractal_reason(...))` call would evaluate
-- fractal_reason() in the OUTER query before the handler is in scope.
DROP PROCEDURE IF EXISTS bmk_safe_call;
DELIMITER $$
CREATE PROCEDURE bmk_safe_call(IN label VARCHAR(64), IN sql_expr TEXT, OUT result TEXT)
BEGIN
    DECLARE msg TEXT DEFAULT '';
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 msg = MESSAGE_TEXT;
        SET result = CONCAT('-- ', label, ' failed: ', msg);
    END;
    SET @bmk_sql = CONCAT('SELECT (', sql_expr, ') INTO @bmk_result');
    PREPARE bmk_stmt FROM @bmk_sql;
    EXECUTE bmk_stmt;
    DEALLOCATE PREPARE bmk_stmt;
    SET result = @bmk_result;
END$$
DELIMITER ;

-- === 0. Meta (2 functions): fractal_edition, fractal_version ===
SELECT fractalsql_edition(), fractalsql_version();

-- === 1. Search (3 functions): fractal_search, fractal_search_debug, fractal_search_explore ===
DROP TABLE IF EXISTS bmk_corpus;
CREATE TABLE bmk_corpus (id INT AUTO_INCREMENT PRIMARY KEY, emb_arr JSON);
INSERT INTO bmk_corpus (emb_arr)
SELECT JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 100) SELECT n FROM seq) s;

-- fractal_search is 4-arg (corpus, query, k, params); corpus=''+k=1
-- converges with no real corpus (see demo.sql Section 2). No
-- debug-mode variant exists here, so a plain notice replaces the call.
SELECT fractal_search('', '[0.6,0.8,0,0,0,0,0,0]', 1, '{"iterations": 30}');
SELECT 'fractal_search_debug: not available in fractalsql-mariadb' AS notice;

-- fractal_explore(corpus, query, params) takes the corpus inline
-- rather than as a table/column reference (see demo.sql Section 4).
SET @bmk_scout_corpus = (SELECT JSON_ARRAYAGG(emb_arr) FROM bmk_corpus);
SELECT COUNT(*) AS scout_population FROM JSON_TABLE(
    (SELECT fractal_explore(@bmk_scout_corpus, '[0,0,0,0,0,0,0,0]',
        '{"population_size": 6, "iterations": 6, "walk": 0}')),
    '$.population[*]' COLUMNS (p JSON PATH '$')
) AS jt;

-- === 2. Reasoning / text-to-SQL / embedding (4 functions, guarded) ===
-- fractal_reason/fractal_embed are still scalar functions (session_id
-- required as the first arg), so bmk_safe_call's dynamic-SQL-expression
-- wrapper still works for these two unchanged in shape.
CALL bmk_safe_call('fractal_reason', 'fractal_reason(CONNECTION_ID(), ''reply with a one-word confirmation'', ''{}'')', @reason_result);
SELECT @reason_result;
CALL bmk_safe_call('fractal_embed', 'JSON_LENGTH(fractal_embed(CONNECTION_ID(), ''a short benchmark sentence''))', @embed_dim);
SELECT @embed_dim;

-- fractal_schema_context/fractal_text_to_sql are PROCEDUREs with a
-- trailing OUT param here, not scalar functions. bmk_safe_call's
-- "wrap a scalar SQL expression" architecture cannot represent a CALL
-- statement with OUT params at all, so these two use a plain CALL +
-- read-the-OUT-var pattern instead (both procedures already report
-- their own failures via out_error rather than raising, so no
-- exception-handling wrapper is needed here either; see
-- demo-business-intelligence.sql's header for the same reasoning).
CALL fractal_schema_context('["bmk_corpus"]', @schema_context_result);
SELECT LEFT(@schema_context_result, 80);
CALL fractal_text_to_sql('how many rows are in bmk_corpus?', '["bmk_corpus"]', @text_to_sql_result, @text_to_sql_err);
SELECT @text_to_sql_result, @text_to_sql_err;

-- === 3. Vectorizer (4 functions) ===
DELETE FROM fractal_vectorizers WHERE source_table = 'bmk_docs';
DROP TABLE IF EXISTS bmk_docs;
CREATE TABLE bmk_docs (id INT AUTO_INCREMENT PRIMARY KEY, body TEXT NOT NULL, embedding JSON);
INSERT INTO bmk_docs (body)
SELECT CONCAT('benchmark document ', gs) FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 5) SELECT n AS gs FROM seq) s;
CALL fractal_vectorizer_create('bmk_docs', 'body', 'embedding', NULL, @bmk_vzid);
CALL fractal_vectorizer_process_queue(100, 600);
-- pause: further writes to bmk_docs stop queueing; resume immediately
-- after so the rest of this script (and a re-run) sees normal behavior.
CALL fractal_vectorizer_pause(@bmk_vzid);
CALL fractal_vectorizer_resume(@bmk_vzid);

-- === 4. Diversify / Repulsion + Feedback (7 functions) ===
-- Every one of these is session-scoped via CONNECTION_ID(); session_id
-- is REQUIRED as the first argument on all of them. MariaDB UDFs have
-- no named-parameter call syntax, so options like window_n become a
-- JSON config object, consistent with every other params argument here.
SELECT fractal_diversify_enable(CONNECTION_ID());
SELECT fractal_diversify_set_params(CONNECTION_ID(), '{"window_n": 5, "repulsion_sigma": 0.3, "repulsion_weight": 0.5}');
-- A single representative call covers this function for this coverage
-- smoke pass; repeated invocation isn't needed here.
-- fractal_search_telemetry is a PROCEDURE here
-- (trailing OUT p_result JSON), not a scalar function.
CALL fractal_search_telemetry('bmk_corpus', 'emb_arr', '[0,0,0,0,0,0,0,0]', 3, @bmk_telemetry);
SELECT JSON_VALUE(doc.value, '$.doc_id') AS doc_id FROM JSON_TABLE(
    @bmk_telemetry, '$[*]' COLUMNS (value JSON PATH '$')
) AS doc;
SELECT fractal_detect_collapse(CONNECTION_ID()) AS dq;
SELECT fractal_explain_result(CONNECTION_ID()) AS diagnostics;
-- fractal_feedback_report(session_id, result_handle, kind [, dwell_ms]):
-- result_handle=1 is a placeholder id, not tied to a real search
-- result from this script (fine for a coverage smoke pass; a real
-- caller would pass back a handle from an actual fractal_search call).
SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'positive', 4000);
SELECT fractal_isolate_background(CONNECTION_ID(), 2);
SELECT fractal_diversify_disable(CONNECTION_ID());

-- === 5. Fractal dimension analysis (3 functions) ===
SELECT fractal_dimension_dfa(
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 200)
        SELECT t, SUM((RAND()-0.5)*0.05) OVER (ORDER BY t) AS cum FROM seq
    ) c)
) AS dfa_alpha;

-- 20x20 jittered grid: box-counting needs a space-filling, not
-- scattered, fixture to find >= 3 valid eps-octaves (see
-- demo-vertical-sovereign-edge-ai.sql).
SELECT fractal_dimension_boxcount(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY r0, c0, ord), ']') FROM (
        SELECT r0, c0, 1 AS ord, r0 + (RAND()-0.5)*0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) cc
        UNION ALL
        SELECT r0, c0, 2 AS ord, c0 + (RAND()-0.5)*0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) cc
    ) g),
    2
) AS boxcount_dimension;

SELECT fractal_dimension_drift(
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 100)
        SELECT t, SUM((RAND()-0.5)*0.05) OVER (ORDER BY t) AS cum FROM seq
    ) c),
    32
) AS drift_report;

-- === 6. Portfolio optimization (1 function) ===
SELECT fractal_optimize_portfolio(
    '[0.05,0.08,0.03,0.12,0.07,0.01]',
    '[0.02,0,0,0,0,0, 0,0.03,0,0,0,0, 0,0,0.04,0,0,0, 0,0,0,0.05,0,0, 0,0,0,0,0.06,0, 0,0,0,0,0,0.07]',
    2, 42
) AS allocation;

-- === 7. Domain-specific geometry (4 functions) ===
-- 28-node chain + 2 branch leaves (see demo-vertical-medtech-clinical.sql
-- for why this scale is needed).
SELECT fractal_vascular_network(
    JSON_MERGE_PRESERVE(
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY i, ord), ']') FROM (
            SELECT i, 1 AS ord, CAST(i AS DOUBLE) AS v FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 27) SELECT i FROM seq) s
            UNION ALL SELECT i, 2 AS ord, 0.0 FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 27) SELECT i FROM seq) s
            UNION ALL SELECT i, 3 AS ord, 0.0 FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 27) SELECT i FROM seq) s
        ) g),
        '[10, 1, 0, 10, 0, 1]'
    ),
    JSON_MERGE_PRESERVE(
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY i, ord), ']') FROM (
            SELECT i, 1 AS ord, i AS v FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 26) SELECT i FROM seq) s
            UNION ALL SELECT i, 2 AS ord, i+1 FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 26) SELECT i FROM seq) s
        ) g),
        '[10, 28, 10, 29]'
    ),
    (SELECT CONCAT('[', GROUP_CONCAT('1.02'), ']') FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 28) SELECT i FROM seq) s)
) AS vascular;
-- TODO: the flattened-array construction above (three ordinal streams
-- unioned + GROUP_CONCAT) is verbose. Worth a helper stored function
-- (e.g. a small "zip 3 arrays interleaved" routine) rather than five
-- more demos reinventing the same pattern.

-- Unit cube surface mesh (8 vertices, 12 faces): known-answer
-- reference (GI ~1.0).
SELECT fractal_cortical_folding(
    '[0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]',
    '[0,1,2, 0,2,3, 4,5,6, 4,6,7, 0,1,5, 0,5,4, 3,2,6, 3,6,7, 0,3,7, 0,7,4, 1,2,6, 1,6,5]'
) AS cortical;

SELECT fractal_nerve_plexus_metric(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY i, ord), ']') FROM (
        SELECT i, 1 AS ord, CAST(i AS DOUBLE) AS v FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 79) SELECT i FROM seq) s
        UNION ALL SELECT i, 2 AS ord, 0.05 * SIN(i) FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 79) SELECT i FROM seq) s
    ) g),
    2,
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY i, ord), ']') FROM (
        SELECT i, 1 AS ord, i AS v FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 78) SELECT i FROM seq) s
        UNION ALL SELECT i, 2 AS ord, i+1 FROM (WITH RECURSIVE seq(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM seq WHERE i < 78) SELECT i FROM seq) s
    ) g)
) AS nerve;

SELECT fractal_morphological_complexity(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY r0, c0, ord), ']') FROM (
        SELECT r0, c0, 1 AS ord, r0 + (RAND()-0.5)*0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) cc
        UNION ALL
        SELECT r0, c0, 2 AS ord, c0 + (RAND()-0.5)*0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) cc
    ) g),
    2
) AS morphology;

-- === 8. Named feature store (2 functions) ===
-- fractal_store_morphology / fractal_mine_topology_negatives don't
-- exist in this extension: no named-feature-store surface is
-- implemented here. Plain notice, not a fabricated call.
SELECT 'fractal_store_morphology / fractal_mine_topology_negatives: not available in fractalsql-mariadb (no named feature-store surface exists here)' AS notice;

-- === 9. Table-backed telemetry search family (4 functions) ===
-- All four are PROCEDUREs here (trailing OUT p_result JSON), not
-- scalar functions: CALL + JSON_TABLE over the OUT var. Result
-- objects use the key "dist".
CALL fractal_search_telemetry('bmk_corpus', 'emb_arr', '[0,0,0,0,0,0,0,0]', 3, @bmk_r1);
SELECT JSON_VALUE(r, '$.doc_id') AS doc_id, JSON_VALUE(r, '$.dist') AS dist
FROM JSON_TABLE(@bmk_r1, '$[*]' COLUMNS (r JSON PATH '$')) t;

CALL fractal_hybrid_clinical_search(
    'bmk_corpus', 'emb_arr', '[0,0,0,0,0,0,0,0]',
    (SELECT CONCAT('[', GROUP_CONCAT(id), ']') FROM bmk_corpus WHERE id <= 20), 3, @bmk_r2);
SELECT JSON_VALUE(r, '$.doc_id') AS doc_id, JSON_VALUE(r, '$.dist') AS dist
FROM JSON_TABLE(@bmk_r2, '$[*]' COLUMNS (r JSON PATH '$')) t;

CALL fractal_search_trajectory(
    'bmk_corpus', 'emb_arr', '[0,0,0,0,0,0,0,0]', '[0.5,0.5,0,0,0,0,0,0]', 3, @bmk_r3);
SELECT JSON_VALUE(r, '$.doc_id') AS doc_id, JSON_VALUE(r, '$.dist') AS dist
FROM JSON_TABLE(@bmk_r3, '$[*]' COLUMNS (r JSON PATH '$')) t;

DROP TABLE IF EXISTS bmk_modal;
CREATE TABLE bmk_modal (id INT AUTO_INCREMENT PRIMARY KEY, combined_vec JSON);
INSERT INTO bmk_modal (combined_vec)
SELECT JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 20) SELECT n FROM seq) s;
CALL fractal_cross_modal_search(
    'bmk_modal', 'combined_vec', '[0.5,0.5]', '[-0.5,-0.5]', 0.5, 3, @bmk_r4);
SELECT JSON_VALUE(r, '$.doc_id') AS doc_id, JSON_VALUE(r, '$.dist') AS dist
FROM JSON_TABLE(@bmk_r4, '$[*]' COLUMNS (r JSON PATH '$')) t;

-- Benchmark complete, full API surface exercised. Tables left in
-- place for inspection. Clean up with:
--   DELETE FROM fractal_vectorizers WHERE source_table = 'bmk_docs';
--   DROP TABLE bmk_corpus, bmk_docs, bmk_modal;
--   DELETE FROM fractalsql_feature_store WHERE doc_id BETWEEN 1 AND 10;
--   DROP PROCEDURE bmk_safe_call;
