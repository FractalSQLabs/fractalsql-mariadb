-- demo/demo-agents.sql
--
-- This demo validates the real, current sql/install_agents.sql
-- implementation:
--   - every fractal_agent_* engine is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a scalar function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field');`
--   - NO "named id column" argument anywhere (cap_id_col, node_id_col,
--     id_col, ...): every engine returns the table's own PRIMARY KEY
--     directly, so no id-column-name string argument is needed.
--   - NO position-remapping needed for cohort_doc_ids
--     (patient_deterioration_triage) or any other doc-id argument: the
--     search primitives (sql/install_udf.sql) resolve and return real
--     primary-key values directly. Pass real `id` values straight
--     through.
--   - fractal_agent_diverse_portfolios (Engine P) calls fractal_optimize_
--     portfolio_multimodal, an Enterprise-tier primitive. Section 13b
--     below probes it directly first (same dormant/active dual-path
--     pattern demo/enterprise-qtl-audit.sql uses) rather than assuming
--     an enterprise library is loaded.
-- See sql/install_agents.sql's header comment for the full account of
-- these design choices.
--
-- End-to-end validation of the sixteen installed agents (A-P), folded
-- into sql/install_agents.sql as plain stored procedures since MariaDB
-- has no extension-dependency system to hook agents into.
--
-- Agents exercised: 12 cognition agents call fractal_reason internally,
-- 3 are pure retrieval/analytics with no LLM call (fractal_dimension_
-- drift, fractal_reason, fractal_optimize_portfolio, fractal_search_
-- telemetry, fractal_hybrid_clinical_search, fractal_diversify_enable,
-- fractal_sql_agent, fractal_search_trajectory, fractal_detect_collapse,
-- fractal_dimension_boxcount, fractal_dimension_dfa,
-- fractal_morphological_complexity).
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (FRACTALSQL_REASONING_PLUGIN/HTTP_URL/
--      HTTP_MODEL/HTTP_ALLOW_PLAINTEXT in mariadbd's environment).
--      The twelve cognition agents call fractal_reason internally;
--      the 3 retrieval/analytics agents need no endpoint. Confirm
--      before running:
--        SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation');
-- Re-runnable: agents_demo_logs and the fixture tables are dropped and
-- recreated at the top of their sections.

-- 0. Prerequisite check. MariaDB has no pg_extension catalog, so check
-- the routines directly instead.
SELECT ROUTINE_NAME FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME LIKE 'fractal_agent_%'
ORDER BY ROUTINE_NAME;
-- Expect sixteen rows (fractal_agent_anomaly_triage .. fractal_agent_regime_triage,
-- plus fractal_agent_diverse_portfolios).
-- If empty: SOURCE sql/install_agents.sql; first.

-- 1. Setup: a drifting metric time series for one host.
-- Baseline ~50 for the first 48 rows then a +30 step-up, 96 points, so
-- fractal_dimension_drift's 32-point recent window has a real regime
-- change to detect. A second host makes the host filter meaningful.
DROP TABLE IF EXISTS agents_demo_logs;
CREATE TABLE agents_demo_logs (metric DOUBLE, ts TIMESTAMP, host VARCHAR(32));
INSERT INTO agents_demo_logs (metric, ts, host)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 96
)
SELECT 50.0 + MOD(gs, 8) * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       NOW() - INTERVAL (96 - gs) SECOND, 'host-1'
FROM seq;
INSERT INTO agents_demo_logs VALUES
    (10, NOW(), 'host-2'),
    (11, NOW() + INTERVAL 1 MINUTE, 'host-2');

-- 2. fractal_agent_anomaly_triage (happy path).
CALL fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32, @r);
SELECT JSON_VALUE(@r, '$.threat_score') AS threat_score,
       JSON_VALUE(@r, '$.anomaly_type') AS anomaly_type,
       JSON_VALUE(@r, '$.triage_summary') AS triage_summary;

