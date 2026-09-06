-- demo/demo-vertical-sovereign-edge-ai.sql
--
-- Industry vertical: Sovereign, Edge & Autonomous Systems AI.
--
-- FractalSQL's whole story fits this vertical natively: search,
-- reasoning, and optimization all run as pure C UDFs inside the same
-- mariadbd process -- no external vector-DB service, no cloud API call
-- required for search/optimization, and even fractal_reason() can point
-- at a fully local model (see docs/reasoning-setup.md's air-gapped
-- guidance) for environments where a network call out is unacceptable.
-- This script: a fleet of 50 edge-compute nodes, finding the best node
-- for a workload (Sniper), a diverse representative sample of the fleet
-- (Scout), and fractal_optimize_portfolio repurposed as a general
-- on-device black-box resource allocator (its own doc comment already
-- frames it as a generic cardinality-constrained optimizer, not
-- finance-specific).
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- full account):
--   - every fractal_agent_* engine is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field');`
--   - fractal_agent_schedule_workload's real signature has no id_col
--     arg -- the node table's own PRIMARY KEY is returned directly as
--     assigned_node, no ctid/row_number() remap needed anywhere here.
--   - fractal_agent_recommend_diverse's real signature has no id_col
--     arg either, same reason.
--   - fractal_agent_allocate does not expose the raw
--     fractal_optimize_portfolio primitive's seed param.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_schedule_workload,
--      fractal_agent_recommend_diverse, fractal_agent_allocate --
--      sections 0-2 need nothing else)
--   3. Reasoning configured (see docs/COOKBOOK.md) -- Sections 3 and 5's
--      presets call fractal_reason internally. Confirm before running:
--        SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation');
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-sovereign-edge-ai.sql
--
-- Safe to re-run: vse_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() here is
-- unseeded, so exact values differ run to run -- the demo's narrative
-- points are still deterministic). Section markers below are plain
-- comments, not executed statements.

-- === 0. Sanity check: extension + edition loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 50 edge-compute nodes with a 5-dim resource-capability vector:
-- [cpu_free, mem_free, gpu_avail, net_headroom, battery] each roughly
-- normalized to [-1,1] (1 = plenty of headroom).
-- ------------------------------------------------------------------
-- === 1. 50 edge-compute nodes: resource-capability vectors ===

DROP TABLE IF EXISTS vse_nodes;
-- JSON, not a distinct vector column type: MariaDB's vector storage
-- convention (see sql/install_udf.sql's "REPRESENTATION" note) is a
-- JSON-array-of-numbers string holding a fixed-width 5-dim
-- resource-capability vector, without a distinct column type for it.
-- fractal_search_telemetry/fractal_explore below already read a plain
-- JSON column transparently.
CREATE TABLE vse_nodes (id INT AUTO_INCREMENT PRIMARY KEY, node_name VARCHAR(32), capability JSON);

-- MariaDB 11.4 has no LATERAL derived tables and no generate_series().
-- A recursive CTE replaces generate_series(1,50).
INSERT INTO vse_nodes (node_name, capability)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 50
)
SELECT CONCAT('edge-node-', gs),
       JSON_ARRAY(RAND() * 2 - 1, RAND() * 2 - 1, RAND() * 2 - 1, RAND() * 2 - 1, RAND() * 2 - 1)
FROM seq;

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount over the physical facility layout: a
-- 20x20 grid of candidate rack positions with small placement jitter --
-- a spatial-complexity signal for constrained-compute monitoring, the
-- spatial sibling of DFA's own time-series complexity signal. Needs
-- enough SPACE-FILLING points for the internal box-counting estimator
-- to find >= 3 valid eps-octaves (same validity filter as
-- demo/demo-vertical-medtech-clinical.sql's vessel/nerve fixtures) -- a
-- sparse or purely random scatter (like the 50-node capability table
-- above) is too sparse for this filter, a physical grid isn't.
-- ------------------------------------------------------------------
-- === 2. fractal_dimension_boxcount: facility deployment-grid density ===
-- (dimension near 2.0 means the deployment fills the available floor
-- space; a lower number would flag a sparse or corner-clustered rollout)

-- MariaDB 11.4 has no LATERAL derived tables (confirmed live, see
-- demo-agents.sql's own note) -- a cross join of two inline JSON_TABLE
-- row/col ranges, unioned across the x/y ordinate, replaces
-- generate_series(0,19) r CROSS JOIN generate_series(0,19) c CROSS JOIN
-- LATERAL unnest(...). Same idiom demo-agents.sql's own
-- fractal_agent_network_coverage_alert section (16) already uses for
-- its 20x20 grid.
SELECT fractal_dimension_boxcount(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY id, ord SEPARATOR ','), ']') FROM (
        SELECT rr.r0 * 20 + cc.c0 AS id, 1 AS ord, rr.r0 + (RAND() - 0.5) * 0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc
        UNION ALL
        SELECT rr.r0 * 20 + cc.c0 AS id, 2 AS ord, cc.c0 + (RAND() - 0.5) * 0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc
    ) g),
    2
) AS deployment_grid_dimension;

