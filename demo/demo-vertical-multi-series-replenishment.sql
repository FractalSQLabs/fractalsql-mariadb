-- demo/demo-vertical-multi-series-replenishment.sql
--
-- Industry vertical: Multi-location replenishment: stockout prevention and
-- non-linear demand forecasting. AGENTIC kit: Six locations x 64 days of
-- unit demand. `fractal_dimension_dfa` finds the location whose demand is
-- accelerating (a viral item or a local event) rather than merely high;
-- `fractal_optimize_portfolio` picks which 3 locations get the scheduled
-- replenishment from the central hub with the risk matrix inflated by the
-- DFA exponent; the surging location is flagged for an expedited pick
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step.
--
--   1. fractal_dimension_dfa over each location's daily units: non-linear
--      vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled replenishment,
--      risk = variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the redistribution rationale.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-multi-series-replenishment.sql
--
-- Safe to re-run: msr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily units per unit of stock moved; the matrix is demand
--     variance x DFA exponent.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Six locations x 64 days of unit demand ===
DROP TABLE IF EXISTS msr_units;
CREATE TABLE msr_units (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO msr_units (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 64),
     s(ent, base, p1, p2) AS (
         SELECT 'loc-a', 130, 1, 0
         UNION ALL SELECT 'loc-b', 105, 2, 0
         UNION ALL SELECT 'loc-c', 150, 3, 0
         UNION ALL SELECT 'loc-d', 115, 4, 0.4
         UNION ALL SELECT 'loc-e', 170, 5, 0
         UNION ALL SELECT 'loc-f', 90, 6, 0)
SELECT ent, g, base * (1.0 + 0.10 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
  FROM s, gs;


-- === 2. DFA exponent of each location ===
DROP TABLE IF EXISTS msr_prof;
CREATE TABLE msr_prof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
  FROM (SELECT ent, arr FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM msr_units GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM msr_units GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM msr_prof ORDER BY ent;


-- === 3. fractal_optimize_portfolio: pick 3 locations ===
SET @msr_mu  = (SELECT GROUP_CONCAT(ROUND(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM msr_prof p);
SET @msr_cov = (SELECT GROUP_CONCAT(CASE WHEN a.pid = b.pid THEN ROUND(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END
                          ORDER BY a.pid, b.pid)
                  FROM msr_prof a CROSS JOIN msr_prof b);
SET @msr_result = fractal_optimize_portfolio(@msr_mu, @msr_cov, 3, '{"seed": 42}');
DROP TABLE IF EXISTS msr_result;
CREATE TABLE msr_result (rj JSON);
INSERT INTO msr_result VALUES (@msr_result);

SELECT ROUND(JSON_VALUE(rj, '$.sharpe'), 4) AS sharpe FROM msr_result;

-- --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, ROUND(jt.w, 4) AS weight
  FROM msr_result r,
       JSON_TABLE(JSON_EXTRACT(r.rj, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN msr_prof p ON p.pid = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;
-- --- locations flagged for an expedited pick (DFA exponent > 1.2) ---
SELECT ent, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM msr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
-- --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
CALL fractal_agent_allocate(CONCAT('[', @msr_mu, ']'), CONCAT('[', @msr_cov, ']'), 3,
    '{"portfolio": "multi-location-replenishment"}', @msr_alloc);
SELECT JSON_EXTRACT(@msr_alloc, '$.allocation') AS allocation,
       JSON_VALUE(@msr_alloc, '$.sharpe')       AS sharpe,
       JSON_VALUE(@msr_alloc, '$.rationale')    AS rationale;


-- === 4. Reasoning: redistribution rationale ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line redistribution rationale: which locations get scheduled stock and which needs an expedited pick',
    JSON_OBJECT('surging_location', (SELECT ent FROM msr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM msr_prof))) AS narrative;


-- === 5. Headline check ===
SELECT CONCAT('HEADLINE kit=multi-series-replenishment ', CASE WHEN (SELECT dfa_alpha FROM msr_prof WHERE ent = 'loc-d') > 1.2 AND (SELECT count(*) FROM msr_prof WHERE dfa_alpha > 1.2) = 1 THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE msr_units, msr_prof, msr_result;
