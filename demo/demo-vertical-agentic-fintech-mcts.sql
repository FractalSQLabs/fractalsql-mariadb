-- demo/demo-vertical-agentic-fintech-mcts.sql
--
-- Agentic vertical: FinTech -- Scenario Exploration & Safe Execution.
--
-- End-to-end regression test for the planning + text-to-sql Universal
-- Agent primitives. Exercises:
--   * fractal_agent_plan_explore      -- embeds the seed state,
--     Scout-searches a real vectorized embedding column, returns each
--     branch's own matched-row id, its own vector, and a score.
--   * fractal_sql_agent               -- self-correcting Text-to-SQL
--     with an optional auto-execute step; a thrown exception during
--     auto-execute is caught and surfaced as execution_status=
--     'execution_failed' in result_json, never propagated to abort the
--     whole CALL.
--   * fractal_agent_rebalance_sibling -- portfolio rebalance (SFS
--     optimizer + trajectory search) composition.
--   * fractal_reason                  -- rationale synthesis (called
--     internally by fractal_agent_rebalance_sibling).
--   * fractal_vectorizer_create / fractal_vectorizer_process_queue --
--     vectorizes the strategy descriptions.
-- Re-runnable: tear down a prior run's vectorizer config + queue (the
-- config outlives the table in v1 -- there is no fractal_vectorizer_
-- drop-on-table-drop), then drop the demo tables. The unconditional
-- DELETEs are no-ops on a first run.
--
-- Structural notes (see sql/install_agents.sql's own header for the
-- fuller account):
--   - fractal_agent_plan_explore is a PROCEDURE with a trailing OUT
--     p_result JSON param, not a RETURNS TABLE function (MariaDB has no
--     set-returning UDFs; this extension's house convention is
--     OUT-JSON, see sql/install_agents.sql's own header):
--     `CALL fractal_agent_plan_explore(initial_state,
--     strategy_table, vector_col, max_branches, @r)`. The branches come
--     back as a JSON array in @r, exploded below via JSON_TABLE.
--   - fractal_sql_agent is a PROCEDURE with three trailing OUT params
--     (generated_sql, status, result_json), not a RETURNS TABLE
--     function, invoked as `CALL fractal_sql_agent(question,
--     table_names, max_retries, auto_execute, @sql, @status,
--     @result_json)`. table_names is a JSON array of table-name
--     strings. auto_execute's safety net is a DECLARE ... CONTINUE
--     HANDLER FOR SQLEXCEPTION around the execute step: a failing
--     generated statement is caught and reported as
--     execution_status='execution_failed' with the error text in
--     result_json, never aborts this script.
--   - fractal_agent_rebalance_sibling's trailing args are (seed BIGINT,
--     context TEXT), see sql/install_agents.sql's own Engine K comment
--     and demo-vertical-quant-finance.sql's identical note.
--   - fractal_optimize_portfolio (called internally by
--     fractal_agent_rebalance_sibling) takes mu/cov as JSON-array-
--     string arguments (cov: a flat, row-major n*n covariance array)
--     plus a JSON params object bundling seed/use_obl/diffusion_mode,
--     rather than trailing DEFAULT scalar arguments (MariaDB's CREATE
--     FUNCTION has no DEFAULT-argument syntax).
--   - fractal_vectorizer_create/_process_queue are PROCEDUREs (trailing
--     OUT p_id / plain IN batch args), see demo-vectorizer.sql.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (fractal_agent_plan_explore,
--      fractal_agent_rebalance_sibling)
--   3. Reasoning AND embedding configured (see docs/reasoning-setup.md
--      and docs/vectorizer-setup.md) -- Section 5's plan_explore call
--      embeds its initial_state text, Section 6's fractal_sql_agent
--      calls the same reasoning endpoint to generate SQL, and Section 7's
--      fractal_agent_rebalance_sibling calls fractal_reason internally.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-agentic-fintech-mcts.sql
--
-- Safe to re-run: vfm_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo: the mariadb CLI has no direct equivalent of
-- psql's \timing (use `SET profiling = 1; ... SHOW PROFILES;` for
-- per-statement timing). This file has no RAND() calls at all, every
-- vector/covariance value below is a literal.

