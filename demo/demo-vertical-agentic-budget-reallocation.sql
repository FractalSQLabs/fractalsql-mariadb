-- demo/demo-vertical-agentic-budget-reallocation.sql
--
-- Industry vertical: Agentic allocation: multi-source attribution and
-- dynamic cross-channel budget reallocation. AGENTIC kit: Six channels x 64
-- days of attributed outcomes. `fractal_dimension_dfa` finds the channel
-- whose response is accelerating (a non-linear surge a plain average would
-- hide); `fractal_optimize_portfolio` picks which 3 channels receive the
-- scheduled budget increase with the risk matrix inflated by the DFA
-- exponent; the surging channel is flagged for a capped, monitored test
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step, and `fractal_agent_route_task` dispatches each journey to
-- the best-matching model under a token budget.
--
--   1. fractal_dimension_dfa over each channel's daily outcomes: non-linear
--      response vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 budget increase, risk =
--      variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. fractal_agent_route_task: each journey routed to the best-capable
--      model.
--   5. A closing fractal_reason() gives the reallocation rationale.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-agentic-budget-reallocation.sql
--
-- Safe to re-run: abr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The optimizer maximizes a Sharpe-style ratio: mu is the mean daily
--     outcomes per unit of spend, the matrix is the response risk (variance
--     x DFA exponent).
--   * Model capability vectors = [single-step, recency-weighted, mid-path-
--     heavy, cross-device].
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Six channels x 64 days of attributed outcomes ===
DROP TABLE IF EXISTS abr_outcome;
CREATE TABLE abr_outcome (
    ent VARCHAR(48),
    seq INT,
    val DOUBLE
);
INSERT INTO abr_outcome (ent, seq, val)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 64),
     s(ent, base, p1, p2) AS (
         SELECT 'channel-a', 120, 1, 0
         UNION ALL SELECT 'channel-b', 95, 2, 0
         UNION ALL SELECT 'channel-c', 140, 3, 0
         UNION ALL SELECT 'channel-d', 110, 4, 0.45
         UNION ALL SELECT 'channel-e', 160, 5, 0
         UNION ALL SELECT 'channel-f', 85, 6, 0)