-- 3. fractal_agent_allocate (happy path). cov is a 2x2 identity
-- flattened row-major (4-element JSON array); fractal_optimize_portfolio
-- reads it flattened, not as a 2-D matrix.
CALL fractal_agent_allocate(
    '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1, '{"portfolio": "agents-demo"}', @r);
-- 'allocation' is a nested JSON object ({"sharpe":...,"weights":[...]}),
-- not a scalar. JSON_VALUE only extracts scalars in MariaDB (returns
-- NULL for an object/array path); JSON_EXTRACT is the right tool here.
SELECT JSON_EXTRACT(@r, '$.allocation') AS allocation,
       JSON_VALUE(@r, '$.sharpe') AS sharpe,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 4. fractal_agent_route_task (happy path). No cap_id_col arg, the
-- capability table's own PRIMARY KEY is returned directly (see header).
DROP TABLE IF EXISTS agents_demo_caps;
CREATE TABLE agents_demo_caps (id INT PRIMARY KEY AUTO_INCREMENT, capability_name VARCHAR(64), emb JSON);
INSERT INTO agents_demo_caps (capability_name, emb) VALUES
    ('root-cause-analyzer', '[0.1, 0.2, 0.3]'),
    ('capacity-autoscaler', '[0.9, 0.8, 0.7]'),
    ('incident-pager',      '[0.3, 0.3, 0.9]');

CALL fractal_agent_route_task(
    '[0.11, 0.21, 0.31]', 'agents_demo_caps', 'emb', 1000, 100, @r);
SELECT JSON_VALUE(@r, '$.routed_to') AS routed_to,
       JSON_VALUE(@r, '$.confidence') AS confidence,
       JSON_VALUE(@r, '$.remaining_budget') AS remaining_budget,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 5. fractal_agent_outlier_intercept. Orthogonal vs. parallel matters --
-- cosine distance ignores magnitude. A far probe must point a
-- different direction, not just a smaller one.
DROP TABLE IF EXISTS agents_demo_badstates;
CREATE TABLE agents_demo_badstates (id INT PRIMARY KEY AUTO_INCREMENT, emb JSON);
INSERT INTO agents_demo_badstates (emb) VALUES ('[1.0, 0.0, 0.0]'), ('[0.9, 0.1, 0.0]');

CALL fractal_agent_outlier_intercept(
    '[0.95, 0.05, 0.0]', 'agents_demo_badstates', 'emb', 0.5, @r);
SELECT JSON_VALUE(@r, '$.intercepted') AS intercepted, JSON_VALUE(@r, '$.reason') AS reason;

CALL fractal_agent_outlier_intercept(
    '[0.0, 1.0, 0.0]', 'agents_demo_badstates', 'emb', 0.5, @r);
SELECT JSON_VALUE(@r, '$.intercepted') AS intercepted, JSON_VALUE(@r, '$.reason') AS reason;

-- 6. fractal_agent_recall_hybrid (happy path). Pure retrieval, no LLM.
-- No session_id-as-id-col arg, state_vector's own row (agents_demo_mem's
-- PRIMARY KEY) is returned directly.
DROP TABLE IF EXISTS agents_demo_mem;
CREATE TABLE agents_demo_mem (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    customer_id   VARCHAR(32),
    state_vector  JSON,
    content       TEXT
);
INSERT INTO agents_demo_mem (customer_id, state_vector, content) VALUES
    ('cust-a', '[0.2, 0.2, 0.2]', 'resolved churn via loyalty upgrade'),
    ('cust-a', '[0.8, 0.8, 0.8]', 'escalated billing dispute to agent'),
    ('cust-b', '[0.5, 0.5, 0.5]', 'refunded a duplicate charge');

CALL fractal_agent_recall_hybrid(
    'agents_demo_mem', 'state_vector', '[0.18, 0.22, 0.2]',
    'customer_id', 'cust-a', 2, 'content', @r);
-- Engine E is one of the two "pure-retrieval multi-row" engines --
-- @r is a JSON ARRAY of {mem_id, content} objects, not one object (see
-- this file's header and sql/install_agents.sql's own D7 note) --
-- explode via JSON_TABLE rather than JSON_VALUE/_EXTRACT on @r directly.
SELECT mem_id, content
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           mem_id  VARCHAR(32) PATH '$.mem_id',
           content TEXT        PATH '$.content')) AS jt;

