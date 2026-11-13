-- demo/demo-vertical-simulated-economy-drift.sql
--
-- Industry vertical: Simulated-economy balancing: market inflation loops
-- and automated-actor detection. AGENTIC kit: Six markets x 96 days of
-- price index; every market carries a weekly demand cycle, and one (mkt-d)
-- enters an accelerating inflation spiral. `fractal_periodogram` confirms
-- the weekly cycle, `fractal_dimension_dfa` flags the market that is
-- inflating non-linearly, and `fractal_optimize_portfolio` picks the 3
-- markets for the scheduled sink program (the inflating market goes to an
-- emergency price-cap instead). `fractal_agent_detect_loop` then watches
-- trade-state logs: an automated actor that flips between the same two item
-- states is detected while a varied actor is not.
--
--   1. fractal_periodogram: the dominant period of each market (a 7-day
--      weekly cycle is expected).
--   2. fractal_dimension_dfa: the market whose price index is accelerating.
--   3. fractal_optimize_portfolio (SFS): 3-of-6 sink program, risk =
--      variance x DFA exponent.
--   4. fractal_agent_detect_loop: SimHash + Brent cycle detection on trade-
--      state logs, automated vs varied actor.
--   5. A closing fractal_reason() writes the balance note.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-simulated-economy-drift.sql
--
-- Safe to re-run: sed_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The trade-state logs follow the edge-swarm kit's fixtures: a
--     3-component state flipping between two directions (the automated
--     actor) against an 8-component varied walk.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Six markets x 96 days of price index ===
DROP TABLE IF EXISTS sed_price;
CREATE TABLE sed_price (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO sed_price (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p1, p2) AS (
         SELECT 'mkt-a', 100, 0.12, 0
         UNION ALL SELECT 'mkt-b', 80, 0.15, 0
         UNION ALL SELECT 'mkt-c', 140, 0.1, 0
         UNION ALL SELECT 'mkt-d', 120, 0.14, 0.0024
         UNION ALL SELECT 'mkt-e', 90, 0.12, 0
         UNION ALL SELECT 'mkt-f', 200, 0.08, 0)
SELECT ent, g, base * (1.0 + p1 * sin(2 * pi() * g / 7.0) + 0.004 * (g % 5)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
  FROM s, gs;


-- === 2. Weekly cycle and non-linearity per market ===
DROP TABLE IF EXISTS sed_prof;
CREATE TABLE sed_prof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, CAST(JSON_VALUE(a.pj, '$.freqs[0]') AS DOUBLE) AS freq
  FROM (SELECT ent, arr, fractal_periodogram(arr, 1) AS pj FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM sed_price GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM sed_price GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha, ROUND(freq, 4) AS top_freq, ROUND(1.0 / freq, 1) AS samples_per_cycle
  FROM sed_prof ORDER BY ent;


-- === 3. fractal_optimize_portfolio: pick 3 markets for the sink program ===
SET @sed_mu  = (SELECT GROUP_CONCAT(ROUND(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM sed_prof p);
SET @sed_cov = (SELECT GROUP_CONCAT(CASE WHEN a.pid = b.pid THEN ROUND(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END
                          ORDER BY a.pid, b.pid)
                  FROM sed_prof a CROSS JOIN sed_prof b);
SET @sed_result = fractal_optimize_portfolio(@sed_mu, @sed_cov, 3, '{"seed": 42}');
DROP TABLE IF EXISTS sed_result;
CREATE TABLE sed_result (rj JSON);
INSERT INTO sed_result VALUES (@sed_result);

SELECT ROUND(JSON_VALUE(rj, '$.sharpe'), 4) AS sharpe FROM sed_result;

-- --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, ROUND(jt.w, 4) AS weight
  FROM sed_result r,
       JSON_TABLE(JSON_EXTRACT(r.rj, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN sed_prof p ON p.pid = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;
-- --- markets flagged for an emergency price cap (DFA exponent > 1.2) ---
SELECT ent, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM sed_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;


-- === 4. fractal_agent_detect_loop: automated actor vs varied actor ===
SET @sed_walk = (WITH RECURSIVE walk(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM walk WHERE t < 24)
    SELECT JSON_ARRAYAGG(JSON_ARRAY(
               ROUND(SIN(t * 1.41421356), 6), ROUND(SIN(t * 1.73205081), 6), ROUND(SIN(t * 2.23606798), 6),
               ROUND(SIN(t * 2.64575131), 6), ROUND(SIN(t * 3.31662479), 6), ROUND(SIN(t * 3.60555128), 6),
               ROUND(SIN(t * 3.87298335), 6), ROUND(SIN(t * 4.12310563), 6)) ORDER BY t)
      FROM walk);
SET @sed_flip = (WITH RECURSIVE walk(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM walk WHERE t < 24)
    SELECT JSON_ARRAYAGG(CASE WHEN t % 2 = 0 THEN JSON_ARRAY(1, 0, 0) ELSE JSON_ARRAY(0, 1, 0) END ORDER BY t)
      FROM walk);
CALL fractal_agent_detect_loop('varied-actor', @sed_walk, 64, 42.0, 0, @sed_l1);
CALL fractal_agent_detect_loop('auto-actor', @sed_flip, 64, 42.0, 0, @sed_l2);
DROP TABLE IF EXISTS sed_loop;
CREATE TABLE sed_loop (agent_id VARCHAR(64), is_loop INT, dfa_exponent DOUBLE);
-- JSON_VALUE renders a JSON null as the four-character STRING 'null', and
-- the automated actor's log is a period-2 cycle whose DFA exponent the
-- agent leaves null (a constant-norm series has no exponent to report).
-- NULLIF turns that string back into a real NULL before it is cast into
-- the DOUBLE column -- without it the INSERT is refused with
-- "Incorrect double value: 'null'".
INSERT INTO sed_loop VALUES
    ('varied-actor', IF(JSON_VALUE(@sed_l1, '$.loop_detected') IN ('true', '1'), 1, 0), CAST(NULLIF(JSON_VALUE(@sed_l1, '$.dfa_exponent'), 'null') AS DOUBLE)),
    ('auto-actor',    IF(JSON_VALUE(@sed_l2, '$.loop_detected') IN ('true', '1'), 1, 0), CAST(NULLIF(JSON_VALUE(@sed_l2, '$.dfa_exponent'), 'null') AS DOUBLE));

SELECT agent_id, is_loop, dfa_exponent FROM sed_loop ORDER BY agent_id;


-- === 5. Reasoning: balance note ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line balance note: the inflating market, the sink program, and the actor to block',
    JSON_OBJECT('inflating_market', (SELECT ent FROM sed_prof ORDER BY dfa_alpha DESC LIMIT 1), 'bot_loops', (SELECT count(*) FROM sed_loop WHERE is_loop = 1))) AS narrative;


-- === 6. Headline check ===
SELECT CONCAT('HEADLINE kit=simulated-economy-drift ', CASE WHEN (SELECT dfa_alpha FROM sed_prof WHERE ent = 'mkt-d') > 1.2 AND (SELECT count(*) FROM sed_prof WHERE dfa_alpha > 1.2) = 1 AND (SELECT freq FROM sed_prof WHERE ent = 'mkt-b') > 0.13 AND (SELECT freq FROM sed_prof WHERE ent = 'mkt-b') < 0.16 AND (SELECT is_loop FROM sed_loop WHERE agent_id = 'auto-actor') = 1 AND (SELECT is_loop FROM sed_loop WHERE agent_id = 'varied-actor') = 0 THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE sed_price, sed_prof, sed_result, sed_loop;
