-- demo/demo-vertical-agentic-edge-swarm.sql
--
-- Industry vertical: Agentic Edge Swarms (many small autonomous agents
-- coordinating under tight memory/battery/bandwidth budgets).
--
-- Three showcases for the newest primitives in this extension, all
-- picked for the same reason: they target resource-constrained,
-- streaming, on-device workloads, which is exactly this vertical's
-- operating envelope.
--   1. fractal_vector_quantize_int8 / fractal_vector_quantize_binary:
--      compress a swarm agent's local memory of past observation
--      vectors down to 4x (int8) or 32x (binary + Hamming) their raw
--      float size -- real compression ratios for genuinely
--      bandwidth/flash-constrained edge hardware, not a synthetic
--      benchmark.
--   2. fractal_state_fingerprint + fractal_cycle_detect: SimHash
--      (Charikar 2002) fingerprinting of an agent's internal state,
--      fed into streaming Brent's-algorithm cycle detection (Brent
--      1980) -- catches an agent stuck oscillating between the same
--      few states ("cognitive wobble": a planner that keeps
--      re-deciding the same two actions back and forth instead of
--      making progress) using O(1) memory per step, not an
--      ever-growing history buffer.
--   3. fractal_optimize_subset: battery-constrained task routing --
--      which tasks should a swarm agent with limited remaining battery
--      actually accept, maximizing total task value subject to a
--      per-task battery-cost upper bound and a hard cap on how many
--      tasks run concurrently.
--
-- Structural notes:
--   - fractal_state_fingerprint(vec_csv, n_bits, seed) takes a flat
--     CSV state vector, not JSON -- matches
--     fractal_change_point_detect's series_csv convention, not the
--     fractal_vector_* family's JSON convention.
--   - fractal_cycle_detect(fingerprints_csv, n_bytes, hamming_threshold)
--     takes CONCATENATED fingerprint bytes (n_fingerprints * n_bytes
--     long) as a flat CSV -- build it by concatenating successive
--     fractal_state_fingerprint outputs in order.
--   - fractal_optimize_subset(item_values_csv, upper_bounds_csv, k,
--     params) is the generic cardinality-constrained optimizer with a
--     hardcoded value-weighted-allocation objective (maximize
--     sum(weight[i]*item_value[i])). This repo's build does not expose
--     turnover_penalty/prev_weights via SQL -- every call here runs
--     with turnover disabled (see sql/install_udf.sql's own comment).
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;   (the base UDF set -- no agent
--      layer or reasoning config needed for any section below)
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-agentic-edge-swarm.sql
--
-- Safe to re-run: ves_* tables are dropped and recreated each time.
--
-- NOTE: MariaDB has no session-wide random seed equivalent to
-- setseed(). RAND() here is unseeded, so exact jitter values differ
-- run to run -- the demo's narrative points (the wobble loop in
-- Section 2 is a fixed 2-state sequence, not randomized) are still
-- deterministic.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Compressed swarm memory: 20 past 8-dim observation vectors an
-- edge agent has stored locally, quantized both ways this extension
-- supports.
-- ------------------------------------------------------------------
-- === 1. fractal_vector_quantize_int8 / _binary: compressed observation memory ===

DROP TABLE IF EXISTS ves_observations;
CREATE TABLE ves_observations (id INT AUTO_INCREMENT PRIMARY KEY, obs JSON);

INSERT INTO ves_observations (obs)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 20
)
SELECT JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1,
                   RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM seq;

SELECT id,
       JSON_VALUE(fractal_vector_quantize_int8(obs), '$.scale') AS int8_scale,
       JSON_EXTRACT(fractal_vector_quantize_int8(obs), '$.values')  AS int8_values,
       fractal_vector_quantize_binary(obs)                          AS binary_bytes
  FROM ves_observations
 ORDER BY id
 LIMIT 5;

-- Binary-quantized candidate filtering: which stored observation is
-- Hamming-nearest to a fresh reading, without ever dequantizing back
-- to float -- the point of shipping quantize+Hamming as a pair.
SET @ves_fresh_reading = (SELECT obs FROM ves_observations WHERE id = 1);
SET @ves_fresh_bytes = fractal_vector_quantize_binary(@ves_fresh_reading);

SELECT id, fractal_vector_hamming_distance(@ves_fresh_bytes, fractal_vector_quantize_binary(obs)) AS hamming_dist
  FROM ves_observations
 ORDER BY hamming_dist
 LIMIT 5;