-- 7. fractal_agent_recommend_diverse (happy path). Pure retrieval, no
-- LLM. Session side effect (fractal_diversify_enable), reset in the
-- cleanup section at the bottom of this file.
DROP TABLE IF EXISTS agents_demo_catalog;
CREATE TABLE agents_demo_catalog (id BIGINT PRIMARY KEY AUTO_INCREMENT, emb JSON);
INSERT INTO agents_demo_catalog (id, emb) VALUES
    (10, '[0.1, 0.0, 0.0]'), (20, '[0.0, 1.0, 0.0]'), (30, '[0.0, 0.0, 1.0]');

CALL fractal_agent_recommend_diverse(
    'agents_demo_catalog', 'emb', '[0.12, 0.01, 0.0]', 3, @r);
-- Engine F is the other "pure-retrieval multi-row" engine, same
-- JSON-array-of-objects shape as Engine E above, same JSON_TABLE fix.
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt;

-- 9. fractal_agent_data_analyst (horizontal NL->SQL->reason). Composes
-- fractal_sql_agent (auto_execute=true) then fractal_reason. Trailing
-- p_context is optional extra guidance for the reasoning step, NULL
-- is fine (same reason fractal_agent_allocate's own p_context exists,
-- see sql/install_agents.sql Engine I).
DROP TABLE IF EXISTS agents_demo_data;
CREATE TABLE agents_demo_data (id INT PRIMARY KEY, category VARCHAR(32), amount DOUBLE);
INSERT INTO agents_demo_data VALUES (1, 'hardware', 1200.00), (2, 'software', 800.50), (3, 'hardware', 450.25);

CALL fractal_agent_data_analyst(
    'total amount spent per category in agents_demo_data',
    '["agents_demo_data"]', 2, NULL, @r);
-- 'result_json' is a nested object ({"status":...,"rows":...}), not a
-- scalar, JSON_EXTRACT, not JSON_VALUE (same reasoning as 'allocation'
-- above).
SELECT JSON_VALUE(@r, '$.analysis') AS analysis,
       JSON_VALUE(@r, '$.generated_sql') AS generated_sql,
       JSON_EXTRACT(@r, '$.result_json') AS result_json;

-- 10. fractal_agent_patient_deterioration_triage (medtech). No ctid/
-- row_number remapping needed (see header), cohort_doc_ids is just
-- the cohort's real `id` values, straight from the table.
DROP TABLE IF EXISTS agents_demo_patients;
CREATE TABLE agents_demo_patients (id INT PRIMARY KEY, age INT, `condition` VARCHAR(32), vitals JSON);
INSERT INTO agents_demo_patients VALUES
    (1, 72, 'sepsis',    '[0.90, -0.80, 0.70, 0.60]'),
    (2, 64, 'sepsis',    '[0.10,  0.10, 0.10, 0.10]'),
    (3, 78, 'pneumonia', '[0.20,  0.20, 0.20, 0.20]'),
    (4, 81, 'sepsis',    '[0.85, -0.75, 0.65, 0.55]');

CALL fractal_agent_patient_deterioration_triage(
    'agents_demo_patients', 'vitals',
    '[0.9, -0.8, 0.7, 0.6]', '[0.1, 0.1, 0.1, 0.1]', '[0.95, -0.85, 0.75, 0.65]',
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']')
       FROM agents_demo_patients WHERE age > 65 AND `condition` = 'sepsis'),
    5, @r);
SELECT JSON_VALUE(@r, '$.nearest_cohort_id') AS nearest_cohort_id,
       JSON_VALUE(@r, '$.cohort_distance') AS cohort_distance,
       JSON_VALUE(@r, '$.drift_distance') AS drift_distance,
       JSON_VALUE(@r, '$.rationale') AS rationale,
       JSON_EXTRACT(@r, '$.cohort_matches') AS cohort_matches;

-- 11. fractal_agent_feedback_audit (pure analytics, NO LLM).
DROP TABLE IF EXISTS agents_demo_fcatalog, agents_demo_fwarmup;
CREATE TABLE agents_demo_fcatalog (id BIGINT PRIMARY KEY, emb JSON);
INSERT INTO agents_demo_fcatalog
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 20)
SELECT gs, JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1) FROM seq;
CREATE TABLE agents_demo_fwarmup (center JSON);
INSERT INTO agents_demo_fwarmup
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 8)
SELECT JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1) FROM seq;