DELETE FROM fractal_vectorizer_rate_window WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'vfm_trade_strategies');
DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id IN
    (SELECT id FROM fractal_vectorizers WHERE source_table = 'vfm_trade_strategies');
DELETE FROM fractal_vectorizers WHERE source_table = 'vfm_trade_strategies';
DROP TABLE IF EXISTS vfm_trade_strategies, vfm_portfolios, vfm_assets, vfm_restrictions, vfm_historical_allocations;

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Setup financial strategy space.
-- ------------------------------------------------------------------
-- === 1. Financial strategy space ===

CREATE TABLE vfm_trade_strategies (
    strategy_id     INT PRIMARY KEY,
    description     TEXT,          -- vectorized below
    -- JSON, not fractal_vector(768) -- MariaDB's vector storage
    -- convention (see sql/install_udf.sql's "REPRESENTATION" note): a
    -- JSON-array-of-numbers string populated by the vectorizer
    -- (nomic-embed-text), not a distinct fixed-width column type.
    embedding       JSON,
    trajectory      JSON,
    constraints_json JSON,
    expected_return DOUBLE
);

INSERT INTO vfm_trade_strategies (strategy_id, description, trajectory, constraints_json, expected_return) VALUES
(1, 'low-volatility mean-reversion strategy targeting ESG-compliant equities with tight risk bounds',
    '[0.1, 0.2]', '{"max_risk": 0.05}', 0.08),
(2, 'momentum strategy riding medium-term trends with moderate risk tolerance and diversified sector exposure',
    '[0.5, 0.1]', '{"max_risk": 0.10}', 0.12),
(3, 'high-conviction concentrated strategy with strict risk budget and low expected turnover',
    '[0.9, 0.8]', '{"max_risk": 0.02}', 0.04);

-- 2. Vectorize the strategy descriptions into embeddings -- the
-- embedding column fractal_agent_plan_explore needs (it embeds the
-- initial_state text and Scout-searches this column).
CALL fractal_vectorizer_create('vfm_trade_strategies', 'description', 'embedding', NULL, @vfm_vzid);
CALL fractal_vectorizer_process_queue(100, 600);

-- ------------------------------------------------------------------
-- 3. Portfolio/asset/restriction tables referenced by the
-- fractal_sql_agent regulatory-audit step. Minimal seed so
-- fractal_schema_context can resolve the table_names it is given.
-- ------------------------------------------------------------------
-- === 3. Portfolio / asset / restriction seed data ===

CREATE TABLE vfm_portfolios (
    portfolio_id INT PRIMARY KEY,
    name         VARCHAR(64) NOT NULL
);
CREATE TABLE vfm_assets (
    asset_id       INT PRIMARY KEY,
    portfolio_id   INT NOT NULL,
    value          DECIMAL(15,2) NOT NULL,
    esg_restricted BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE vfm_restrictions (
    restriction_id   INT PRIMARY KEY,
    asset_id         INT NOT NULL,
    restriction_type VARCHAR(32) NOT NULL
);
INSERT INTO vfm_portfolios (portfolio_id, name) VALUES
    (1, 'Global Growth'), (2, 'ESG Core'), (3, 'High Yield');
INSERT INTO vfm_assets (asset_id, portfolio_id, value, esg_restricted) VALUES
    (101, 1, 250000, FALSE),
    (102, 1, 120000, TRUE),
    (103, 2,  80000, TRUE),
    (104, 3, 310000, FALSE);
INSERT INTO vfm_restrictions (restriction_id, asset_id, restriction_type) VALUES
    (1, 102, 'ESG-fossil-fuel'),
    (2, 103, 'ESG-weapons');

-- ------------------------------------------------------------------
-- 4. A snapshot of past allocation decisions, for
-- fractal_agent_rebalance_sibling's trajectory-search half: "which
-- prior allocation is this new one closest to." Weight vectors match
-- mu/cov's 2-asset shape below.
-- ------------------------------------------------------------------
-- === 4. Historical allocation snapshots ===

CREATE TABLE vfm_historical_allocations (
    alloc_id BIGINT PRIMARY KEY,
    label    VARCHAR(64),
    weights  JSON
);
INSERT INTO vfm_historical_allocations (alloc_id, label, weights) VALUES
(1, 'Q1-2025 momentum tilt',  '[0.6, 0.4]'),
(2, 'Q2-2025 defensive tilt', '[0.3, 0.7]'),
(3, 'Q3-2025 balanced',       '[0.5, 0.5]');

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- === 5. fractal_agent_plan_explore: MCTS-style strategy exploration ===
-- Explore N non-overlapping execution paths starting from a seed market
-- state. Embeds the initial_state text (->embedding-width) and
-- Scout-searches vfm_trade_strategies.embedding for diverse branches.
-- Result: max_branches (here 3) diverse branch_ids with confidence
-- scores.
CALL fractal_agent_plan_explore(
    'momentum strategy with moderate risk',
    'vfm_trade_strategies', 'embedding',
    3,   -- max_branches
    @r);
SELECT branch.doc_id, branch.plan_trajectory, branch.score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           doc_id          VARCHAR(32) PATH '$.doc_id',
           plan_trajectory JSON        PATH '$.plan_trajectory',
           score           DOUBLE      PATH '$.score')) AS branch
