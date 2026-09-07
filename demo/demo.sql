-- demo/demo.sql
--
-- FractalSQL basic demo: Sniper/Scout search feeding LLM reasoning.
--
-- Prerequisites (see demo/README.md for the full walkthrough):
--   1. fractalsql-mariadb installed and `SOURCE sql/install_udf.sql;`
--      already run against the target database (MariaDB has no
--      CREATE EXTENSION mechanism, UDFs are registered directly).
--   2. Reasoning configured, see docs/reasoning-setup.md. This script assumes
--      the reasoning plugin + endpoint are already reachable. Any
--      OpenAI-compatible endpoint works (Ollama, Bedrock, Azure, GCP
--      Vertex, ...), this script doesn't care which.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo.sql
--
-- Safe to re-run: the demo tables are dropped and recreated each time.
-- Nothing here is destructive to anything outside the two demo_* tables.
--
-- NOTE ON \timing / \echo: the mariadb CLI has no direct equivalent of
-- psql's \timing; use `SET profiling = 1; ... SHOW PROFILES;` if you
-- want per-statement timing. Section markers below are plain comments,
-- not executed statements (unlike psql's \echo, which prints even when
-- run non-interactively). Pipe through `mariadb --comments` or just
-- read the script if you want the narration to show alongside output.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- === 1. Set up a small alerts table with something worth noticing ===
DROP TABLE IF EXISTS demo_alerts;
CREATE TABLE demo_alerts (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    service     VARCHAR(64),
    message     TEXT,
    severity    VARCHAR(16),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO demo_alerts (service, message, severity, created_at) VALUES
    ('api-gateway',  'request latency p99 245ms',              'info',     NOW() - INTERVAL 55 MINUTE),
    ('api-gateway',  'request latency p99 260ms',              'info',     NOW() - INTERVAL 50 MINUTE),
    ('payments',     'transaction processed successfully',     'info',     NOW() - INTERVAL 45 MINUTE),
    ('payments',     'transaction processed successfully',     'info',     NOW() - INTERVAL 40 MINUTE),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  NOW() - INTERVAL 30 MINUTE),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  NOW() - INTERVAL 29 MINUTE),
    ('auth-service', '17 failed login attempts, user_id=8821', 'warning',  NOW() - INTERVAL 28 MINUTE),
    ('payments',     'transaction processed successfully',     'info',     NOW() - INTERVAL 20 MINUTE),
    ('api-gateway',  'request latency p99 4200ms',              'critical', NOW() - INTERVAL 10 MINUTE),
    ('api-gateway',  'request latency p99 3900ms',              'critical', NOW() - INTERVAL  9 MINUTE);

-- === 2. Sniper Search: converge to a single best point ===
-- Vector args/results are JSON-encoded strings on this extension's UDF
-- surface (no native array type across the 10.6-12.3 compat floor, see
-- sql/install_udf.sql's own header). fractal_search takes 4 args
-- (vector_csv corpus, query_csv, k, params); corpus='' (empty string)
-- means an empty corpus, and k=1 asks for just the one converged point.
SELECT fractal_search('', '[0.6, 0.8, 0.0]', 1, '{"iterations": 50}');

-- === 3. Ask the LLM to analyze the alerts table (real context, not a bare ping) ===
-- JSON_ARRAYAGG plus an explicit JSON_OBJECT per row builds the same
-- shape jsonb_agg(row_to_json(t)) would in a JSONB-native database.
-- fractal_reason(session_id, query [, context]): session_id is
-- required so the extension can key its per-connection context
-- (CONNECTION_ID() picks it up), the same convention fractal_search's
-- own optional session_id param JSON key uses, see
-- fractalsql_session.h.
SELECT fractal_reason(
    CONNECTION_ID(),
    'summarize what happened in the last hour and flag anything that needs attention',
    (SELECT JSON_ARRAYAGG(JSON_OBJECT(
                'service', service, 'message', message,
                'severity', severity, 'created_at', created_at))
       FROM (SELECT service, message, severity, created_at
               FROM demo_alerts
              WHERE created_at > NOW() - INTERVAL 1 HOUR
              ORDER BY created_at) t)
);

-- === 4. Scout Discovery feeding reasoning: search + reason in one pipeline ===
-- generate_series() has no MariaDB equivalent, a recursive CTE (10.2+)
-- is the standard replacement.
DROP TABLE IF EXISTS demo_embeddings;
CREATE TABLE demo_embeddings (id INT AUTO_INCREMENT PRIMARY KEY, emb_arr JSON);
INSERT INTO demo_embeddings (emb_arr)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 500
)
SELECT JSON_ARRAY(RAND(), RAND(), RAND()) FROM seq;

-- Scout Mode, fractal_explore(corpus, query, params), takes the corpus
-- as an inline JSON-array-of-arrays argument rather than a table
-- reference (see sql/install_udf.sql's own comment near "Scout Mode").
-- Aggregate demo_embeddings' rows into that shape with JSON_ARRAYAGG
-- first, the same "scan into an inline corpus string" pattern
-- build_test.sh's own gates use.
SET @scout_corpus = (SELECT JSON_ARRAYAGG(emb_arr) FROM demo_embeddings);
SELECT fractal_reason(
    CONNECTION_ID(),
    'these are points from a 3D embedding space sampled by Scout Discovery, describe the spread',
    (SELECT fractal_explore(
        @scout_corpus, '[0,0,0]',
        '{"population_size": 10, "iterations": 8, "walk": 0}'
    ))
);

-- === Demo complete ===
-- Tables demo_alerts and demo_embeddings were left in place for you to
-- inspect further. Clean up with:
--   DROP TABLE demo_alerts, demo_embeddings;
