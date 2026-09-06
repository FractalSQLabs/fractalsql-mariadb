-- demo/demo-vertical-agentic-customer-support.sql
--
-- Agentic vertical: Customer Support -- Stateful Session & Churn Drift.
--
-- End-to-end regression test for the trajectory-forecast Universal Agent
-- primitives in sql/install_agents.sql. Exercises:
--   * fractal_agent_trajectory_predict  -- reads the baseline vector (by
--     PK = baseline_id) and the latest vector (max PK) from a table,
--     derives dim from the data, computes a real delta via
--     fractal_search_trajectory, and returns a real predicted_state_
--     vector plus projected_drift_delta.
--   * fractal_explore                   -- pure-C Scout search on an
--     inline corpus.
--   * fractal_agent_recall_hybrid       -- hybrid memory recall over a
--     churn-recovery playbook.
--   * fractal_agent_recommend_diverse   -- repulsion-guided diverse
--     retention-offer recommendations.
--   * fractal_diversify_enable / fractal_diversify_disable
-- Re-runnable (DROP at the top of each section).
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- fuller account):
--   - fractal_agent_trajectory_predict is a PROCEDURE with a trailing
--     OUT p_result JSON param, not a RETURNS TABLE function, invoked as
--     `CALL fractal_agent_trajectory_predict(table, vec_col, baseline_id,
--     forecast_steps, risk_threshold, @r); SELECT JSON_VALUE(@r, ...)`.
--     Its signature takes an explicit risk_threshold argument; passing
--     NULL here applies the fixed default of 0.5. forecast_steps is
--     accepted for signature completeness only; it is read but never
--     used in the computation (see sql/install_agents.sql's own comment
--     on this).
--   - fractal_agent_recall_hybrid's trailing args are (filter_col,
--     filter_val, k, content_col). There is no cohort-remap step
--     anywhere here: NULL/NULL for filter_col/filter_val means "no
--     cohort filter, search the whole table" (this demo's own "no
--     cohort filter: search the whole playbook" comment, preserved
--     verbatim below), and mem_id in the result is already
--     customer_playbook's own real `case_id` PRIMARY KEY value, not a
--     corpus-position index.
--   - fractal_explore(corpus, query, params) takes the corpus inline
--     (a JSON array) rather than as a table/column reference, the same
--     approach demo-business-intelligence.sql Section 6 and
--     demo-vertical-cybersecurity-threat-detection.sql Section 2 use.
--   - fractal_agent_recommend_diverse has no id_col argument at all:
--     item_id in the result is already product_catalog's own real
--     `item_id` PRIMARY KEY value.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_trajectory_predict,
--      fractal_agent_recall_hybrid, fractal_agent_recommend_diverse --
--      this file needs no reasoning endpoint configured at all: none of
--      the primitives exercised here call fractal_reason.)
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-agentic-customer-support.sql
--
-- Safe to re-run: vcs_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo: the mariadb CLI has no direct equivalent of
-- psql's \timing (use `SET profiling = 1; ... SHOW PROFILES;` for
-- per-statement timing). Section markers below are plain comments, not
-- executed statements. This file has no RAND() calls at all, every
-- vector below is a literal.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Customer session telemetry -- a single customer (cust-abc)
-- drifting from onboarding toward churn across four sessions.
-- session_id is the PK the trajectory_predict agent resolves
-- internally; the latest row (max PK, session_id = 103) is "current",
-- and baseline_id (100) is "baseline".
-- ------------------------------------------------------------------
-- === 1. Customer session telemetry: onboarding -> churn drift ===

