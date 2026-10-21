-- demo/demo-vertical-climatech-grid-balancing.sql
--
-- Industry vertical: Climate Tech -- renewable and storage generation
-- balancing on a distribution grid.  AGENTIC kit: a hand-composed chain,
-- then the shipped agents doing each step in one call.
--
--   1. fractal_dimension_dfa / _drift over grid-frequency telemetry --
--      detects a stability regime change (the same recipe the quant-
--      finance kit uses for volatility regimes, applied to a grid).
--   2. fractal_optimize_portfolio (SFS) -- reallocates generation and
--      storage dispatch across nodes under a cardinality constraint,
--      using a ramp-risk matrix in which correlated renewables carry
--      shared weather risk.
--   3. A closing fractal_reason() gives the dispatch-plan rationale.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_anomaly_triage and fractal_agent_allocate are
--     PROCEDUREs with a trailing OUT result JSON param.
--   - fractal_optimize_portfolio takes (mu, cov, k, params_json); the
--     returned weights array is in input order and is exploded with
--     JSON_TABLE ... FOR ORDINALITY.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agents and Section 4 call fractal_reason.  Sections 1-3's hand-
--      composed steps need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-climatech-grid-balancing.sql
--
-- Safe to re-run: cgb_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * The drift window is 32 points, so each area needs >= 48 readings.
--     The instability is an ACCELERATING oscillation envelope, not a
--     level shift: DFA removes a constant offset, so only a change in the
--     series' dynamics moves the exponent.
--   * The optimizer maximizes a Sharpe-style ratio: mu is dispatch value
--     per unit of capacity moved, the matrix is ramp risk.  Two variable
--     renewables (solar, wind) share weather risk (correlation 0.6);
--     batteries and hydro are nearly independent.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Grid-frequency telemetry for three balancing areas, 96 samples
-- each (deviation from nominal, mHz).  AREA-C loses damping from sample
-- 65: its oscillation envelope grows quadratically.
-- ------------------------------------------------------------------
-- === 1. Grid-frequency deviation: 3 areas x 96 samples ===

DROP TABLE IF EXISTS cgb_freq;
CREATE TABLE cgb_freq (
    area    VARCHAR(16),
    sample  INT,
    dev_mhz DOUBLE
);
INSERT INTO cgb_freq (area, sample, dev_mhz)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     a(area) AS (SELECT 'AREA-A' UNION ALL SELECT 'AREA-B' UNION ALL SELECT 'AREA-C')
SELECT area, g,
       4.0 + MOD(g, 8) * 0.8
         + CASE WHEN area = 'AREA-C' AND g > 64
                THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END
  FROM a, gs;

SELECT area, COUNT(*) AS samples, ROUND(MAX(dev_mhz), 2) AS peak_dev_mhz
  FROM cgb_freq GROUP BY area ORDER BY area;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: stability-regime drift per area.
-- ------------------------------------------------------------------
-- === 2. Step 1 (hand-composed): frequency-stability drift per area ===

SELECT area,
       ROUND(JSON_VALUE(d, '$.drift'), 4)          AS drift,
       ROUND(JSON_VALUE(d, '$.recent_alpha'), 4)   AS recent_alpha,
       ROUND(JSON_VALUE(d, '$.baseline_alpha'), 4) AS baseline_alpha
  FROM (SELECT area,
               fractal_dimension_drift(
                   CONCAT('[', GROUP_CONCAT(ROUND(dev_mhz, 4) ORDER BY sample), ']'), 32) AS d
          FROM cgb_freq GROUP BY area) x
 ORDER BY area;

-- --- the shipped agent: same composition, one call (reasoning plugin) ---
CALL fractal_agent_anomaly_triage('cgb_freq', 'dev_mhz', 'sample', 'area', 'AREA-C', 32, @r);
SELECT JSON_VALUE(@r, '$.threat_score')   AS threat_score,
       JSON_VALUE(@r, '$.anomaly_type')   AS anomaly_type,
       JSON_VALUE(@r, '$.triage_summary') AS stability_triage;

-- ------------------------------------------------------------------
-- 3. Step 2: the dispatch set.  Six resources; pick the 4 that carry
-- the AREA-C instability response with the best risk-adjusted value.
-- ------------------------------------------------------------------
-- === 3. Step 2: fractal_optimize_portfolio -- pick 4 of 6 resources ===

DROP TABLE IF EXISTS cgb_resources;
CREATE TABLE cgb_resources (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    name      VARCHAR(32),
    class     VARCHAR(16),
    value_mu  DOUBLE,      -- dispatch value per unit of capacity moved
    ramp_risk DOUBLE       -- ramp-rate risk, MW/min scaled
);
INSERT INTO cgb_resources (name, class, value_mu, ramp_risk) VALUES
    ('solar-farm-north',  'variable', 0.090, 0.30),
    ('wind-park-ridge',   'variable', 0.100, 0.35),
    ('battery-4h-east',   'storage',  0.070, 0.08),
    ('battery-2h-west',   'storage',  0.060, 0.07),
    ('pumped-hydro',      'dispatch', 0.080, 0.10),
    ('gas-peaker',        'dispatch', 0.110, 0.20);

-- Flat row-major risk matrix: ramp_i * ramp_j * rho, with rho = 1 on the
-- diagonal, 0.6 between two variable renewables, 0.1 otherwise.
SET @cgb_mu  = (SELECT GROUP_CONCAT(value_mu ORDER BY id) FROM cgb_resources);
SET @cgb_cov = (SELECT GROUP_CONCAT(ROUND(a.ramp_risk * b.ramp_risk *
                          CASE WHEN a.id = b.id THEN 1.0
                               WHEN a.class = 'variable' AND b.class = 'variable' THEN 0.6
                               ELSE 0.1 END, 6) ORDER BY a.id, b.id)
                  FROM cgb_resources a CROSS JOIN cgb_resources b);
SET @cgb_result = fractal_optimize_portfolio(@cgb_mu, @cgb_cov, 4, '{"seed": 42}');

SELECT ROUND(JSON_VALUE(@cgb_result, '$.sharpe'), 4) AS sharpe;

-- --- the dispatch set (weight > 0; weights are in resource id order) ---
SELECT r.name, r.class, ROUND(jt.w, 4) AS dispatch_weight
  FROM JSON_TABLE(JSON_EXTRACT(@cgb_result, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN cgb_resources r ON r.id = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;

-- --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
CALL fractal_agent_allocate(
    CONCAT('[', @cgb_mu, ']'), CONCAT('[', @cgb_cov, ']'), 4,
    '{"portfolio": "grid-dispatch"}', @r2);
SELECT JSON_EXTRACT(@r2, '$.allocation') AS dispatch_plan,
       JSON_VALUE(@r2, '$.sharpe')       AS sharpe,
       JSON_VALUE(@r2, '$.rationale')    AS rationale;

-- ------------------------------------------------------------------
-- 4. Reasoning: the dispatch-plan rationale (needs the reasoning
-- plugin).
-- ------------------------------------------------------------------
-- === 4. Reasoning: dispatch-plan rationale ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line rationale for this grid dispatch plan given the frequency-stability drift in AREA-C',
    JSON_OBJECT(
        'area_c_drift', JSON_COMPACT(fractal_dimension_drift(
            (SELECT CONCAT('[', GROUP_CONCAT(ROUND(dev_mhz, 4) ORDER BY sample), ']')
               FROM cgb_freq WHERE area = 'AREA-C'), 32)),
        'dispatch', JSON_EXTRACT(@cgb_result, '$'))) AS rationale;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE cgb_freq, cgb_resources;