ORDER BY branch.score DESC;

-- === 6. Self-correcting Text-to-SQL for regulatory audit ===
-- Ask for a complex regulatory report, with auto-execution and
-- retries. On a working model this returns execution_status='executed'
-- and the row count in result_json; on a rejected/failing candidate it
-- returns execution_status='execution_failed' with the error captured
-- by the CONTINUE HANDLER described in this file's header, rather than
-- aborting this script.
CALL fractal_sql_agent(
    'Calculate the total exposure to ESG-restricted assets across all portfolios',
    '["vfm_portfolios", "vfm_assets", "vfm_restrictions"]',
    3,     -- max_retries
    TRUE,  -- auto_execute
    @vfm_sql, @vfm_status, @vfm_result_json);
SELECT @vfm_sql AS generated_sql, @vfm_status AS execution_status, @vfm_result_json AS result_json;

-- === 7. Portfolio Rebalance (fractal_agent_rebalance_sibling) ===
-- Runs the SFS optimizer (cov must be a FLATTENED 1-D array of length
-- n_assets^2 -- fractal_optimize_portfolio rejects a 2-D matrix; the
-- 2x2 identity here is [1,0,0,1] row-major, see
-- demo-vertical-quant-finance.sql for the JSON_ARRAYAGG pattern at real
-- scale), then finds the nearest prior allocation to an equal-weight
-- baseline via trajectory search, then reasons over both. Trailing
-- args are (seed, context), not (k, id_col, meta) -- see this file's
-- header.
CALL fractal_agent_rebalance_sibling(
    '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 2,
    'vfm_historical_allocations', 'weights', '[0.5, 0.5]',
    42, '{"portfolio": "port-global-01"}', @r);
SELECT JSON_VALUE(@r, '$.sharpe') AS sharpe,
       JSON_EXTRACT(@r, '$.weights') AS weights,
       JSON_VALUE(@r, '$.nearest_alloc_id') AS nearest_alloc_id,
       JSON_VALUE(@r, '$.nearest_distance') AS nearest_distance,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 8. Safe Execution: see this file's header note on fractal_sql_agent's
-- auto_execute path -- the CONTINUE HANDLER wrapped around the execute
-- step in Section 6 ensures a late-stage constraint violation or
-- generated-SQL error surfaces as execution_status='execution_failed'
-- in result_json instead of aborting this whole script or session.
-- ------------------------------------------------------------------
-- === 8. Safe execution: absorbed into the Section 6 result ===

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE vfm_trade_strategies, vfm_portfolios, vfm_assets,
--              vfm_restrictions, vfm_historical_allocations;
