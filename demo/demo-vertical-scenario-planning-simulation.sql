-- demo/demo-vertical-scenario-planning-simulation.sql
--
-- Industry vertical: strategic scenario planning and simulation training
-- -- business continuity, logistics contingency, tabletop and training
-- exercises.  DOMAIN kit built on one installed agent,
-- fractal_agent_plan_explore (MCTS-style exploration), reused verbatim:
-- its designed job is to produce a SPREAD of distinct, non-overlapping
-- strategy trajectories from a seed state, which is exactly a scenario
-- variant set.
--
--   1. A strategy / scenario space (24 candidate scenarios placed in a
--      4-dimension option space: cost, risk, speed, resilience).
--   2. fractal_search_explore (Scout, the diversity-first search) over
--      the raw option space -- pure analytics, no model -- to pick six
--      deliberately different scenarios.
--   3. fractal_agent_plan_explore -- the shipped agent: embeds a seed
--      state description and Scout-searches the vectorized scenario
--      descriptions for diverse branches (needs an embedding endpoint
--      and the reasoning plugin).
--   4. A closing fractal_reason() summarizes the generated scenario set.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_plan_explore is a PROCEDURE with a trailing OUT
--     result JSON param: `CALL fractal_agent_plan_explore(initial_state,
--     strategy_table, vector_col, max_branches, @r)`.  The branches come
--     back as a JSON array, exploded with JSON_TABLE.
--   - fractal_search_explore is a function over a ';'-separated corpus
--     string; its result carries the final population as vectors.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Sections 1-2 need nothing else.  Section 3's vectorization and
--      Section 4's plan_explore need an EMBEDDING endpoint, and Section
--      5 the reasoning plugin -- see docs/vectorizer-setup.md and
--      docs/reasoning-setup.md.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-scenario-planning-simulation.sql
--
-- Safe to re-run: sps_* tables are dropped and recreated each time (the
-- vectorizer registry rows are removed first).
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * Scout (fractal_search_explore) is an MMR diversity search: lowering
--     mmr_lambda trades relevance to the seed for spread.  Section 2
--     maps each returned point back to its scenario row by exact
--     option-space coordinates.

DELETE FROM fractal_vectorizer_rate_window WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'sps_scenarios');
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'sps_scenarios');
DELETE FROM fractal_vectorizers WHERE source_table = 'sps_scenarios';

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. 24 candidate scenarios in four clusters of six.  Coordinates are
-- [cost, risk, speed, resilience], each in 0..1.
-- ------------------------------------------------------------------
-- === 1. Scenario space: 24 candidates in four clusters ===

DROP TABLE IF EXISTS sps_scenarios;
CREATE TABLE sps_scenarios (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    description VARCHAR(120),
    cost        DOUBLE,
    risk        DOUBLE,
    speed       DOUBLE,
    resilience  DOUBLE,
    embedding   JSON                       -- populated by the vectorizer
);

INSERT INTO sps_scenarios (description, cost, risk, speed, resilience)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 24),
     c(g, label, c0, c1, c2, c3) AS (
       SELECT g,
              CASE MOD(g, 4) WHEN 0 THEN 'dual-source suppliers with safety stock'
                             WHEN 1 THEN 'nearshore relocation of critical lines'
                             WHEN 2 THEN 'regional hub-and-spoke redistribution'
                             ELSE 'expedited air-freight surge capacity' END,
              CASE MOD(g, 4) WHEN 0 THEN 0.70 WHEN 1 THEN 0.85 WHEN 2 THEN 0.40 ELSE 0.90 END,
              CASE MOD(g, 4) WHEN 0 THEN 0.20 WHEN 1 THEN 0.35 WHEN 2 THEN 0.30 ELSE 0.55 END,
              CASE MOD(g, 4) WHEN 0 THEN 0.40 WHEN 1 THEN 0.25 WHEN 2 THEN 0.65 ELSE 0.95 END,
              CASE MOD(g, 4) WHEN 0 THEN 0.85 WHEN 1 THEN 0.80 WHEN 2 THEN 0.60 ELSE 0.35 END
         FROM gs)
SELECT CONCAT(label, ' (variant ', g, ')'),
       ROUND(c0 + 0.01 * MOD(g, 5), 3), ROUND(c1 + 0.01 * MOD(g, 3), 3),
       ROUND(c2 + 0.01 * MOD(g, 4), 3), ROUND(c3 - 0.01 * MOD(g, 5), 3)
  FROM c ORDER BY g;