CALL fractal_agent_feedback_audit(
    'agents_demo_fcatalog', 'emb', '[0.5, 0.5, 0.5]',
    'agents_demo_fwarmup', 'center', 8, 3, @r);
SELECT JSON_VALUE(@r, '$.diversity_quotient') AS diversity_quotient,
       JSON_VALUE(@r, '$.explanation') AS explanation;

-- 12. fractal_agent_schedule_workload (sovereign-edge). Trailing
-- p_context is optional extra guidance for the reasoning step (NULL ok).
DROP TABLE IF EXISTS agents_demo_nodes;
CREATE TABLE agents_demo_nodes (id INT PRIMARY KEY, capability JSON);
INSERT INTO agents_demo_nodes VALUES
    (1, '[0.9, 0.1, 0.0, 0.0, 0.0]'),
    (2, '[0.0, 0.0, 0.9, 0.1, 0.0]'),
    (3, '[0.1, 0.0, 0.0, 0.0, 0.9]');

CALL fractal_agent_schedule_workload(
    '[0.8, 0.1, 0.0, 0.0, 0.1]', 'agents_demo_nodes', 'capability', 30, 50, 5, NULL, @r);
SELECT JSON_VALUE(@r, '$.assigned_node') AS assigned_node,
       JSON_VALUE(@r, '$.confidence') AS confidence,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 13. fractal_agent_rebalance_sibling (quant-finance). cov is a
-- flattened row-major 4x4 (16-element JSON array). Trailing args are
-- (seed BIGINT, context TEXT), NOT (k, id_col) as the original draft
-- assumed; seed makes the internal fractal_optimize_portfolio run
-- reproducible across re-runs of this demo.
DROP TABLE IF EXISTS agents_demo_alloc;
CREATE TABLE agents_demo_alloc (id BIGINT PRIMARY KEY, alloc JSON);
INSERT INTO agents_demo_alloc VALUES
    (1, '[0.25, 0.25, 0.25, 0.25]'),
    (2, '[0.40, 0.30, 0.20, 0.10]'),
    (3, '[0.10, 0.20, 0.30, 0.40]');

CALL fractal_agent_rebalance_sibling(
    '[0.05, 0.10, 0.15, 0.20]',
    '[0.04, 0.0, 0.0, 0.0, 0.0, 0.09, 0.0, 0.0, 0.0, 0.0, 0.16, 0.0, 0.0, 0.0, 0.0, 0.25]',
    4, 'agents_demo_alloc', 'alloc', '[0.25, 0.25, 0.25, 0.25]', 42, NULL, @r);
-- 'weights' is a JSON array, not a scalar, so use JSON_EXTRACT (same
-- reasoning as 'allocation'/'result_json' above).
SELECT JSON_VALUE(@r, '$.sharpe') AS sharpe,
       JSON_EXTRACT(@r, '$.weights') AS weights,
       JSON_VALUE(@r, '$.nearest_alloc_id') AS nearest_alloc_id,
       JSON_VALUE(@r, '$.nearest_distance') AS nearest_distance,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 13b. fractal_agent_diverse_portfolios (Engine P). Probes fractal_
