-- demo/demo-vertical-recommendation-search.sql
--
-- Industry vertical: Advanced Recommendation, Search & Discovery Engines.
--
-- A product/content catalog for diverse "you might also like" discovery,
-- a table-backed top-k telemetry search, the full stateful-diversity
-- loop (enable Diversify, search, report negative feedback on a result,
-- re-search, confirm it's avoided -- the real differentiator over plain
-- top-K or MMR: it's stateful and feedback-learning, not a one-shot
-- re-ranking heuristic), and cross-modal search (content + behavior
-- vectors, weighted).
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- full account):
--   - every fractal_agent_* engine is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field');`
--   - fractal_search_telemetry (and the fractal_agent_recommend_diverse/
--     fractal_agent_feedback_audit presets built on it) return REAL
--     vrs_catalog.id values as doc_id, so no remap is needed anywhere
--     in this file.
--   - fractal_diversify_enable/_disable/_set_params, fractal_detect_
--     collapse, fractal_explain_result, and fractal_isolate_background all
--     take an explicit session_id (CONNECTION_ID(), by convention) as
--     their first argument here, since MariaDB is one shared process
--     serving every connection: the ctx registry needs an explicit
--     session key to tell connections apart. See sql/install_udf.sql's
--     own header on this.
--   - fractal_explore(corpus, query, params) takes the corpus inline
--     rather than as a table/column reference, so the corpus has to be
--     assembled by the caller first (see Section 2's blueprint below).
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_recommend_diverse,
--      fractal_agent_feedback_audit -- both pure retrieval/analytics, no
--      LLM -- sections 0-5 need nothing else)
--   3. Reasoning configured (see docs/COOKBOOK.md) -- Section 6 calls
--      fractal_reason directly.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-recommendation-search.sql
--
-- Safe to re-run: vrs_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() here is
-- unseeded, so exact values differ run to run -- the demo's narrative
-- points, like the 6 genre clusters and the negative-feedback loop, are
-- still deterministic). Section markers below are plain comments, not
-- executed statements.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 300-item catalog, 6 genre clusters x 50 items in R^8. Centers
-- spread uniformly across [-0.9, 0.9] with per-item jitter -- matching
-- demo/benchmark.sql's own approach (narrow clustering in the box
-- center would silently understate Scout's real diversity result, per
-- that file's own load-bearing comment). Fixed-width (8-dim) vectors
-- are built as literal JSON_ARRAY(...) calls, not a per-dimension
-- generate_series loop -- the same idiom demo-vertical-maritime-defense.sql
-- already uses for its own fixed-width track vectors.
-- ------------------------------------------------------------------
-- === 1. 300-item catalog: 6 genre clusters in R^8 ===