SELECT COUNT(*) AS scenarios FROM sps_scenarios;

-- ------------------------------------------------------------------
-- 2. Scout over the raw option space: six deliberately different
-- scenarios around the seed "current plan" (cost 0.6, risk 0.3,
-- speed 0.5, resilience 0.7).  A low mmr_lambda favors spread.
-- ------------------------------------------------------------------
-- === 2. Scout (diversity-first): six different scenarios ===

SET @sps_scout = fractal_search_explore(
    (SELECT GROUP_CONCAT(CONCAT_WS(',', cost, risk, speed, resilience) ORDER BY id SEPARATOR ';')
       FROM sps_scenarios),
    '0.6,0.3,0.5,0.7',
    '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}');

SELECT s.id, s.description
  FROM JSON_TABLE(JSON_EXTRACT(@sps_scout, '$.population'), '$[*]' COLUMNS (
           ord FOR ORDINALITY,
           p_cost DOUBLE PATH '$[0]', p_risk DOUBLE PATH '$[1]',
           p_speed DOUBLE PATH '$[2]', p_res DOUBLE PATH '$[3]')) pt
  JOIN sps_scenarios s
    ON ABS(s.cost - pt.p_cost) < 1e-6 AND ABS(s.risk - pt.p_risk) < 1e-6
   AND ABS(s.speed - pt.p_speed) < 1e-6 AND ABS(s.resilience - pt.p_res) < 1e-6
 ORDER BY pt.ord;

-- --- coverage: scenario clusters represented in the six picks ---
SELECT COUNT(DISTINCT MOD(s.id, 4)) AS clusters_covered_of_4
  FROM JSON_TABLE(JSON_EXTRACT(@sps_scout, '$.population'), '$[*]' COLUMNS (
           p_cost DOUBLE PATH '$[0]', p_risk DOUBLE PATH '$[1]',
           p_speed DOUBLE PATH '$[2]', p_res DOUBLE PATH '$[3]')) pt
  JOIN sps_scenarios s
    ON ABS(s.cost - pt.p_cost) < 1e-6 AND ABS(s.risk - pt.p_risk) < 1e-6
   AND ABS(s.speed - pt.p_speed) < 1e-6 AND ABS(s.resilience - pt.p_res) < 1e-6;

-- ------------------------------------------------------------------
-- 3. Vectorize the scenario descriptions (your configured embedding
-- endpoint's width).  Without an endpoint the queued rows fail with a
-- clean last_error (see demo-vectorizer.sql) and the agent call below
-- reports an error instead -- the rest of the script still runs.
-- ------------------------------------------------------------------
-- === 3. Vectorize the scenario descriptions ===
CALL fractal_vectorizer_create('sps_scenarios', 'description', 'embedding', NULL, @sps_vzid);
CALL fractal_vectorizer_process_queue(100, 600);

-- ------------------------------------------------------------------
-- 4. The shipped agent: MCTS-style exploration from a seed state.
-- ------------------------------------------------------------------
-- === 4. fractal_agent_plan_explore (MCTS-style scenario branches) ===

CALL fractal_agent_plan_explore(
    'regional supply disruption with a two-week port closure',
    'sps_scenarios', 'embedding', 4, @sps_plan);
SELECT * FROM JSON_TABLE(@sps_plan, '$[*]' COLUMNS (
           branch_id        VARCHAR(32) PATH '$.branch_id',
           confidence_score DOUBLE      PATH '$.confidence_score')) AS branches;

-- ------------------------------------------------------------------
-- 5. Reasoning: a summary of the generated scenario set (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: summary of the scenario set ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line summary of how these continuity scenarios differ and when to use each',
    (SELECT GROUP_CONCAT(s.description ORDER BY pt.ord SEPARATOR '; ')
       FROM JSON_TABLE(JSON_EXTRACT(@sps_scout, '$.population'), '$[*]' COLUMNS (
                ord FOR ORDINALITY,
                p_cost DOUBLE PATH '$[0]', p_risk DOUBLE PATH '$[1]',
                p_speed DOUBLE PATH '$[2]', p_res DOUBLE PATH '$[3]')) pt
       JOIN sps_scenarios s
         ON ABS(s.cost - pt.p_cost) < 1e-6 AND ABS(s.risk - pt.p_risk) < 1e-6
        AND ABS(s.speed - pt.p_speed) < 1e-6 AND ABS(s.resilience - pt.p_res) < 1e-6)) AS summary;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE sps_scenarios;