-- optimize_portfolio_multimodal directly first, the same dormant/active
-- dual-path pattern demo/enterprise-qtl-audit.sql uses: a NULL result
-- means no enterprise library is loaded. The agent procedure itself
-- SIGNALs SQLSTATE '45000' on that NULL rather than passing it through
-- as if it were real data (see sql/install_agents.sql's own comment),
-- so this probes first rather than relying on a HANDLER.
DROP PROCEDURE IF EXISTS demo_diverse_portfolios_probe;
DELIMITER $$
CREATE PROCEDURE demo_diverse_portfolios_probe()
BEGIN
    DECLARE v_probe TEXT;
    SET v_probe = fractal_optimize_portfolio_multimodal(
        '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1, 4, 0.3, 0.8, 0);
    IF v_probe IS NULL THEN
        SELECT 'fractal_agent_diverse_portfolios (Engine P): enterprise tier not loaded (fractal_optimize_portfolio_multimodal returned NULL). Set FRACTALSQL_ENTERPRISE_LIB and restart to activate. See docs/enterprise.md.' AS notice;
    ELSE
        CALL fractal_agent_diverse_portfolios(
            '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1, 4, 0.3, 0.8,
            '{"portfolio": "agents-demo-diverse"}', 'sharpe', @r);
        SELECT JSON_EXTRACT(@r, '$.optimization') AS optimization,
               JSON_VALUE(@r, '$.rationale') AS rationale;
    END IF;
END$$
DELIMITER ;
CALL demo_diverse_portfolios_probe();
DROP PROCEDURE demo_diverse_portfolios_probe;

-- 14. fractal_agent_detour_classify (fleet-logistics). Vehicle 1 has a
-- deliberate detour. Trailing arg is boxcount_dim only, no k or
-- id_col (see header).
DROP TABLE IF EXISTS agents_demo_vehicles;
CREATE TABLE agents_demo_vehicles (id INT PRIMARY KEY, baseline JSON, current_pos JSON);
-- MariaDB 11.4 doesn't support LATERAL derived tables (both comma-join
-- and JOIN LATERAL forms error), so generate baseline with 4
-- independent RAND() calls (fine: each row's 4 components don't
-- need to correlate with EACH OTHER, only baseline needs to correlate
-- with that SAME row's current_pos, which the follow-up UPDATE handles
-- via JSON_EXTRACT off the just-inserted baseline, same technique
-- this file already uses for vehicle id=1's deliberate detour below).
INSERT INTO agents_demo_vehicles (id, baseline)
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 8)
SELECT gs, JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1) FROM seq;
UPDATE agents_demo_vehicles
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline,'$[0]')+0.05, JSON_EXTRACT(baseline,'$[1]')+0.05,
        JSON_EXTRACT(baseline,'$[2]')+0.05, JSON_EXTRACT(baseline,'$[3]')+0.05);
UPDATE agents_demo_vehicles
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline,'$[0]')-0.7, JSON_EXTRACT(baseline,'$[1]')+0.6,
        JSON_EXTRACT(baseline,'$[2]')+0.5, JSON_EXTRACT(baseline,'$[3]')-0.4)
 WHERE id = 1;

CALL fractal_agent_detour_classify(
    'agents_demo_vehicles', 'current_pos',
    (SELECT baseline FROM agents_demo_vehicles WHERE id = 1),
    (SELECT current_pos FROM agents_demo_vehicles WHERE id = 1),
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t, ord), ']') FROM (
        SELECT t, ord, SUM(step) OVER (PARTITION BY ord ORDER BY t) AS cum
          FROM (
              WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 200)
              SELECT t, 1 AS ord, (RAND()-0.5)*0.3 AS step FROM seq
              UNION ALL
              SELECT t, 2 AS ord, (RAND()-0.5)*0.3 AS step FROM seq
          ) s
    ) c),
    2, @r);
SELECT JSON_VALUE(@r, '$.nearest_fleet_id') AS nearest_fleet_id,
       JSON_VALUE(@r, '$.trajectory_distance') AS trajectory_distance,
       JSON_VALUE(@r, '$.trace_complexity') AS trace_complexity,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 15. fractal_agent_track_anomaly (maritime/cybersecurity). Vessel 1
-- has a deliberate track deviation. No trailing k/id_col at all (see
-- header), the call ends right after heading_series.
DROP TABLE IF EXISTS agents_demo_tracks;
CREATE TABLE agents_demo_tracks (id INT PRIMARY KEY, baseline JSON, current_pos JSON);
-- Same LATERAL-unavailable fix as agents_demo_vehicles above.
INSERT INTO agents_demo_tracks (id, baseline)
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 8)
SELECT gs, JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1) FROM seq;
UPDATE agents_demo_tracks
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline,'$[0]')+0.04, JSON_EXTRACT(baseline,'$[1]')+0.04,
        JSON_EXTRACT(baseline,'$[2]')+0.04, JSON_EXTRACT(baseline,'$[3]')+0.04);
UPDATE agents_demo_tracks
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline,'$[0]')+0.6, JSON_EXTRACT(baseline,'$[1]')-0.5,
        JSON_EXTRACT(baseline,'$[2]')-0.9, JSON_EXTRACT(baseline,'$[3]')+0.8)
 WHERE id = 1;

