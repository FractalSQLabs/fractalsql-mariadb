-- demo/benchmark.sql
--
-- A quick, reproducible benchmark for FractalSQL: Sniper Search
-- convergence, Scout Discovery's diversity advantage over plain top-K,
-- and real vectorizer throughput. For the full large-scale evaluation,
-- see this repo's benchmark/ directory.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/benchmark.sql
--
-- Safe to re-run: all tables here are dropped and recreated each time,
-- prefixed bt_bench_* so they can't collide with demo.sql's own demo_* tables.

-- Vector args/results are JSON-encoded arrays throughout (no native
-- array/vector type across the compat floor). Pairwise dot products
-- are computed via JSON_TABLE() zipping the two arrays by index.

-- ------------------------------------------------------------------
-- Section 1: Sniper Search -- convergence latency + accuracy by dimension
-- ------------------------------------------------------------------
-- iterations/population_size held constant; only the query dimension
-- changes. cosine_similarity_to_query close to 1.0 confirms SFS
-- actually converged.

DELIMITER $$
CREATE PROCEDURE demo_bench_sniper(IN dim INT)
BEGIN
    DECLARE query_json JSON;
    DECLARE best_json JSON;
    SELECT JSON_ARRAYAGG(RAND()*2-1) INTO query_json FROM (
        WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < dim) SELECT n FROM seq
    ) s;
    -- fractal_search is 4-arg here (corpus, query, k, params);
    -- corpus='' (empty corpus) + k=1 runs Sniper mode with no real
    -- corpus, same as demo.sql Section 2.
    SET best_json = fractal_search('', query_json, 1, JSON_OBJECT('iterations', 50, 'population_size', 50));
    -- fractal_search's result is the canonical {"dim":...,"best_point":
    -- [...],...} object (sql/install_udf.sql), not a bare array -- pull
    -- best_point out via $.best_point[*], not $[*].
    SELECT dim AS dim,
        (SELECT SUM(a.v * b.v) FROM
            JSON_TABLE(best_json,  '$.best_point[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) a
         JOIN JSON_TABLE(query_json, '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) b ON a.idx = b.idx)
        / (SQRT((SELECT SUM(v*v) FROM JSON_TABLE(best_json,  '$.best_point[*]' COLUMNS (v DOUBLE PATH '$')) x))
         * SQRT((SELECT SUM(v*v) FROM JSON_TABLE(query_json, '$[*]' COLUMNS (v DOUBLE PATH '$')) x)))
        AS cosine_similarity_to_query;
END$$
DELIMITER ;

-- --- dim=8 ---
CALL demo_bench_sniper(8);
-- --- dim=32 ---
CALL demo_bench_sniper(32);
-- --- dim=128 ---
CALL demo_bench_sniper(128);
DROP PROCEDURE demo_bench_sniper;

-- ------------------------------------------------------------------
-- Section 2: Scout Discovery vs. naive top-K -- cluster diversity
-- ------------------------------------------------------------------
-- 20 synthetic clusters x 250 points in R^8 (5000 rows). Both methods
-- return K=50; count how many of the 20 clusters each method's results
-- represent -- the mode-collapse problem Scout Discovery fixes.

DROP TABLE IF EXISTS bt_bench_clusters;
DROP TABLE IF EXISTS bt_bench_corpus;
CREATE TABLE bt_bench_clusters (cluster_id INT PRIMARY KEY, center JSON);
CREATE TABLE bt_bench_corpus (id INT AUTO_INCREMENT PRIMARY KEY, cluster_id INT, emb_arr JSON);

-- Centers spread uniformly across [-0.9, 0.9]: a flat cross join (not
-- a correlated-looking subquery) so every base row gets its own
-- RAND() call.
INSERT INTO bt_bench_clusters (cluster_id, center)
SELECT c.cluster_id, JSON_ARRAYAGG(RAND() * 1.8 - 0.9)
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 20) SELECT n AS cluster_id FROM seq) c
CROSS JOIN (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 8) SELECT n AS dim_idx FROM seq) d
GROUP BY c.cluster_id;

INSERT INTO bt_bench_corpus (cluster_id, emb_arr)
SELECT c.cluster_id, JSON_ARRAYAGG(JSON_VALUE(c.center, CONCAT('$[', d.dim_idx - 1, ']')) + (RAND() - 0.5) * 0.2)
FROM bt_bench_clusters c
CROSS JOIN (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 250) SELECT n AS point_n FROM seq) pt
CROSS JOIN (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 8) SELECT n AS dim_idx FROM seq) d
GROUP BY c.cluster_id, pt.point_n;