SELECT ent, g, base * (1.0 + 0.06 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
  FROM s, gs;


-- === 2. DFA exponent of each channel ===
DROP TABLE IF EXISTS abr_prof;
CREATE TABLE abr_prof AS
SELECT ROW_NUMBER() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, ROUND(m.mean_v, 4) AS mean_v, ROUND(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
  FROM (SELECT ent, arr FROM (SELECT ent, CONCAT('[', GROUP_CONCAT(ROUND(val, 5) ORDER BY seq), ']') AS arr FROM abr_outcome GROUP BY ent) x) a
  JOIN (SELECT ent, AVG(val) AS mean_v, AVG(val * val) - AVG(val) * AVG(val) AS var_v
          FROM abr_outcome GROUP BY ent) m ON m.ent = a.ent
 ORDER BY a.ent;
SELECT ent, mean_v, var_v, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM abr_prof ORDER BY ent;


-- === 3. fractal_optimize_portfolio: pick 3 channels ===
SET @abr_mu  = (SELECT GROUP_CONCAT(ROUND(p.mean_v / 100.0, 4) ORDER BY p.pid) FROM abr_prof p);
SET @abr_cov = (SELECT GROUP_CONCAT(CASE WHEN a.pid = b.pid THEN ROUND(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END
                          ORDER BY a.pid, b.pid)
                  FROM abr_prof a CROSS JOIN abr_prof b);
SET @abr_result = fractal_optimize_portfolio(@abr_mu, @abr_cov, 3, '{"seed": 42}');
DROP TABLE IF EXISTS abr_result;
CREATE TABLE abr_result (rj JSON);
INSERT INTO abr_result VALUES (@abr_result);

SELECT ROUND(JSON_VALUE(rj, '$.sharpe'), 4) AS sharpe FROM abr_result;

-- --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, ROUND(jt.w, 4) AS weight
  FROM abr_result r,
       JSON_TABLE(JSON_EXTRACT(r.rj, '$.weights'), '$[*]' COLUMNS (
           ord FOR ORDINALITY, w DOUBLE PATH '$')) jt
  JOIN abr_prof p ON p.pid = jt.ord
 WHERE jt.w > 0
 ORDER BY jt.w DESC;
-- --- channels flagged from Step 1 for a capped test (DFA exponent > 1.2) ---
SELECT ent, ROUND(dfa_alpha, 3) AS dfa_alpha
  FROM abr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
-- --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
CALL fractal_agent_allocate(CONCAT('[', @abr_mu, ']'), CONCAT('[', @abr_cov, ']'), 3,
    '{"portfolio": "budget-reallocation"}', @abr_alloc);
SELECT JSON_EXTRACT(@abr_alloc, '$.allocation') AS allocation,
       JSON_VALUE(@abr_alloc, '$.sharpe')       AS sharpe,
       JSON_VALUE(@abr_alloc, '$.rationale')    AS rationale;


-- === 4. Dispatch each journey to a routing model ===
DROP TABLE IF EXISTS abr_models;
CREATE TABLE abr_models (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT abr_models_dims CHECK (JSON_LENGTH(vec) = 4)
);
INSERT INTO abr_models (id, label, vec) VALUES
    (1, 'single-step', '[0.95, 0.2, 0.1, 0.1]'),
    (2, 'time-decay', '[0.3, 0.95, 0.2, 0.15]'),
    (3, 'mid-path-weighted', '[0.2, 0.3, 0.9, 0.2]'),
    (4, 'cross-device', '[0.35, 0.4, 0.45, 0.95]');
DROP TABLE IF EXISTS abr_events;
CREATE TABLE abr_events (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT abr_events_dims CHECK (JSON_LENGTH(vec) = 4)
);
INSERT INTO abr_events (id, label, vec) VALUES
    (1, 'J1 one-step direct path', '[0.92, 0.15, 0.1, 0.1]'),
    (2, 'J2 week-long path, recent contact', '[0.3, 0.92, 0.2, 0.15]'),
    (3, 'J3 multi-channel path, mid-touch heavy', '[0.2, 0.3, 0.88, 0.2]'),
    (4, 'J4 cross-device path', '[0.35, 0.4, 0.45, 0.92]'),
    (5, 'J5 direct return visit', '[0.9, 0.25, 0.1, 0.12]');
DROP TABLE IF EXISTS abr_routed;
CREATE TABLE abr_routed (req_id INT, label VARCHAR(128), routed_to VARCHAR(128), confidence DOUBLE, remaining_budget INT);
DROP PROCEDURE IF EXISTS abr_routed_all;
DELIMITER $$
CREATE PROCEDURE abr_routed_all()
BEGIN
    DECLARE v_id INT; DECLARE v_label VARCHAR(128); DECLARE v_vec JSON; DECLARE v_done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT id, label, vec FROM abr_events ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    OPEN cur;
    loop_r: LOOP
        FETCH cur INTO v_id, v_label, v_vec;
        IF v_done = 1 THEN LEAVE loop_r; END IF;
        CALL fractal_agent_route_task(v_vec, 'abr_models', 'vec', 1000, 150, @abr_routed_rt);
        INSERT INTO abr_routed
        SELECT v_id, v_label, n.label, JSON_VALUE(@abr_routed_rt, '$.confidence'),
               JSON_VALUE(@abr_routed_rt, '$.remaining_budget')
          FROM abr_models n WHERE n.id = JSON_VALUE(@abr_routed_rt, '$.routed_to');
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL abr_routed_all();
DROP PROCEDURE abr_routed_all;

SELECT req_id, label, routed_to, ROUND(confidence, 4) AS confidence, remaining_budget FROM abr_routed ORDER BY req_id;


-- === 5. Reasoning: reallocation rationale ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line rationale for this cross-channel budget reallocation and the capped test on the surging channel',
    JSON_OBJECT('surging_channel', (SELECT ent FROM abr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM abr_prof), 'journeys_routed', (SELECT count(*) FROM abr_routed))) AS narrative;


-- === 6. Headline check ===
SELECT CONCAT('HEADLINE kit=agentic-budget-reallocation ', CASE WHEN (SELECT dfa_alpha FROM abr_prof WHERE ent = 'channel-d') > 1.2 AND (SELECT count(*) FROM abr_prof WHERE dfa_alpha > 1.2) = 1 AND (SELECT count(*) FROM abr_routed) = 5 AND (SELECT routed_to FROM abr_routed WHERE req_id = 1) = 'single-step' AND (SELECT routed_to FROM abr_routed WHERE req_id = 4) = 'cross-device' THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed;