CALL fractal_agent_track_anomaly(
    'agents_demo_tracks', 'current_pos',
    (SELECT baseline FROM agents_demo_tracks WHERE id = 1),
    (SELECT current_pos FROM agents_demo_tracks WHERE id = 1),
    (SELECT CONCAT('[', GROUP_CONCAT(cum ORDER BY t), ']') FROM (
        SELECT t, SUM(step) OVER (ORDER BY t) AS cum FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 120)
            SELECT t, (RAND()-0.5) * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS step FROM seq
        ) s
    ) c),
    @r);
SELECT JSON_VALUE(@r, '$.nearest_fleet_id') AS nearest_fleet_id,
       JSON_VALUE(@r, '$.trajectory_distance') AS trajectory_distance,
       JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 16. fractal_agent_network_coverage_alert (smart-cities). Needs a
-- flattened 20x20 grid (2 dims per point, 800-element array). Trailing
-- p_context is optional extra guidance for the reasoning step (NULL ok).
CALL fractal_agent_network_coverage_alert(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY id, ord), ']') FROM (
        SELECT r0*20 + c0 AS id, 1 AS ord, r0 + (RAND()-0.5)*0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc
        UNION ALL
        SELECT r0*20 + c0 AS id, 2 AS ord, c0 + (RAND()-0.5)*0.3 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc
    ) g),
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 96)
        SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*SIN(t*0.31) + (RAND()-0.5)*0.8
                       ELSE 4.0 + 3.0*SIN(t*1.4) + (RAND()-0.5)*0.4 END AS v
          FROM seq) s),
    2, 48, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.morph_dimension') AS morph_dimension,
       JSON_VALUE(@r, '$.lacunarity') AS lacunarity,
       JSON_VALUE(@r, '$.drift_detected') AS drift_detected,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 17. fractal_agent_regime_triage (general-purpose). Trailing p_context
-- is optional extra guidance for the reasoning step (NULL ok).
CALL fractal_agent_regime_triage(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 96)
        SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*SIN(t*0.31) + (RAND()-0.5)*0.8
                       ELSE 4.0 + 3.0*SIN(t*1.4) + (RAND()-0.5)*0.4 END AS v
          FROM seq) s),
    64, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.drift_detected') AS drift_detected,
       JSON_VALUE(@r, '$.recent_alpha') AS recent_alpha,
       JSON_VALUE(@r, '$.baseline_alpha') AS baseline_alpha,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- 18. Closing narrative: fractal_reason over the real computed
-- results. session_id (CONNECTION_ID()) is required and first, since
-- MariaDB is one shared process for every connection: the ctx registry
-- needs an explicit session key to tell connections apart.
SELECT fractal_reason(
    CONNECTION_ID(),
    'Synthesize a one-paragraph ops brief across the agents run above and what each implies for the on-call engineer.',
    JSON_OBJECT('source', 'demo-agents.sql',
                'engines', JSON_ARRAY(
                    'fractal_agent_anomaly_triage','fractal_agent_allocate',
                    'fractal_agent_route_task','fractal_agent_outlier_intercept',
                    'fractal_agent_recall_hybrid','fractal_agent_recommend_diverse',
                    'fractal_agent_data_analyst','fractal_agent_patient_deterioration_triage',
                    'fractal_agent_feedback_audit','fractal_agent_schedule_workload',
                    'fractal_agent_rebalance_sibling',
                    'fractal_agent_detour_classify','fractal_agent_track_anomaly',
                    'fractal_agent_network_coverage_alert','fractal_agent_regime_triage'))
);

-- Reset the session-global diversify flag the recommend_diverse and
-- feedback_audit agents enabled (feedback_audit self-disables, but
-- belt-and-suspenders).
SELECT fractal_diversify_disable(CONNECTION_ID());

-- Cleanup: drop the demo tables. The agent routines are dropped only by
-- re-running/dropping sql/install_agents.sql (see demo/README.md
-- Cleanup). Leave the tables in place to inspect the results; drop
-- them to re-run.
-- DROP TABLE agents_demo_logs, agents_demo_caps, agents_demo_badstates,
--            agents_demo_mem, agents_demo_catalog, agents_demo_data,
--            agents_demo_patients, agents_demo_fcatalog, agents_demo_fwarmup,
--            agents_demo_nodes, agents_demo_alloc, agents_demo_vehicles,
--            agents_demo_tracks;