DROP TABLE IF EXISTS vrs_genres;
DROP TABLE IF EXISTS vrs_catalog;
-- JSON, not a fixed-width vector column: MariaDB's vector storage
-- convention (see sql/install_udf.sql's "REPRESENTATION" note) is a
-- JSON-array-of-numbers string holding a fixed-width genre-centroid
-- and catalog-item embedding shape, without a distinct column type
-- for it.
CREATE TABLE vrs_genres (genre_id INT PRIMARY KEY, name VARCHAR(32), center JSON);
CREATE TABLE vrs_catalog (id BIGINT AUTO_INCREMENT PRIMARY KEY, genre_id INT, title VARCHAR(64), emb_arr JSON);

INSERT INTO vrs_genres (genre_id, name, center) VALUES
    (1, 'sci-fi',         JSON_ARRAY(RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9)),
    (2, 'documentary',    JSON_ARRAY(RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9)),
    (3, 'true-crime',     JSON_ARRAY(RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9)),
    (4, 'comedy',         JSON_ARRAY(RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9)),
    (5, 'strategy-games', JSON_ARRAY(RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9)),
    (6, 'cooking',        JSON_ARRAY(RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9, RAND()*1.8-0.9));

-- generate_series(1, 50) has no MariaDB equivalent; a recursive CTE
-- replaces it. JSON_VALUE(gc.center, '$[n]') is the per-dimension
-- lookup -- MariaDB's JSON type has no [n] subscript operator either,
-- same fix demo-vertical-maritime-defense.sql's own baseline/current_pos
-- UPDATEs already use via JSON_EXTRACT.
INSERT INTO vrs_catalog (genre_id, title, emb_arr)
WITH RECURSIVE seq(item_n) AS (
    SELECT 1 UNION ALL SELECT item_n + 1 FROM seq WHERE item_n < 50
)
SELECT gc.genre_id, CONCAT(gc.name, '-item-', seq.item_n),
       JSON_ARRAY(
           JSON_VALUE(gc.center, '$[0]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[1]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[2]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[3]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[4]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[5]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[6]') + (RAND() - 0.5) * 0.25,
           JSON_VALUE(gc.center, '$[7]') + (RAND() - 0.5) * 0.25)
FROM vrs_genres gc
CROSS JOIN seq;

SELECT COUNT(*) AS items, COUNT(DISTINCT genre_id) AS genres FROM vrs_catalog;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse "you might also like" -- a spread across
-- distinct genre basins, not K near-duplicates from one genre.
-- ------------------------------------------------------------------
-- === 2. fractal_search_explore: diverse recommendations ===
-- --- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---

-- Blueprint (raw primitive): returns a diverse spread of representative
-- catalog embeddings across distinct genre basins (not K near-duplicates
-- from one genre). fractal_explore takes the corpus inline rather than
-- as a table/column reference, so the corpus has to be assembled
-- first, same approach as demo-business-intelligence.sql's own Scout
-- Discovery section.
-- SET @vrs_corpus = (SELECT JSON_ARRAYAGG(emb_arr) FROM vrs_catalog);
-- SELECT fractal_explore(@vrs_corpus, '[0,0,0,0,0,0,0,0]',
--     '{"population_size": 6, "iterations": 8, "walk": 0}') AS p;

-- Productized preset: the shipped engine returns real catalog ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session so the section-3 top-k and section-4 diversify loop
-- below see the same diversify-off baseline as before (the engine leaves
-- diversify on -- the caller owns that policy; section 4 re-enables it
-- explicitly for its own audit). The blueprint's zero query is query-agnostic
-- (explore samples the space); recommend_diverse is query-anchored, so
-- anchor on the first catalog item's own embedding. No id_col arg:
-- the catalog table's own PRIMARY KEY is returned directly.
CALL fractal_agent_recommend_diverse(
    'vrs_catalog', 'emb_arr',
    (SELECT emb_arr FROM vrs_catalog ORDER BY id LIMIT 1),
    6, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
 ORDER BY score DESC;
SELECT fractal_diversify_disable(CONNECTION_ID());

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry: real top-k rows (doc_id + distance) --
-- the primitive fractal_search_explore/fractal_search don't provide on
-- their own (see that procedure's own doc comment in sql/install_udf.sql).
-- ------------------------------------------------------------------
-- === 3. fractal_search_telemetry: top-5 nearest catalog items ===

-- doc_id in the JSON result is already vrs_catalog's real `id` column
-- (fractal_search_telemetry resolves the table's own PRIMARY KEY
-- internally), so no remap is needed here.
CALL fractal_search_telemetry('vrs_catalog', 'emb_arr',
                               (SELECT center FROM vrs_genres WHERE genre_id = 1), 5, @t);
SELECT c.title, jt.dist AS distance
  FROM JSON_TABLE(@t, '$[*]' COLUMNS (doc_id BIGINT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN vrs_catalog c ON c.id = jt.doc_id
 ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 4. Diversify/Repulsion session state: enable it, report NEGATIVE
-- feedback on a result, and confirm the session picks it up.
--
-- fractal_diversify_enable()'s own doc comment scopes this to
-- "fractal_search results" specifically -- fractal_search_telemetry's
-- top_k (and hybrid_clinical_search/search_trajectory/cross_modal_
-- search, which all share it) is deliberately a literal, ground-truth
-- "k nearest REAL rows to this query" list, not repulsion-adjusted --
-- that's what makes it trustworthy for the doc_id/distance pairs the
-- rest of this demo joins back to real catalog rows. Repulsion state
-- from fractal_isolate_background is real (see the diagnostics below),
-- but today it only steers fractal_search()'s own single converged
-- point in the abstract [-1,1]^dim space, not this table-backed top-k
-- list -- so re-running the SAME fractal_search_telemetry query below
-- correctly returns the SAME top result, not a different one.
-- ------------------------------------------------------------------
-- === 4. Diversify/Repulsion: session-level feedback state ===

-- Blueprint (raw primitive): the stateful diversify/repulsion loop --
-- enable repulsion, set params, warm the D_q rolling window with varied
-- genre-center queries, report negative feedback on the genre-3 top
-- result (fractal_isolate_background on its doc_id -- the doc_id IS the
-- handle), read back the real diversity_quotient + session diagnostics,
-- and disable. Generalized below by the shipped
-- fractal_agent_feedback_audit preset, which runs this whole audit cycle
-- self-contained (and self-disables diversify, unlike recommend_diverse).
-- session_id (CONNECTION_ID()) is required and first on every
-- diversify/repulsion call here (see this file's header).
-- SELECT fractal_diversify_enable(CONNECTION_ID());
-- SELECT fractal_diversify_set_params(CONNECTION_ID(),
--     '{"window_n": 5, "repulsion_sigma": 0.3, "repulsion_weight": 0.5}');
-- -- Warm the D_q rolling window with varied genre-center queries,
-- -- cycling genre_id (g % 6) + 1 across 8 iterations; MariaDB 11.4 has
-- -- no LATERAL, so the real working equivalent is a cursor loop over
-- -- a small driver table -- see
-- -- fractal_agent_feedback_audit's own implementation in
-- -- sql/install_agents.sql (Engine I) for that exact pattern; this
-- -- blueprint just shows one representative iteration:
-- CALL fractal_search_telemetry('vrs_catalog', 'emb_arr',
--     (SELECT center FROM vrs_genres WHERE genre_id = 1), 3, @ignored);
-- -- ... repeated across genre_id 1..6 (twice around) ...
-- CALL fractal_search_telemetry('vrs_catalog', 'emb_arr',
--     (SELECT center FROM vrs_genres WHERE genre_id = 3), 1, @before);
-- SET @before_doc_id = JSON_VALUE(@before, '$[0].doc_id');
-- SELECT fractal_isolate_background(CONNECTION_ID(), @before_doc_id);
-- SELECT fractal_detect_collapse(CONNECTION_ID()) AS dq,
--        fractal_explain_result(CONNECTION_ID()) AS diagnostics;
-- SELECT fractal_diversify_disable(CONNECTION_ID());

-- Productized preset: the shipped engine enables repulsion, warms the
-- D_q window from the genre centers, reports negative feedback on the
-- genre-3 audit target, reads back the real diversity_quotient (NOT NaN
-- once the window is warm) + session diagnostics, and self-disables.
-- Pure analytics, no LLM.
-- --- Preset: fractal_agent_feedback_audit (raw diversify loop preserved above) ---
CALL fractal_agent_feedback_audit(
    'vrs_catalog', 'emb_arr',
    (SELECT center FROM vrs_genres WHERE genre_id = 3),
    'vrs_genres', 'center', 8, 3, @r);
SELECT JSON_VALUE(@r, '$.diversity_quotient') AS diversity_quotient,
       JSON_VALUE(@r, '$.explanation') AS explanation;

-- ------------------------------------------------------------------
-- 5. Cross-modal search: content embedding + behavior embedding,
-- weighted (weighted CONCATENATION, not a blend -- each modality keeps
-- its own dimensions; vector_col must already be stored in this
-- combined shape).
-- ------------------------------------------------------------------
-- === 5. fractal_cross_modal_search: content + behavior, weighted ===

DROP TABLE IF EXISTS vrs_modal_items;
-- JSON -- combined_vec is content (4d) + behavior (4d) concatenated
-- into one 8-dim stored vector; fractal_cross_modal_search re-scales
-- and re-concatenates the two QUERY vectors to match at search time.
CREATE TABLE vrs_modal_items (id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(64), combined_vec JSON);
INSERT INTO vrs_modal_items (title, combined_vec)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 60
)
SELECT CONCAT('modal-item-', gs),
       JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1,   -- content (4d)
                   RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)  -- behavior (4d)
FROM seq;

CALL fractal_cross_modal_search(
    'vrs_modal_items', 'combined_vec',
    '[0.6,0.6,-0.6,0.0]',   -- content query
    '[0.2,-0.2,0.2,0.2]',   -- behavior query
    0.7, 5, @t);
SELECT m.title, jt.dist AS distance
  FROM JSON_TABLE(@t, '$[*]' COLUMNS (doc_id BIGINT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN vrs_modal_items m ON m.id = jt.doc_id
 ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 6. Reasoning: explain the recommendation set in plain language.
-- ------------------------------------------------------------------
-- === 6. Reasoning over the recommendation set ===

CALL fractal_search_telemetry('vrs_catalog', 'emb_arr',
                               '[0,0,0,0,0,0,0,0]', 8, @gt);
SELECT fractal_reason(
    CONNECTION_ID(),
    'each item is a catalog title with a distance score from a diverse discovery search -- explain what kind of viewer/listener would want this mix and why the spread across genres matters',
    (SELECT JSON_ARRAYAGG(JSON_OBJECT('title', c.title, 'genre_id', c.genre_id, 'distance', jt.dist))
       FROM JSON_TABLE(@gt, '$[*]' COLUMNS (doc_id BIGINT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
       JOIN vrs_catalog c ON c.id = jt.doc_id)
);

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vrs_genres, vrs_catalog, vrs_modal_items;
