-- demo/demo-vertical-sensor-telemetry-allocation.sql
--
-- Industry vertical: Resource allocation: sensor telemetry regime shifts
-- and non-linear demand. AGENTIC kit: Six sites x 64 days of resource
-- demand from soil-moisture sensors. `fractal_dimension_dfa` finds the site
-- whose demand is accelerating (a non-linear trend or a failing supply
-- line) rather than merely high; `fractal_optimize_portfolio` picks which 3
-- sites get the scheduled service run with the risk matrix inflated by the
-- DFA exponent; the accelerating site is flagged for an inspection instead.
-- `fractal_agent_allocate` is the shipped one-call form of the optimizer
-- step.
--
--   1. fractal_dimension_dfa over each site's daily demand.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled service, risk =
--      variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the service-plan rationale.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-sensor-telemetry-allocation.sql
--
-- Safe to re-run: sta_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily demand served per unit of resource moved; the risk
--     matrix is demand variance x DFA exponent, so an accelerating site
--     costs more risk than a steady one of the same volume.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Six sites x 64 days of resource demand ===
DROP TABLE IF EXISTS sta_demand;
CREATE TABLE sta_demand (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO sta_demand (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 64),
     s(ent, base, p1, p2) AS (
         SELECT 'site-a', 120, 1, 0
         UNION ALL SELECT 'site-b', 95, 2, 0
         UNION ALL SELECT 'site-c', 140, 3, 0
         UNION ALL SELECT 'site-d', 110, 4, 0.45
         UNION ALL SELECT 'site-e', 160, 5, 0
         UNION ALL SELECT 'site-f', 85, 6, 0)
SELECT ent, g, base * (1.0 + 0.06 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
  FROM s, gs;


-- === 2. DFA exponent of each site ===
DROP TABLE IF EXISTS sta_prof;
CREATE TABLE sta_prof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
  FROM (SELECT ent, arr FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM sta_demand GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM sta_demand GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM sta_prof ORDER BY ent;


-- === 3. fractal_optimize_portfolio: pick 3 sites ===
SET @sta_mu  = (SELECT GROUP_CONCAT(ROUND(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM sta_prof p);
SET @sta_cov = (SELECT GROUP_CONCAT(CASE WHEN a.pid = b.pid THEN ROUND(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END
                          ORDER BY a.pid, b.pid)
                  FROM sta_prof a CROSS JOIN sta_prof b);
SET @sta_result = fractal_optimize_portfolio(@sta_mu, @sta_cov, 3, '{"seed": 42}');
DROP TABLE IF EXISTS sta_result;
CREATE TABLE sta_result (rj JSON);
INSERT INTO sta_result VALUES (@sta_result);

SELECT ROUND(JSON_VALUE(rj, '$.sharpe'), 4) AS sharpe FROM sta_result;

-- --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, ROUND(jt.w, 4) AS weight
  FROM sta_result r,
       JSON_TABLE(JSON_EXTRACT(r.rj, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN sta_prof p ON p.pid = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;
-- --- sites flagged for inspection (DFA exponent > 1.2) ---
SELECT ent, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM sta_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
-- --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
CALL fractal_agent_allocate(CONCAT('[', @sta_mu, ']'), CONCAT('[', @sta_cov, ']'), 3,
    '{"portfolio": "sensor-allocation"}', @sta_alloc);
SELECT JSON_EXTRACT(@sta_alloc, '$.allocation') AS allocation,
       JSON_VALUE(@sta_alloc, '$.sharpe')       AS sharpe,
       JSON_VALUE(@sta_alloc, '$.rationale')    AS rationale;


-- === 4. Reasoning: service-plan rationale ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line service-plan rationale: which sites get the resource this cycle and which needs an inspection',
    JSON_OBJECT('inspect_site', (SELECT ent FROM sta_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM sta_prof))) AS narrative;


-- === 5. Headline check ===
SELECT CONCAT('HEADLINE kit=sensor-telemetry-allocation ', CASE WHEN (SELECT dfa_alpha FROM sta_prof WHERE ent = 'site-d') > 1.2 AND (SELECT count(*) FROM sta_prof WHERE dfa_alpha > 1.2) = 1 THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE sta_demand, sta_prof, sta_result;