-- ------------------------------------------------------------------
-- 3. Sniper Search: converge toward the ideal node profile for a
-- GPU-heavy inference workload (high GPU, high mem, moderate CPU).
-- fractal_search_telemetry then maps that ideal profile to a REAL node
-- to actually schedule onto.
-- ------------------------------------------------------------------
-- === 3. Sniper Search: ideal node profile for a GPU-inference workload ===

-- Blueprint (raw primitives): converge toward the ideal node profile with
-- fractal_search (the "sniper search" in the abstract [-1,1]^5 space --
-- corpus='' + k=1 runs Sniper mode with no real corpus, same as
-- demo.sql Section 2), then map that profile to a REAL node with
-- fractal_search_telemetry. doc_id in the result is already vse_nodes'
-- real `id` column (resolved internally), no remap needed. Generalized
-- below by the shipped fractal_agent_schedule_workload preset, which
-- folds both steps together and reasons.
-- SELECT fractal_search('', '[0.3, 0.6, 0.9, 0.2, 0.0]', 1, '{"iterations": 50}') AS ideal_profile;
--
-- CALL fractal_search_telemetry('vse_nodes', 'capability',
--                                '[0.3, 0.6, 0.9, 0.2, 0.0]', 3, @t);
-- SELECT n.node_name, jt.dist AS distance
--   FROM JSON_TABLE(@t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
--   JOIN vse_nodes n ON n.id = jt.doc_id
--  ORDER BY jt.dist;

-- Productized preset: the shipped engine refines the task vector
-- (fractal_search), finds the nearest node (fractal_search_telemetry),
-- and reasons. assigned_node is the real node id; confidence is
-- 1/(1+distance). No id_col arg: the node table's
-- own PRIMARY KEY is returned directly, see this file's header.
-- --- Preset: fractal_agent_schedule_workload (raw search+telemetry form preserved above) ---
CALL fractal_agent_schedule_workload(
    '[0.3, 0.6, 0.9, 0.2, 0.0]',
    'vse_nodes', 'capability', 50, 50, 5, '{}', @r);
SELECT JSON_VALUE(@r, '$.assigned_node') AS assigned_node,
       JSON_VALUE(@r, '$.confidence') AS confidence,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 4. Scout Discovery: a diverse representative sample of the fleet's
-- distinct capability profiles -- useful for capacity planning ("what
-- KINDS of nodes do we actually have") without scanning all 50 by hand.
-- ------------------------------------------------------------------
-- === 4. Scout Discovery: diverse fleet capability profiles ===
-- --- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's distinct capability-profile embeddings. fractal_explore
-- (corpus, query, params) takes the corpus inline rather than as a
-- table/column reference, so the corpus has to be assembled first,
-- same approach as demo-business-intelligence.sql's own Scout
-- Discovery section.
-- SET @corpus = (SELECT JSON_ARRAYAGG(capability) FROM vse_nodes);
-- SELECT fractal_explore(@corpus, '[0,0,0,0,0]',
--     '{"population_size": 6, "iterations": 8, "walk": 0}') AS p;

-- Productized preset: the shipped engine returns real node ids
-- (item_id) + scores (1 - cosine_distance) with session-global
-- repulsion enabled, then we restore the session (the engine leaves
-- diversify on -- the caller owns that policy) so the section-5
-- allocator below is unaffected. The blueprint's zero query is
-- query-agnostic (explore samples the space); recommend_diverse is
-- query-anchored, so anchor on the first node's own capability vector.
-- No id_col arg: the node table's own PRIMARY KEY
-- is returned directly, see this file's header.
CALL fractal_agent_recommend_diverse(
    'vse_nodes', 'capability',
    (SELECT capability FROM vse_nodes ORDER BY id LIMIT 1),
    6, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
 ORDER BY score DESC;
SELECT fractal_diversify_disable(CONNECTION_ID());

-- ------------------------------------------------------------------
-- 5. fractal_optimize_portfolio as a general on-device black-box
-- resource allocator: which 6 of these 50 nodes should a distributed
-- job land on, maximizing an "efficiency Sharpe" over expected
-- throughput (mu) vs. contention risk (cov, higher between nodes on
-- the same rack/subnet)? Cardinality-constrained, NP-hard in general --
-- exactly the ruggedness class this SFS-backed optimizer targets (see
-- that function's own doc comment).
-- ------------------------------------------------------------------
-- === 5. fractal_optimize_portfolio: pick 6-of-50 nodes for a distributed job ===

DROP TABLE IF EXISTS vse_throughput;
CREATE TABLE vse_throughput (node_id INT PRIMARY KEY, expected_throughput DOUBLE, rack INT);
-- (id - 1) DIV 10, not (id - 1) / 10: MariaDB's `/` always does
-- decimal (not integer) division; DIV is the true-integer-division
-- equivalent.
INSERT INTO vse_throughput (node_id, expected_throughput, rack)
SELECT id, 0.4 + RAND() * 0.6, (id - 1) DIV 10 FROM vse_nodes;

DROP TEMPORARY TABLE IF EXISTS vse_contention_flat;
CREATE TEMPORARY TABLE vse_contention_flat AS
SELECT a.node_id AS i, b.node_id AS j,
       CASE WHEN a.node_id = b.node_id THEN 0.05
            WHEN a.rack = b.rack THEN 0.06
            ELSE 0.005 END AS c_ij
FROM vse_throughput a
CROSS JOIN vse_throughput b;

-- Blueprint (raw primitive): the SFS cardinality-constrained Sharpe
-- maximizer over expected-throughput (mu) vs. contention risk (cov).
-- mu/cov are built with JSON_ARRAYAGG here, not the GROUP_CONCAT+CONCAT
-- string idiom Section 2 above needs -- each is already a flat scalar
-- list per row (no per-row sub-array to unnest), so JSON_ARRAYAGG's
-- native ordering is enough.
-- SELECT fractal_optimize_portfolio(
--     (SELECT JSON_ARRAYAGG(expected_throughput ORDER BY node_id) FROM vse_throughput),
--     (SELECT JSON_ARRAYAGG(c_ij ORDER BY i, j) FROM vse_contention_flat),
--     6, '{"seed": 7}'
-- ) AS allocation;

-- Productized preset: the shipped engine runs the optimizer and reasons a
-- placement rationale over its {sharpe, weights} output. (The engine does
-- not expose the raw primitive's seed param -- the allocation is still
-- real, just not seeded to 7.)
-- --- Preset: fractal_agent_allocate (raw optimizer form preserved above) ---
CALL fractal_agent_allocate(
    (SELECT JSON_ARRAYAGG(expected_throughput ORDER BY node_id) FROM vse_throughput),
    (SELECT JSON_ARRAYAGG(c_ij ORDER BY i, j) FROM vse_contention_flat),
    6,
    '{"job": "distributed-inference", "vertical": "sovereign-edge"}', @r);
-- 'allocation' is a nested JSON object ({"sharpe":...,"weights":[...]}),
-- not a scalar -- JSON_EXTRACT, not JSON_VALUE (same reasoning as
-- demo-agents.sql's Engine B note).
SELECT JSON_EXTRACT(@r, '$.allocation') AS allocation,
       JSON_VALUE(@r, '$.sharpe') AS sharpe,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 5. Reasoning: narrate the placement decision. Runs against whatever
-- endpoint this repo's FRACTALSQL_REASONING_* config points at -- a
-- fully local model on a LAN-only host demonstrates the air-gapped-
-- capable story this vertical cares about (see docs/reasoning-setup.md).
-- ------------------------------------------------------------------
-- === 6. Reasoning over the placement decision ===

-- The section-5 preset (fractal_agent_allocate) already produces this
-- placement rationale as its `rationale` output column -- it runs the
-- same fractal_reason call over the same optimizer output this
-- standalone section used to. The raw form is preserved below as the
-- blueprint it generalizes:
-- SELECT fractal_reason(
--     CONNECTION_ID(),
--     'given this cardinality-constrained node allocation (sharpe + weights per node), explain the placement decision and any risk from rack co-location',
--     JSON_OBJECT('allocation', JSON_EXTRACT(
--         fractal_optimize_portfolio(
--             (SELECT JSON_ARRAYAGG(expected_throughput ORDER BY node_id) FROM vse_throughput),
--             (SELECT JSON_ARRAYAGG(c_ij ORDER BY i, j) FROM vse_contention_flat),
--             6, '{"seed": 7}'),
--         '$'))
-- );
-- === (rationale now produced by fractal_agent_allocate above -- see its rationale column) ===

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vse_nodes, vse_throughput;
