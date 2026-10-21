-- demo/demo-vertical-critical-inventory-routing.sql
--
-- Industry vertical: critical-consumables inventory and replenishment
-- across a distributed depot network (medical / cold-chain stock, retail
-- high-turnover SKUs, industrial spare-parts consumables).  AGENTIC kit:
-- a hand-composed chain, then the shipped agent doing the allocation
-- step in one call.
--
--   1. fractal_dimension_dfa over each depot's daily-consumption series
--      -- identifies depots whose demand is NON-LINEAR (bursty, runaway)
--      rather than merely high.
--   2. fractal_optimize_portfolio (SFS) -- chooses which depots get the
--      scheduled replenishment run under a cardinality constraint, with
--      the risk matrix inflated for the bursty depots.  Bursty depots
--      fall out of the risk-adjusted run and are flagged from Step 1 for
--      expedited restock instead.
--   3. A closing fractal_reason() gives the rebalancing rationale.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_allocate is a PROCEDURE with a trailing OUT result
--     JSON param: `CALL fractal_agent_allocate(mu, cov, k, context, @r)`.
--   - fractal_optimize_portfolio takes (mu, cov, k, params_json); the
--     returned weights array is in input order and is exploded with
--     JSON_TABLE ... FOR ORDINALITY.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent and Section 4 call fractal_reason.  Sections 1-3's hand-
--      composed steps need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-critical-inventory-routing.sql
--
-- Safe to re-run: cir_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * The optimizer maximizes a Sharpe-style ratio: mu is the expected
--     need served per unit of stock moved, the matrix is the demand risk.
--     Here risk_i = demand variance x DFA exponent, so a depot whose
--     demand is accelerating costs more risk than a steady one of the
--     same volume.
--   * fractal_agent_allocate is the shipped composition of the optimizer
--     plus a reasoned rationale; a purpose-built productized form of this
--     whole recipe is a separate roadmap item, so this kit composes the
--     steps by hand exactly as the other agentic kits do before their
--     agent function lands.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Six regional depots, 64 days of consumption each.  D1-D3 and D5-D6
-- are steady (a weekly cycle on a base level).  D4 starts accelerating
-- on day 41 -- the non-linear spike a plain average would hide.
-- ------------------------------------------------------------------
-- === 1. Six depots x 64 days of consumption ===

DROP TABLE IF EXISTS cir_depots;
CREATE TABLE cir_depots (
    id     INT AUTO_INCREMENT PRIMARY KEY,
    region VARCHAR(16),
    base   DOUBLE
);
INSERT INTO cir_depots (region, base) VALUES
    ('north', 120), ('south', 95), ('east', 140),
    ('west', 110), ('central', 160), ('coastal', 85);

DROP TABLE IF EXISTS cir_consumption;
CREATE TABLE cir_consumption (
    depot_id INT,
    day      INT,
    units    DOUBLE
);
INSERT INTO cir_consumption (depot_id, day, units)
WITH RECURSIVE gs(d) AS (SELECT 1 UNION ALL SELECT d + 1 FROM gs WHERE d < 64)
SELECT p.id, gs.d,
       p.base * (1.0 + 0.06 * MOD(gs.d + p.id, 7) / 7.0)
         + CASE WHEN p.id = 4 AND gs.d > 40
                THEN 0.45 * (gs.d - 40) * (gs.d - 40) ELSE 0 END
  FROM cir_depots p, gs;

-- ------------------------------------------------------------------
-- 2. Step 1: DFA exponent, mean and variance per depot.  D4's exponent
-- stands well above the steady depots even though its average moves
-- less than D5's raw volume.
-- ------------------------------------------------------------------
-- === 2. Step 1: DFA exponent of each depot's consumption ===

DROP TABLE IF EXISTS cir_profile;
CREATE TABLE cir_profile AS
SELECT d.id AS depot_id, d.region,
       ROUND(AVG(c.units), 2) AS mean_units,
       ROUND(AVG(c.units * c.units) - AVG(c.units) * AVG(c.units), 2) AS var_units,
       fractal_dimension_dfa(
           CONCAT('[', GROUP_CONCAT(ROUND(c.units, 3) ORDER BY c.day), ']')) AS dfa_alpha
  FROM cir_depots d JOIN cir_consumption c ON c.depot_id = d.id
 GROUP BY d.id, d.region
 ORDER BY d.id;

SELECT depot_id, region, mean_units, var_units, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM cir_profile ORDER BY depot_id;

-- ------------------------------------------------------------------
-- 3. Step 2: scheduled replenishment for 3 of the 6 depots.
-- mu_i  = mean daily consumption (need served per unit moved);
-- cov   = diagonal risk matrix, var_i x alpha_i (demand variance
--         inflated by how non-linear the depot's demand is), flat
--         row-major as the optimizer expects.
-- ------------------------------------------------------------------
-- === 3. Step 2: fractal_optimize_portfolio -- pick 3 depots ===

SET @cir_mu  = (SELECT GROUP_CONCAT(ROUND(mean_units / 100.0, 4) ORDER BY depot_id) FROM cir_profile);
SET @cir_cov = (SELECT GROUP_CONCAT(
                          CASE WHEN a.depot_id = b.depot_id
                               THEN ROUND(a.var_units * a.dfa_alpha / 100.0, 4) ELSE 0 END
                          ORDER BY a.depot_id, b.depot_id)
                  FROM cir_profile a CROSS JOIN cir_profile b);
SET @cir_result = fractal_optimize_portfolio(@cir_mu, @cir_cov, 3, '{"seed": 42}');

SELECT ROUND(JSON_VALUE(@cir_result, '$.sharpe'), 4) AS sharpe;

-- --- the chosen depots (weight > 0; weights are in depot_id order) ---
SELECT p.depot_id, p.region, ROUND(jt.w, 4) AS weight
  FROM JSON_TABLE(JSON_EXTRACT(@cir_result, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN cir_profile p ON p.depot_id = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;

-- --- depots flagged from Step 1 for expedited restock (DFA exponent > 1.2) ---
SELECT depot_id, region, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM cir_profile WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;

-- --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
CALL fractal_agent_allocate(
    CONCAT('[', @cir_mu, ']'), CONCAT('[', @cir_cov, ']'), 3,
    '{"portfolio": "critical-inventory-routing"}', @r);
SELECT JSON_EXTRACT(@r, '$.allocation') AS allocation,
       JSON_VALUE(@r, '$.sharpe')       AS sharpe,
       JSON_VALUE(@r, '$.rationale')    AS rationale;

-- ------------------------------------------------------------------
-- 4. Reasoning: the rebalancing rationale (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 4. Reasoning: rebalancing rationale ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line rationale for this critical-inventory replenishment plan',
    JSON_OBJECT(
        'dfa_by_depot', (SELECT JSON_OBJECTAGG(region, ROUND(dfa_alpha, 3)) FROM cir_profile),
        'allocation', JSON_EXTRACT(@cir_result, '$'))) AS rationale;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE cir_depots, cir_consumption, cir_profile;
