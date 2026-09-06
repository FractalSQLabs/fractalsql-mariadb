-- demo/demo-vertical-agentic-ops-devops.sql
--
-- Agentic vertical: Ops/DevOps -- Autonomous Incident Triage & Self-Healing.
--
-- End-to-end regression test for the embed-coupled Universal Agent
-- primitives. Exercises:
--   * fractal_agent_detect_loop     -- period-2 loop detection (DFA +
--     short-period check), a pure numeric primitive with no table
--     access at all.
--   * fractal_search_agent          -- embeds a question, Scout-
--     searches a real vectorized embedding column, reasons over the
--     matched rows' content.
--   * fractal_rag_agent             -- thin wrapper around
--     fractal_search_agent returning only the answer text.
--   * fractal_dimension_drift       -- non-degenerate drifting latency
--     series (called internally by fractal_agent_anomaly_triage).
--   * fractal_vectorizer_create / fractal_vectorizer_process_queue --
--     vectorizes the incident text.
--   * fractal_agent_route_task, fractal_agent_outlier_intercept,
--     fractal_agent_anomaly_triage -- task routing, outlier
--     interception, and drift+reason threat triage compositions.
-- Re-runnable: tear down a prior run's vectorizer config + queue (the
-- config outlives the table in v1 -- there is no fractal_vectorizer_
-- drop-on-table-drop), then drop the demo tables. The unconditional
-- DELETEs are no-ops on a first run.
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- fuller account):
--   - every fractal_agent_* engine here is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r,'$.field')`.
--   - fractal_agent_route_task has NO cap_id_col argument: routed_to in
--     the result is already agent_capabilities' own real
--     `capability_name` PRIMARY KEY value, used here directly as the
--     text PK, not a surrogate int id. Its trailing args are (budget,
--     cost_per_route), an extra accounting argument.
--   - fractal_agent_detect_loop takes a JSON array of integer state
--     hashes directly (log_hashes), a pure numeric function with no
--     table argument at all.
--   - fractal_search_agent's trailing args are (pop_size, iterations,
--     OUT result): result is one JSON object
--     {"answer":..,"source_doc_ids":..,"execution_time_ms":..}, not a
--     RETURNS TABLE row. execution_time_ms is a real wall-clock
--     measurement here (SYSDATE(6) start/end).
--   - fractal_rag_agent's trailing args are (meta_filter, OUT answer):
--     meta_filter is accepted but currently UNUSED, reserved for a
--     future WHERE clause; for now the whole corpus is scanned.
--   - fractal_agent_outlier_intercept and fractal_agent_anomaly_triage
--     calls below follow their argument order/count exactly as defined
--     in sql/install_agents.sql.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_detect_loop,
--      fractal_search_agent, fractal_rag_agent, fractal_agent_
--      route_task, fractal_agent_outlier_intercept, fractal_agent_
--      anomaly_triage)
--   3. Reasoning AND embedding configured (see docs/reasoning-setup.md
--      and docs/vectorizer-setup.md) -- Sections 8-9's search_agent/
--      rag_agent calls need both; Section 7's anomaly_triage calls
--      fractal_reason internally.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-agentic-ops-devops.sql
--
-- Safe to re-run: vao_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo / setseed: the mariadb CLI has no direct
-- equivalent of psql's \timing (use `SET profiling = 1; ... SHOW
-- PROFILES;` for per-statement timing) or setseed() (RAND() is used
-- below only for a small +/- jitter on an otherwise deterministic
-- latency series, so the demo's narrative points -- the period-2 loop,
-- the t=64 latency step-up -- are still deterministic; exact jitter
-- values differ run to run, a known, flagged divergence, not a silent
-- omission).

DELETE FROM fractal_vectorizer_rate_window WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'vao_incident_logs');
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'vao_incident_logs');
DELETE FROM fractal_vectorizers WHERE source_table = 'vao_incident_logs';
DROP TABLE IF EXISTS vao_incident_logs, vao_agent_capabilities, vao_known_bad_states;

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Setup synthetic incident telemetry.
-- ------------------------------------------------------------------
-- === 1. Synthetic incident telemetry: a bot stuck in a retry loop ===

CREATE TABLE vao_incident_logs (
    id         BIGINT PRIMARY KEY,
    agent_id   VARCHAR(32),
    state_hash BIGINT,        -- period-2 loop indicator (12345 / 67890)
    latency_ms DOUBLE,        -- drifting metric -> fractal_dimension_drift
    body       TEXT,          -- human-readable event line, vectorized below
    -- JSON, not fractal_vector(768) -- MariaDB's vector storage
    -- convention (see sql/install_udf.sql's "REPRESENTATION" note): a
    -- JSON-array-of-numbers string populated by the vectorizer
    -- (nomic-embed-text), not a distinct fixed-width column type.
    embedding  JSON,
    event_ts   DATETIME,
    payload    JSON
);

-- Simulate a deployment bot stuck in an infinite retry loop: state_hash
-- toggles 12345<->67890 every cycle (a clean period-2 sequence --
-- detect_loop flags it via the short-period check even though its DFA
-- alpha is well below the 0.9 threshold). The latency_ms series is a
-- genuinely drifting (non-degenerate) signal -- a baseline ~50ms for
-- the first 64 cycles, then a +30ms step-up over the most recent 32
-- cycles (the loop degrading latency) -- so fractal_dimension_drift
-- succeeds with a 32-point recent window (DFA needs the recent window
-- large enough; window=16 would be too small). generate_series() has
-- no MariaDB equivalent -- a recursive CTE replaces it, same idiom
-- demo-agents.sql already uses.
INSERT INTO vao_incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 96
)
SELECT gs, 'bot-deploy-01',
       CASE WHEN MOD(gs, 2) = 1 THEN 12345 ELSE 67890 END,
       50.0 + MOD(gs, 8) * 1.3 + CASE WHEN gs > 64 THEN 30.0 ELSE 0.0 END,
       CASE WHEN MOD(gs, 2) = 1
            THEN CONCAT('bot-deploy-01 retrying authentication: identity service refused connection (attempt ', gs, ')')
            ELSE CONCAT('bot-deploy-01 health check completed: all subsystems nominal (cycle ', gs, ')')
       END,
       NOW() - INTERVAL (96 - gs) SECOND,
       CASE WHEN MOD(gs, 2) = 1 THEN JSON_OBJECT('event', 'retry_auth')
            ELSE JSON_OBJECT('event', 'check_health') END
FROM seq;

-- A few healthy logs from a second bot (ids 97-99, outside
-- bot-deploy-01's range).
INSERT INTO vao_incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload) VALUES
(97, 'bot-deploy-02', 11111, 42.0, 'bot-deploy-02 deployed configuration v2.3 successfully', NOW(), JSON_OBJECT('event', 'init')),
(98, 'bot-deploy-02', 22222, 45.0, 'bot-deploy-02 applied rolling update to worker pool',    NOW(), JSON_OBJECT('event', 'config')),
(99, 'bot-deploy-02', 33333, 48.0, 'bot-deploy-02 deployment finalized, rollout green',      NOW(), JSON_OBJECT('event', 'deploy'));

-- 2. Vectorize the incident body text into embeddings. The vectorizer
-- backfills the already-inserted rows into its queue, then
-- process_queue embeds them -- this is the embedding-width column the
-- embed-coupled agents (search_agent, rag_agent) need.
CALL fractal_vectorizer_create('vao_incident_logs', 'body', 'embedding', NULL, @vao_vzid);
CALL fractal_vectorizer_process_queue(100, 600);   -- processes the rows queued above

-- ------------------------------------------------------------------
-- 3. Setup capabilities map for routing. capability_name is the
-- table's own real PRIMARY KEY (a VARCHAR PK, not a surrogate int id)
-- so fractal_agent_route_task's routed_to reads the actual capability
-- name directly, no id_col argument needed.
-- ------------------------------------------------------------------
-- === 3. Agent capabilities map + known-bad-states library ===

CREATE TABLE vao_agent_capabilities (
    capability_name VARCHAR(64) PRIMARY KEY,
    embedding        JSON
);

INSERT INTO vao_agent_capabilities (capability_name, embedding) VALUES
('root-cause-analyzer', '[0.1, 0.2, 0.3]'),
('rollback-executor',   '[0.9, 0.8, 0.7]');

-- A small library of known-bad deployment states for
-- fractal_agent_outlier_intercept to screen proposed actions against.
CREATE TABLE vao_known_bad_states (
    state_id    BIGINT PRIMARY KEY,
    description VARCHAR(128),
    state_vec   JSON
);
INSERT INTO vao_known_bad_states (state_id, description, state_vec) VALUES
(1, 'auth-service unreachable, retry storm',  '[0.5, 0.5, 0.5]'),
(2, 'disk pressure cascading restarts',       '[0.9, 0.1, 0.2]');

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- === 4. Loop Detection via DFA + short-period check ===
-- The state_hash sequence is a clean 12345<->67890 period-2 toggle. Its
-- DFA scaling exponent is well below the 0.9 threshold, so the DFA path
-- alone would NOT flag it -- but the short-period check does. Result:
-- loop_detected = true.
CALL fractal_agent_detect_loop(
    (SELECT JSON_ARRAYAGG(state_hash ORDER BY event_ts) FROM vao_incident_logs WHERE agent_id = 'bot-deploy-01'),
    @r);
SELECT JSON_VALUE(@r, '$.recommendation') AS recommendation,
       JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.loop_detected') AS loop_detected;

-- === 5. Multi-Agent Routing (fractal_agent_route_task) ===
-- Real nearest-capability search over agent_capabilities.embedding.
-- routed_to is already the table's own real capability_name PK value.
CALL fractal_agent_route_task(
    '[0.15, 0.25, 0.35]',
    'vao_agent_capabilities', 'embedding',
    1000, 100,   -- budget, cost_per_route
    @r);
SELECT JSON_VALUE(@r, '$.routed_to') AS routed_to,
       JSON_VALUE(@r, '$.confidence') AS confidence,
       JSON_VALUE(@r, '$.remaining_budget') AS remaining_budget,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- === 6. Outlier Interception (fractal_agent_outlier_intercept) ===
-- Real cosine distance to the nearest known_bad_states row. This
-- state_vec matches state_id 1 exactly (distance 0), so
-- intercepted = true.
CALL fractal_agent_outlier_intercept(
    '[0.5, 0.5, 0.5]',
    'vao_known_bad_states', 'state_vec',
    0.8,
    @r);
SELECT JSON_VALUE(@r, '$.intercepted') AS intercepted,
       JSON_VALUE(@r, '$.reason') AS reason;

-- === 7. Threat Triage on the drifting latency metric (fractal_agent_anomaly_triage) ===
-- The latency_ms series is a non-degenerate step-up signal with a
-- 32-point recent window, so fractal_dimension_drift succeeds --
-- window=16 would be too small for DFA on the recent window.
CALL fractal_agent_anomaly_triage(
    'vao_incident_logs', 'latency_ms', 'event_ts', 'agent_id', 'bot-deploy-01', 32,
    @r);
SELECT JSON_VALUE(@r, '$.threat_score') AS threat_score,
       JSON_VALUE(@r, '$.anomaly_type') AS anomaly_type,
       JSON_VALUE(@r, '$.triage_summary') AS triage_summary;

-- === 8. Localized Root-Cause Synthesis via Search Agent ===
-- Embeds the query and runs a diverse Scout search over the
-- vao_incident_logs.embedding column, then reasons over the retrieved
-- context (never the raw vectors -- see sql/install_agents.sql's own
-- note on this).
CALL fractal_search_agent(
    'Why is bot-deploy-01 looping on auth?',
    'vao_incident_logs', 'embedding',
    10, 5,   -- pop_size, iterations
    @r);
SELECT JSON_VALUE(@r, '$.answer') AS answer,
       JSON_EXTRACT(@r, '$.source_doc_ids') AS source_doc_ids,
       JSON_VALUE(@r, '$.execution_time_ms') AS execution_time_ms;

-- === 9. RAG Agent: retrieve-then-reason over the incident corpus ===
-- Thin wrapper around fractal_search_agent (Section 8): same embed ->
-- scan -> Scout search -> content-refetch -> reason pipeline, fixed
-- pop_size=50/iterations=15, returning only the answer text.
-- p_meta_filter is accepted but currently unused (NULL).
CALL fractal_rag_agent(
    'What events led to the auth retry loop on bot-deploy-01?',
    'vao_incident_logs', 'embedding',
    NULL,
    @vao_answer);
SELECT @vao_answer AS answer;

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vao_incident_logs, vao_agent_capabilities, vao_known_bad_states;