-- Query is a small fixed off-center point, not a literal corpus row,
-- to avoid a degenerate exact-match tie.
-- --- naive top-K (brute-force cosine distance, plain SQL, K=50) ---
SET @query = '[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]';
DROP TEMPORARY TABLE IF EXISTS bt_topk;
CREATE TEMPORARY TABLE bt_topk AS
SELECT bc.emb_arr FROM bt_bench_corpus bc
ORDER BY (
    1 - (SELECT SUM(a.v * b.v) FROM
            JSON_TABLE(bc.emb_arr, '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) a
         JOIN JSON_TABLE(@query,   '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) b ON a.idx = b.idx)
      / (SQRT((SELECT SUM(v*v) FROM JSON_TABLE(bc.emb_arr, '$[*]' COLUMNS (v DOUBLE PATH '$')) x))
       * SQRT((SELECT SUM(v*v) FROM JSON_TABLE(@query, '$[*]' COLUMNS (v DOUBLE PATH '$')) x)) + 1e-9)
)
LIMIT 50;

SELECT COUNT(DISTINCT (
    SELECT bcl.cluster_id FROM bt_bench_clusters bcl
    ORDER BY (SELECT SUM(POW(a.v - b.v, 2)) FROM
                 JSON_TABLE(bcl.center,      '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) a
              JOIN JSON_TABLE(bt_topk.emb_arr, '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) b ON a.idx = b.idx)
    LIMIT 1
)) AS distinct_clusters_of_20_naive
FROM bt_topk;

-- mmr_lambda 0.2 weights diversity more heavily than the 0.5 default.
-- --- Scout Discovery (fractal_explore, population_size=50) ---
-- fractal_explore(corpus, query, params) takes the corpus inline
-- rather than as a table/column reference (same as demo.sql
-- Section 4). Aggregate the 5000-row corpus into that shape first, then
-- explode the "population" array in the JSON result.
SET @bench_corpus = (SELECT JSON_ARRAYAGG(emb_arr) FROM bt_bench_corpus);
DROP TEMPORARY TABLE IF EXISTS bt_scout;
CREATE TEMPORARY TABLE bt_scout AS
SELECT p AS emb_arr FROM JSON_TABLE(
    (SELECT fractal_explore(
        @bench_corpus, @query,
        '{"population_size": 50, "iterations": 8, "walk": 0, "mmr_lambda": 0.2}')),
    '$.population[*]' COLUMNS (p JSON PATH '$')
) AS jt;

SELECT COUNT(DISTINCT (
    SELECT bcl.cluster_id FROM bt_bench_clusters bcl
    ORDER BY (SELECT SUM(POW(a.v - b.v, 2)) FROM
                 JSON_TABLE(bcl.center,       '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) a
              JOIN JSON_TABLE(bt_scout.emb_arr, '$[*]' COLUMNS (idx FOR ORDINALITY, v DOUBLE PATH '$')) b ON a.idx = b.idx)
    LIMIT 1
)) AS distinct_clusters_of_20_scout
FROM bt_scout;

-- ------------------------------------------------------------------
-- Section 3: vectorizer/embed throughput
-- ------------------------------------------------------------------
-- Real, end-to-end vectorizer throughput -- 50 rows through your
-- configured embedding endpoint. Reflects that endpoint's own latency
-- as much as FractalSQL's.

DELETE FROM fractal_vectorizers WHERE source_table = 'bt_bench_docs';
DROP TABLE IF EXISTS bt_bench_docs;
CREATE TABLE bt_bench_docs (id INT AUTO_INCREMENT PRIMARY KEY, body TEXT NOT NULL, embedding JSON);
INSERT INTO bt_bench_docs (body)
SELECT CONCAT('benchmark document number ', gs, ': FractalSQL runs vector search directly inside MariaDB.')
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 50) SELECT n AS gs FROM seq) s;

CALL fractal_vectorizer_create('bt_bench_docs', 'body', 'embedding', NULL, @bench_vzid);

-- Processing 50 rows through the vectorizer (this timing includes real
-- network calls to your embedding endpoint):
CALL fractal_vectorizer_process_queue(100, 600);

-- Benchmark complete. Tables left in place for inspection -- safe to
-- re-run this script any time. Clean up with:
--   DELETE FROM fractal_vectorizers WHERE source_table = 'bt_bench_docs';
--   DROP TABLE bt_bench_docs, bt_bench_corpus, bt_bench_clusters;
