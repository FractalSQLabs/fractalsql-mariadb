-- demo/demo-vertical-telecom-traffic-routing.sql
--
-- Industry vertical: telecom -- dynamic traffic and bandwidth dispatch to
-- the best-capable network node under a capacity budget.  DOMAIN kit
-- built on one installed agent, fractal_agent_route_task, reused
-- verbatim: it matches each incoming request to the best-capable node
-- under a token budget, exactly its designed contract.
--
-- Scope note: this is nearest-capable-node dispatch, not multi-hop
-- rerouting around a failed node (graph routing is a different problem).
-- Load awareness comes from routing over a table of only the nodes that
-- still have headroom.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - fractal_agent_route_task is a PROCEDURE with a trailing OUT result
--     JSON param and no id-column argument: `routed_to` is the node
--     table's own PRIMARY KEY, joined here to the node name.  Its
--     signature is (task_emb, cap_table, cap_emb_col, budget,
--     cost_per_route, OUT p_result).
--   - Dispatching five requests is a loop, so the kit defines a small
--     helper procedure (ttr_route_all) that runs the agent once per
--     request against whichever table it is given.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- the shipped
--      agent returns a reasoned rationale and Section 5 calls
--      fractal_reason.  The hand-composed routing needs no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-telecom-traffic-routing.sql
--
-- Safe to re-run: ttr_* tables and the helper procedure are dropped and
-- recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * Vectors are [bandwidth, latency_sensitivity, loss_tolerance,
--     region_affinity] as JSON arrays.  A request vector says what the
--     session needs; a node vector says what the node is good at.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Network nodes (capability vector + current load) and five
-- incoming session requests.
-- ------------------------------------------------------------------
-- === 1. Nodes and incoming requests ===

DROP TABLE IF EXISTS ttr_nodes;
CREATE TABLE ttr_nodes (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    node     VARCHAR(32),
    capacity INT,        -- sessions
    node_load INT,       -- sessions now
    caps     JSON,
    CONSTRAINT ttr_caps_dims CHECK (JSON_LENGTH(caps) = 4)
);
INSERT INTO ttr_nodes (node, capacity, node_load, caps) VALUES
    ('edge-core-east',   400, 120, '[0.95, 0.20, 0.10, 0.90]'),   -- bulk bandwidth, east region
    ('edge-lowlat-west', 150,  60, '[0.30, 0.95, 0.15, 0.10]'),   -- low latency, west region
    ('edge-mobile-hub',  250, 200, '[0.50, 0.50, 0.85, 0.50]'),   -- loss-tolerant mobile traffic
    ('edge-backup-west', 200,  20, '[0.55, 0.55, 0.40, 0.15]');   -- general purpose, west

DROP TABLE IF EXISTS ttr_requests;
CREATE TABLE ttr_requests (
    id    INT AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(48),
    need  JSON,
    CONSTRAINT ttr_need_dims CHECK (JSON_LENGTH(need) = 4)
);
INSERT INTO ttr_requests (label, need) VALUES
    ('R1 bulk video backhaul, east',     '[0.90, 0.15, 0.10, 0.85]'),
    ('R2 cloud-gaming session, west',    '[0.35, 0.92, 0.12, 0.12]'),
    ('R3 mobile handover burst',         '[0.45, 0.50, 0.88, 0.45]'),
    ('R4 enterprise VPN, west',          '[0.50, 0.60, 0.30, 0.12]'),
    ('R5 software update fan-out, east', '[0.92, 0.10, 0.20, 0.88]');

SELECT node, capacity, node_load, ROUND(100.0 * node_load / capacity) AS pct_loaded FROM ttr_nodes;

-- ------------------------------------------------------------------
-- 2. Hand-composed dispatch: nearest node by capability, per request.
-- confidence = 1/(1+distance).  One fractal_search_telemetry CALL per
-- request, collected by a helper procedure.
-- ------------------------------------------------------------------
-- === 2. Hand-composed dispatch: nearest capable node per request ===