DROP TABLE IF EXISTS vcs_customer_sessions;
CREATE TABLE vcs_customer_sessions (
    session_id       BIGINT PRIMARY KEY,
    customer_id      VARCHAR(32),
    -- JSON, not fractal_vector(3): MariaDB's vector storage
    -- convention (see sql/install_udf.sql's "REPRESENTATION" note) is
    -- a JSON-array-of-numbers string, a fixed, known-width vector
    -- without a distinct column type.
    state_vector     JSON,
    sentiment_score  DOUBLE,
    last_interaction DATETIME
);

INSERT INTO vcs_customer_sessions (session_id, customer_id, state_vector, sentiment_score, last_interaction) VALUES
(100, 'cust-abc', '[0.1, 0.1, 0.1]', 0.8, NOW() - INTERVAL 30 DAY),
(101, 'cust-abc', '[0.3, 0.15, 0.1]', 0.6, NOW() - INTERVAL 20 DAY),
(102, 'cust-abc', '[0.6, 0.2, 0.1]', 0.4, NOW() - INTERVAL 10 DAY),
(103, 'cust-abc', '[0.8, 0.2, 0.1]', 0.2, NOW());

-- ------------------------------------------------------------------
-- 2. A playbook of past churn-recovery cases: what worked (or didn't)
-- for other customers whose state vector, at the point of
-- intervention, looked like this. fractal_agent_recall_hybrid searches
-- this by real vector similarity against session 103's current state.
-- ------------------------------------------------------------------
-- === 2. Churn-recovery playbook ===

DROP TABLE IF EXISTS vcs_customer_playbook;
CREATE TABLE vcs_customer_playbook (
    case_id      BIGINT PRIMARY KEY,
    customer_id  VARCHAR(32),
    state_vector JSON,
    resolution   TEXT
);

INSERT INTO vcs_customer_playbook (case_id, customer_id, state_vector, resolution) VALUES
(1, 'cust-def', '[0.75, 0.22, 0.12]', 'Escalated to a retention specialist with a loyalty discount; saved'),
(2, 'cust-ghi', '[0.30, 0.10, 0.05]', 'Proactive check-in call resolved early-stage frustration'),
(3, 'cust-jkl', '[0.82, 0.18, 0.09]', 'Offered a downgrade path instead of cancellation; saved'),
(4, 'cust-mno', '[0.05, 0.05, 0.05]', 'No intervention needed, healthy customer');

-- ------------------------------------------------------------------
-- 3. A retention-offer catalog for fractal_agent_recommend_diverse to
-- pick a diverse, non-redundant set of interventions from.
-- ------------------------------------------------------------------
-- === 3. Retention-offer catalog ===

DROP TABLE IF EXISTS vcs_product_catalog;
CREATE TABLE vcs_product_catalog (
    item_id BIGINT PRIMARY KEY,
    name    VARCHAR(64),
    emb     JSON
);

INSERT INTO vcs_product_catalog (item_id, name, emb) VALUES
(1, 'Loyalty Discount 20%',    '[0.80, 0.20, 0.10]'),
(2, 'Free Premium Upgrade',    '[0.75, 0.25, 0.15]'),
(3, 'Dedicated Support Line',  '[0.60, 0.30, 0.20]'),
(4, 'Downgrade to Basic Plan', '[0.40, 0.10, 0.05]'),
(5, 'Early Renewal Bonus',     '[0.20, 0.10, 0.10]');

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- === 4. Enable stateful diversification to avoid repeating failed scripts ===
SELECT fractal_diversify_enable(CONNECTION_ID());

-- === 5. fractal_agent_trajectory_predict: forecast trajectory drift toward churn ===
-- Searches the corpus for the nearest predicted state to the delta
-- between the baseline session (100) and the latest session (103,
-- resolved internally as the table's own MAX(session_id)). Returns a
-- real predicted_state_vector (length 3, derived from the data) and a
-- real projected_drift_delta, not a hardcoded placeholder. risk_
-- threshold NULL applies the fixed 0.5 default.
CALL fractal_agent_trajectory_predict(
    'vcs_customer_sessions', 'state_vector',
    100,   -- baseline_id (onboarding)
    5,     -- forecast_steps (signature parity only, unused -- see header)
    NULL,  -- risk_threshold: NULL -> default 0.5
    @r);
SELECT JSON_EXTRACT(@r, '$.predicted_state_vector') AS predicted_state_vector,
       JSON_VALUE(@r, '$.projected_drift_delta') AS projected_drift_delta,
       JSON_VALUE(@r, '$.risk_threshold_exceeded') AS risk_threshold_exceeded;

-- === 6. fractal_agent_recall_hybrid: hybrid memory recall ===
-- Recall past playbook cases whose state vector, at intervention time,
-- was close to this customer's current drifting state (session 103).
-- NULL, NULL for filter_col/filter_val: no cohort filter, search the
-- whole playbook.
CALL fractal_agent_recall_hybrid(
    'vcs_customer_playbook', 'state_vector', '[0.8, 0.2, 0.1]',
    NULL, NULL, 5, 'resolution', @r);
-- Pure-retrieval engine (no LLM step): @r is a JSON ARRAY of
-- {"mem_id":..,"content":..} objects (mem_id is customer_playbook's own
-- real case_id) -- explode via JSON_TABLE, same fix demo-agents.sql
-- Section 6 uses for the identical shape.
SELECT mem_id, content
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           mem_id  VARCHAR(32) PATH '$.mem_id',
           content TEXT        PATH '$.content')) AS jt;

-- === 7. fractal_explore: repulsion-guided intervention candidates ===
-- Diverse (non-redundant) session-state candidates around this
-- customer's current drifting state, Scout-searched over the inline
-- session corpus, see this file's header note on why this takes the
-- corpus inline instead of a table/column pair.
SET @vcs_corpus = (SELECT JSON_ARRAYAGG(state_vector) FROM vcs_customer_sessions);
SELECT jt.p AS candidate_vector
  FROM JSON_TABLE(
      (SELECT fractal_explore(@vcs_corpus, '[0.8, 0.2, 0.1]', '{"population_size": 5}')),
      '$.population[*]' COLUMNS (p JSON PATH '$')
  ) AS jt;

-- === 8. fractal_agent_recommend_diverse: diverse retention offers ===
-- Repulsion-diverse top-k retention offers for this customer's current
-- state. item_id in the result is already product_catalog's own real
-- item_id, no id_col argument or ctid/row_number remap needed.
CALL fractal_agent_recommend_diverse(
    'vcs_product_catalog', 'emb', '[0.8, 0.2, 0.1]', 5, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
ORDER BY score DESC;

-- Reset the session-global diversify flag Sections 4 and 8 left
-- enabled (recommend_diverse leaves it on, the caller owns resetting
-- it -- same belt-and-suspenders reset demo-agents.sql and
-- demo-vertical-cybersecurity-threat-detection.sql both use).
SELECT fractal_diversify_disable(CONNECTION_ID());

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vcs_customer_sessions, vcs_customer_playbook, vcs_product_catalog;