-- ------------------------------------------------------------------
-- 2. Cognitive wobble detection: a planner agent whose internal
-- decision state toggles between exactly two states (period-2) for 10
-- steps -- stuck re-deciding the same two actions instead of making
-- progress. Each state is a 3-dim decision-direction vector (not a
-- 1-dim scalar -- fractal_state_fingerprint's SimHash is direction/
-- cosine-based, so a 1-dim scalar only has two possible directions and
-- any same-signed sequence would collapse to one fingerprint
-- regardless of whether it's actually looping; 3 dimensions gives the
-- fingerprint real direction information to work with).
-- ------------------------------------------------------------------
-- === 2. fractal_state_fingerprint + fractal_cycle_detect: wobble detection ===

DROP TABLE IF EXISTS ves_agent_states;
CREATE TABLE ves_agent_states (step INT PRIMARY KEY, state_vec VARCHAR(64));
INSERT INTO ves_agent_states (step, state_vec) VALUES
    (1, '1.0,0.2,-0.3'), (2, '-0.8,0.9,0.1'),
    (3, '1.0,0.2,-0.3'), (4, '-0.8,0.9,0.1'),
    (5, '1.0,0.2,-0.3'), (6, '-0.8,0.9,0.1'),
    (7, '1.0,0.2,-0.3'), (8, '-0.8,0.9,0.1'),
    (9, '1.0,0.2,-0.3'), (10, '-0.8,0.9,0.1');

-- fractal_state_fingerprint returns a JSON array of bytes (e.g.
-- "[145,3]"); fractal_cycle_detect wants those bytes concatenated as a
-- flat CSV, not JSON, so each step's fingerprint is stripped of its
-- brackets and concatenated in step order.
DROP TEMPORARY TABLE IF EXISTS ves_fingerprints;
CREATE TEMPORARY TABLE ves_fingerprints AS
SELECT step,
       TRIM(BOTH ',' FROM REPLACE(REPLACE(
           fractal_state_fingerprint(state_vec, 16, 42.0), '[', ''), ']', ''))
       AS fp_csv,
       -- (16 bits -> 2 bytes per fingerprint; needed below as n_bytes)
       2 AS n_bytes
  FROM ves_agent_states
 ORDER BY step;

SET @ves_fp_stream = (SELECT GROUP_CONCAT(fp_csv ORDER BY step SEPARATOR ',') FROM ves_fingerprints);
SET @ves_loop = fractal_cycle_detect(@ves_fp_stream, 2, 0);

SELECT JSON_VALUE(@ves_loop, '$.detected')  AS is_loop_detected,
       JSON_VALUE(@ves_loop, '$.cycle_len') AS cycle_len,
       JSON_VALUE(@ves_loop, '$.at_index')  AS at_index;
-- detected=true, cycle_len=2: confirms the agent is oscillating
-- between the same two decision states rather than progressing.

-- ------------------------------------------------------------------
-- 3. Battery-constrained task routing: 15 candidate tasks this agent
-- could accept, each with a value score and a battery-cost upper
-- bound (as a fraction of the agent's remaining battery budget) --
-- pick at most 4 tasks maximizing total accepted value.
-- ------------------------------------------------------------------
-- === 3. fractal_optimize_subset: battery-constrained task acceptance ===

DROP TABLE IF EXISTS ves_tasks;
CREATE TABLE ves_tasks (task_id INT PRIMARY KEY, task_name VARCHAR(32), task_value DOUBLE, battery_cost_cap DOUBLE);
INSERT INTO ves_tasks (task_id, task_name, task_value, battery_cost_cap)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 15
)
SELECT gs, CONCAT('task-', gs), 0.2 + RAND() * 0.8, 0.1 + RAND() * 0.5
FROM seq;

SET @ves_values  = (SELECT GROUP_CONCAT(task_value ORDER BY task_id) FROM ves_tasks);
SET @ves_bounds  = (SELECT GROUP_CONCAT(battery_cost_cap ORDER BY task_id) FROM ves_tasks);
SET @ves_routing = fractal_optimize_subset(@ves_values, @ves_bounds, 4, '{"seed": 7}');

SELECT JSON_VALUE(@ves_routing, '$.score') AS total_accepted_value;
SELECT t.task_name, jt.weight AS acceptance_weight
  FROM JSON_TABLE(@ves_routing, '$.weights[*]' COLUMNS (weight DOUBLE PATH '$', ord FOR ORDINALITY)) jt
  JOIN ves_tasks t ON t.task_id = jt.ord
 WHERE jt.weight > 1e-9
 ORDER BY jt.weight DESC;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE ves_observations, ves_agent_states, ves_tasks;
