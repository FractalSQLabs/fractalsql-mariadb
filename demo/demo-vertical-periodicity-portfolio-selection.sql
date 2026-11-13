-- demo/demo-vertical-periodicity-portfolio-selection.sql
--
-- Industry vertical: Periodicity and selection: cycle-strength detection
-- and risk-aware portfolio choice. DOMAIN kit: Six items x 96 days of sales
-- velocity with a weekly demand cycle of differing strength.
-- `fractal_periodogram` quantifies which items are genuinely periodic;
-- `fractal_optimize_portfolio` picks the 3 items that get the scheduled
-- action (a Sharpe-style trade of margin recovered against demand
-- volatility); `fractal_agent_recommend_diverse` proposes a diverse set of
-- substitute items. On the Enterprise edition
-- `fractal_agent_diverse_portfolios` (multimodal optimization) also returns
-- structurally different schedules; on the Community edition that step
-- reports "enterprise tier not loaded".
--
--   1. fractal_periodogram: the dominant period of each item's sales
--      velocity.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 selection for the scheduled
--      action.
--   3. fractal_agent_recommend_diverse: a diverse substitute-item set.
--   4. fractal_agent_diverse_portfolios (Enterprise): structurally
--      different schedules.
--   5. A closing fractal_reason() writes the decision note.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-periodicity-portfolio-selection.sql
--
-- Safe to re-run: pps_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The multimodal step is the one expected error on the Community edition
--     (the "enterprise tier not loaded" refusal); everything else runs on
--     Community.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Six items x 96 days of sales velocity ===
DROP TABLE IF EXISTS pps_sales;
CREATE TABLE pps_sales (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO pps_sales (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p1, p2) AS (
         SELECT 'item-a', 90, 0.35, 0
         UNION ALL SELECT 'item-b', 110, 0.3, 0
         UNION ALL SELECT 'item-c', 140, 0.02, 0
         UNION ALL SELECT 'item-d', 120, 0.04, 0
         UNION ALL SELECT 'item-e', 100, 0.28, 0
         UNION ALL SELECT 'item-f', 160, 0.02, 0)
SELECT ent, g, base * (1.0 + p1 * sin(2 * pi() * g / 7.0) + 0.004 * (g % 5))
  FROM s, gs;


-- === 2. Periodicity per item (fractal_periodogram) + volatility ===
DROP TABLE IF EXISTS pps_prof;
CREATE TABLE pps_prof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, CAST(JSON_VALUE(a.pj, '$.freqs[0]') AS DOUBLE) AS freq
  FROM (SELECT ent, arr, fractal_periodogram(arr, 1) AS pj FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM pps_sales GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM pps_sales GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha, ROUND(freq, 4) AS top_freq, ROUND(1.0 / freq, 1) AS samples_per_cycle
  FROM pps_prof ORDER BY ent;


-- === 3. fractal_optimize_portfolio: pick 3 items for the scheduled action ===
SET @pps_mu  = (SELECT GROUP_CONCAT(ROUND(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM pps_prof p);
SET @pps_cov = (SELECT GROUP_CONCAT(CASE WHEN a.pid = b.pid THEN ROUND(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END
                          ORDER BY a.pid, b.pid)
                  FROM pps_prof a CROSS JOIN pps_prof b);
SET @pps_result = fractal_optimize_portfolio(@pps_mu, @pps_cov, 3, '{"seed": 42}');
DROP TABLE IF EXISTS pps_result;
CREATE TABLE pps_result (rj JSON);
INSERT INTO pps_result VALUES (@pps_result);

SELECT ROUND(JSON_VALUE(rj, '$.sharpe'), 4) AS sharpe FROM pps_result;

-- --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, ROUND(jt.w, 4) AS weight
  FROM pps_result r,
       JSON_TABLE(JSON_EXTRACT(r.rj, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN pps_prof p ON p.pid = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;


-- === 4. Diverse substitute-item set ===
DROP TABLE IF EXISTS pps_catalog;
CREATE TABLE pps_catalog (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT pps_catalog_dims CHECK (JSON_LENGTH(vec) = 3)
);
INSERT INTO pps_catalog (id, label, vec) VALUES
    (1, 'alt-b 1', '[0.1513, 0.8487, 0.2763]'),
    (2, 'alt-c 2', '[0.3026, 0.1474, 0.8776]'),
    (3, 'alt-d 3', '[0.5789, 0.5461, 0.6539]'),
    (4, 'alt-e 4', '[0.9302, 0.1448, 0.1552]'),
    (5, 'alt-f 5', '[0.1065, 0.8435, 0.2065]'),
    (6, 'alt-a 6', '[0.2578, 0.1422, 0.9328]'),
    (7, 'alt-b 7', '[0.6591, 0.5409, 0.5841]'),
    (8, 'alt-c 8', '[0.8854, 0.1396, 0.2104]'),
    (9, 'alt-d 9', '[0.1867, 0.8383, 0.2617]'),
    (10, 'alt-e 10', '[0.213, 0.137, 0.863]'),
    (11, 'alt-f 11', '[0.6143, 0.5357, 0.6393]'),
    (12, 'alt-a 12', '[0.9656, 0.1344, 0.1406]'),
    (13, 'alt-b 13', '[0.1419, 0.8331, 0.3169]'),
    (14, 'alt-c 14', '[0.2932, 0.1318, 0.9182]'),
    (15, 'alt-d 15', '[0.5695, 0.5305, 0.5695]'),
    (16, 'alt-e 16', '[0.9208, 0.1292, 0.1958]'),
    (17, 'alt-f 17', '[0.2221, 0.8279, 0.2471]'),
    (18, 'alt-a 18', '[0.2484, 0.1266, 0.9734]'),
    (19, 'alt-b 19', '[0.6497, 0.5253, 0.6247]'),
    (20, 'alt-c 20', '[0.876, 0.124, 0.126]'),
    (21, 'alt-d 21', '[0.1773, 0.8227, 0.3023]'),
    (22, 'alt-e 22', '[0.3286, 0.1214, 0.9036]'),
    (23, 'alt-f 23', '[0.6049, 0.5201, 0.6799]'),
    (24, 'alt-a 24', '[0.9562, 0.1188, 0.1812]'),
    (25, 'alt-b 25', '[0.1325, 0.8175, 0.2325]'),
    (26, 'alt-c 26', '[0.2838, 0.1162, 0.9588]'),
    (27, 'alt-d 27', '[0.6851, 0.5149, 0.6101]'),
    (28, 'alt-e 28', '[0.9114, 0.1136, 0.2364]'),
    (29, 'alt-f 29', '[0.2127, 0.8123, 0.2877]'),
    (30, 'alt-a 30', '[0.239, 0.111, 0.889]');
CALL fractal_agent_recommend_diverse('pps_catalog', 'vec', '[0.85, 0.2, 0.15]', 4, @pps_r);
DROP TABLE IF EXISTS pps_rec;
CREATE TABLE pps_rec AS
SELECT ROW_NUMBER() OVER (ORDER BY jt.score DESC, jt.item_id) AS rk, c.id AS item_id, c.label AS label,
       ROUND(jt.score, 4) AS score
  FROM JSON_TABLE(@pps_r, '$[*]' COLUMNS (item_id INT PATH '$.item_id', score DOUBLE PATH '$.score')) jt
  JOIN pps_catalog c ON c.id = jt.item_id;

SELECT rk, item_id, label, score FROM pps_rec ORDER BY rk;
SELECT fractal_diversify_disable(CONNECTION_ID());


-- === 5. Enterprise edition: structurally different schedules ===
-- --- Enterprise edition: structurally distinct candidates (reports "enterprise tier not loaded" on the Community edition) ---
CALL fractal_agent_diverse_portfolios(CONCAT('[', @pps_mu, ']'), CONCAT('[', @pps_cov, ']'), 3, 4, 0.15, 0.9,
    '{"portfolio": "markdown-schedules"}', 'sharpe', NULL, @pps_div);
SELECT JSON_EXTRACT(@pps_div, '$.optimization') AS optimization, JSON_VALUE(@pps_div, '$.rationale') AS rationale;


-- === 6. Reasoning: decision note ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line decision note: which items to act on, why they are periodic, and what to promote instead',
    JSON_OBJECT('most_periodic_item', (SELECT ent FROM pps_prof ORDER BY dfa_alpha DESC LIMIT 1), 'promoted_substitute', (SELECT label FROM pps_rec WHERE rk = 1))) AS narrative;


-- === 7. Headline check ===
SELECT CONCAT('HEADLINE kit=periodicity-portfolio-selection ', CASE WHEN (SELECT freq FROM pps_prof WHERE ent = 'item-a') > 0.13 AND (SELECT freq FROM pps_prof WHERE ent = 'item-a') < 0.16 AND (SELECT count(*) FROM pps_rec) = 4 THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE pps_sales, pps_prof, pps_result, pps_catalog, pps_rec;