DROP PROCEDURE IF EXISTS ttr_nearest_all;
DROP PROCEDURE IF EXISTS ttr_route_all;
DELIMITER $$
CREATE PROCEDURE ttr_nearest_all()
BEGIN
    DECLARE v_id INT; DECLARE v_label VARCHAR(48); DECLARE v_need JSON; DECLARE v_done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT id, label, need FROM ttr_requests ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DROP TEMPORARY TABLE IF EXISTS ttr_nearest;
    CREATE TEMPORARY TABLE ttr_nearest (label VARCHAR(48), routed_to VARCHAR(32), confidence DOUBLE);
    OPEN cur;
    loop_rq: LOOP
        FETCH cur INTO v_id, v_label, v_need;
        IF v_done = 1 THEN LEAVE loop_rq; END IF;
        CALL fractal_search_telemetry('ttr_nodes', 'caps', v_need, 1, @ttr_nn);
        INSERT INTO ttr_nearest
        SELECT v_label, n.node, ROUND(1.0 / (1.0 + jt.dist), 4)
          FROM JSON_TABLE(@ttr_nn, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
          JOIN ttr_nodes n ON n.id = jt.doc_id;
    END LOOP;
    CLOSE cur;
END$$

-- Runs the shipped route_task agent once per request against p_table and
-- collects routed_to (resolved to the node name), confidence, remaining
-- budget and the rationale.  p_table must hold (id, node, caps) rows.
CREATE PROCEDURE ttr_route_all(IN p_table VARCHAR(64))
BEGIN
    DECLARE v_id INT; DECLARE v_label VARCHAR(48); DECLARE v_need JSON; DECLARE v_done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT id, label, need FROM ttr_requests ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DROP TEMPORARY TABLE IF EXISTS ttr_routed;
    CREATE TEMPORARY TABLE ttr_routed (label VARCHAR(48), routed_to VARCHAR(32),
                                       confidence DOUBLE, remaining_budget INT, rationale TEXT);
    OPEN cur;
    loop_rq: LOOP
        FETCH cur INTO v_id, v_label, v_need;
        IF v_done = 1 THEN LEAVE loop_rq; END IF;
        CALL fractal_agent_route_task(v_need, p_table, 'caps', 1000, 150, @ttr_rt);
        INSERT INTO ttr_routed
        SELECT v_label, n.node, JSON_VALUE(@ttr_rt, '$.confidence'),
               JSON_VALUE(@ttr_rt, '$.remaining_budget'), JSON_VALUE(@ttr_rt, '$.rationale')
          FROM ttr_nodes n WHERE n.id = JSON_VALUE(@ttr_rt, '$.routed_to');
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;

CALL ttr_nearest_all();
SELECT label, routed_to, confidence FROM ttr_nearest;

-- ------------------------------------------------------------------
-- 3. The shipped agent, one call per request, under a 1000-token budget
-- (reasoning plugin for the rationale).  remaining_budget shows each
-- routing decision's cost.
-- ------------------------------------------------------------------
-- === 3. fractal_agent_route_task (budget 1000) ===

CALL ttr_route_all('ttr_nodes');
SELECT label, routed_to, confidence, remaining_budget, rationale FROM ttr_routed;

-- ------------------------------------------------------------------
-- 4. Load awareness: edge-mobile-hub is at 80% load.  Route over only
-- the nodes with headroom (below 75% loaded) and R3 is re-homed.
-- ------------------------------------------------------------------
-- === 4. Route over nodes with headroom (< 75% loaded) ===

DROP TABLE IF EXISTS ttr_available;
CREATE TABLE ttr_available (id INT PRIMARY KEY, node VARCHAR(32), caps JSON);   -- the agents need a single-column PK
INSERT INTO ttr_available (id, node, caps)
SELECT id, node, caps FROM ttr_nodes WHERE 100.0 * node_load / capacity < 75 ORDER BY id;

CALL ttr_route_all('ttr_available');
SELECT label, routed_to FROM ttr_routed;

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch summary (needs the reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: dispatch summary ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line summary of how these session requests were dispatched and why one was re-homed',
    (SELECT GROUP_CONCAT(CONCAT(label, ' -> ', routed_to) SEPARATOR '; ') FROM ttr_routed)) AS summary;

DROP PROCEDURE ttr_nearest_all;
DROP PROCEDURE ttr_route_all;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE ttr_nodes, ttr_requests, ttr_available;
-- (the ttr_nearest / ttr_routed TEMPORARY tables evaporate with the connection.)
