-- sql/install_agents.sql
-- fractalsql-mariadb Agency tier.
--
-- These agents are plain stored PROCEDURE definitions that call the base
-- UDFs from sql/install_udf.sql. MariaDB has no CREATE EXTENSION and no
-- extension dependency graph to hook into, so a second install script of
-- ordinary procedures is the whole mechanism: nothing else needs building.
--
-- Prerequisite: sql/install_udf.sql must already be run. This script calls
-- fractal_search/_telemetry, fractal_hybrid_clinical_search, fractal_
-- search_trajectory, fractal_reason, fractal_dimension_*, fractal_
-- optimize_portfolio(_multimodal), fractal_morphological_complexity,
-- fractal_diversify_*, fractal_feedback_report/_isolate_background, and
-- fractal_sql_agent, all base-tier primitives.
--
-- 16 lettered engines (A-P), each a real composition of fractalsql
-- primitives across Discovery, Cognition, and Analytics, with the
-- user's tables and columns passed as arguments rather than hardcoded.
-- Engine P (fractal_agent_diverse_portfolios) calls fractal_optimize_
-- portfolio_multimodal, an enterprise-tier primitive: dormant (returns
-- NULL) on a Community deployment with no FRACTALSQL_ENTERPRISE_LIB set,
-- same as the fractal_ledger_* enterprise functions in sql/install_udf.sql,
-- real once that variable points at a loaded enterprise core library.
-- See docs/enterprise.md.
--
-- Five additional base-tier "Universal Agent" procedures use the same
-- compositional style (embed/search/reason over a caller-named table):
-- fractal_agent_trajectory_predict, fractal_search_agent,
-- fractal_rag_agent, fractal_agent_plan_explore, and
-- fractal_agent_detect_loop. Each runs its table scan via dynamic SQL
-- (PREPARE/EXECUTE) inside a stored PROCEDURE, the same mechanism
-- fractal_search_telemetry/_hybrid_clinical_search/_search_trajectory
-- (sql/install_udf.sql) already use (see each one's own header comment
-- below for behavioral notes).
--
-- Three simplifications apply across every engine below:
--
--   1. No id remapping. fractal_search_telemetry/fractal_hybrid_
--      clinical_search/fractal_search_trajectory (sql/install_udf.sql)
--      already resolve and return real primary-key values directly, so
--      every agent below that consumes their doc_id output skips any
--      separate "named id column" argument (cap_id_col, node_id_col,
--      id_col, and so on): the table's own single-column PRIMARY KEY,
--      which the base primitives already require and resolve, is
--      always what gets returned, not a caller-chosen alternate
--      column.
--   2. Enterprise audit-chain logging: every decision-making engine
--      below also logs its own decision, best-effort, to the kind=2
--      decision-audit chain (fractal_audit_log, an enterprise-tier UDF
--      in sql/install_udf.sql, see docs/enterprise.md). A dormant call
--      returns NULL and writes nothing, so a missing enterprise tier
--      never breaks the agent; the three pure-retrieval/pure-analytics
--      engines (recall_hybrid, recommend_diverse, feedback_audit) don't
--      make a decision worth auditing and aren't wired up.
--   3. JSON-array-string arguments and returns, not float8[]/text[]/
--      int8[]/RETURNS TABLE. Same convention the rest of this
--      extension uses everywhere; see sql/install_udf.sql for the full
--      rationale. Every engine below takes vectors and matrices as
--      JSON arrays and returns one JSON object (or, for the two
--      pure-retrieval multi-row engines E and F, a JSON array of
--      objects) via a single OUT parameter, rather than RETURNS TABLE,
--      which MariaDB doesn't have.
--
-- Session scoping: every engine below computes CONNECTION_ID() internally
-- for its own fractal_reason/fractal_diversify_* calls, rather than
-- exposing session_id as a caller-facing parameter.
--
-- SQL SECURITY: every engine is SQL SECURITY INVOKER, an explicit
-- choice since MariaDB's own default is DEFINER. These procedures run
-- ordinary reads and writes against caller-named tables and dispatch
-- to primitives that already carry the right INVOKER/DEFINER setting;
-- there's no privilege elevation need here the way
-- fractal_vectorizer_create's own CREATE TRIGGER step has.

DROP PROCEDURE IF EXISTS fractal_agent_anomaly_triage;
DROP PROCEDURE IF EXISTS fractal_agent_allocate;
DROP PROCEDURE IF EXISTS fractal_agent_diverse_portfolios;
DROP PROCEDURE IF EXISTS fractal_agent_route_task;
DROP PROCEDURE IF EXISTS fractal_agent_outlier_intercept;
DROP PROCEDURE IF EXISTS fractal_agent_recall_hybrid;
DROP PROCEDURE IF EXISTS fractal_agent_recommend_diverse;
DROP PROCEDURE IF EXISTS fractal_agent_data_analyst;
DROP PROCEDURE IF EXISTS fractal_agent_patient_deterioration_triage;
DROP PROCEDURE IF EXISTS fractal_agent_feedback_audit;
DROP PROCEDURE IF EXISTS fractal_agent_schedule_workload;
DROP PROCEDURE IF EXISTS fractal_agent_rebalance_sibling;
DROP PROCEDURE IF EXISTS fractal_agent_detour_classify;
DROP PROCEDURE IF EXISTS fractal_agent_track_anomaly;
DROP PROCEDURE IF EXISTS fractal_agent_network_coverage_alert;
DROP PROCEDURE IF EXISTS fractal_agent_regime_triage;
DROP PROCEDURE IF EXISTS fractal_agent_trajectory_predict;
DROP PROCEDURE IF EXISTS fractal_search_agent;
DROP PROCEDURE IF EXISTS fractal_rag_agent;
DROP PROCEDURE IF EXISTS fractal_agent_plan_explore;
DROP PROCEDURE IF EXISTS fractal_agent_detect_loop;

DELIMITER $$

-- =====================================================================
-- Engine A: fractal_agent_anomaly_triage
-- fractal_dimension_drift + fractal_reason. Reads one entity's metric
-- time series from log_table (filtered by filter_col = filter_val,
-- ordered by time_col), runs fractal_dimension_drift over it, then
-- fractal_reason to synthesize a triage summary.
-- =====================================================================
CREATE PROCEDURE fractal_agent_anomaly_triage(
    IN  p_log_table       VARCHAR(128),
    IN  p_metric_col      VARCHAR(64),
    IN  p_time_col        VARCHAR(64),
    IN  p_filter_col      VARCHAR(64),
    IN  p_filter_val      VARCHAR(255),
    IN  p_baseline_window INT,
    OUT p_result          JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_series      TEXT;
    DECLARE v_drift        TEXT;
    DECLARE v_reasoning    TEXT;
    DECLARE v_window       INT DEFAULT IFNULL(p_baseline_window, 32);
    DECLARE v_audit        BIGINT DEFAULT 0;

    IF p_log_table IS NULL OR p_metric_col IS NULL OR p_time_col IS NULL OR p_filter_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_anomaly_triage: identifier arguments must not be NULL';
    END IF;

    SET @_fractalsql_at_sql = CONCAT(
        'SELECT CONCAT(''['', GROUP_CONCAT(', _fractalsql_quote_ident(p_metric_col),
        ' ORDER BY ', _fractalsql_quote_ident(p_time_col), ' SEPARATOR '',''), '']'') ',
        'INTO @_fractalsql_at_series FROM ', _fractalsql_quote_ident(p_log_table),
        ' WHERE ', _fractalsql_quote_ident(p_filter_col), ' = ', QUOTE(p_filter_val));
    SET @_fractalsql_at_series = NULL;
    PREPARE _fractalsql_at_stmt FROM @_fractalsql_at_sql;
    EXECUTE _fractalsql_at_stmt;
    DEALLOCATE PREPARE _fractalsql_at_stmt;
    SET v_series = @_fractalsql_at_series;

    IF v_series IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_anomaly_triage: no rows matching the filter';
    END IF;

    SET v_drift = fractal_dimension_drift(v_series, v_window);
    SET v_reasoning = fractal_reason(v_session_id,
        CONCAT('Triage this anomaly: ', v_drift),
        JSON_OBJECT('table', p_log_table, p_filter_col, p_filter_val));

    SET v_audit = fractal_audit_log('agent_anomaly_triage', JSON_OBJECT(
        'threat_score', IFNULL(JSON_VALUE(v_drift, '$.drift'), 0.0),
        'anomaly_type', 'vector_drift', 'triage_summary', v_reasoning));

    SET p_result = JSON_OBJECT(
        'threat_score', IFNULL(JSON_VALUE(v_drift, '$.drift'), 0.0),
        'anomaly_type', 'vector_drift',
        'triage_summary', v_reasoning);
END$$

-- =====================================================================
-- Engine B: fractal_agent_allocate
-- fractal_optimize_portfolio + fractal_reason.
-- =====================================================================
CREATE PROCEDURE fractal_agent_allocate(
    IN  p_mu          JSON,
    IN  p_cov         JSON,
    IN  p_cardinality INT,
    IN  p_context     TEXT,
    OUT p_result      JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_opt      TEXT;
    DECLARE v_sharpe    DOUBLE;
    DECLARE v_reasoning TEXT;
    DECLARE v_audit     BIGINT DEFAULT 0;

    SET v_opt = fractal_optimize_portfolio(p_mu, p_cov, p_cardinality, '{}');
    SET v_sharpe = IFNULL(JSON_VALUE(v_opt, '$.sharpe'), 0.0);
    SET v_reasoning = fractal_reason(v_session_id,
        CONCAT('Explain this cardinality-constrained allocation and its risk/return: ', v_opt),
        IFNULL(p_context, '{}'));

    -- Use JSON_EXTRACT(v_opt, '$'), not CAST(v_opt AS CHAR). We verified
    -- live that JSON_OBJECT() string-escapes a plain TEXT/JSON-typed
    -- variable's content as a quoted scalar rather than nesting it as a
    -- real sub-object (MariaDB's JSON type carries no distinct runtime
    -- representation a variable assignment can preserve; only an
    -- inline JSON_EXTRACT(..., '$') expression is recognized as
    -- "already JSON" by JSON_OBJECT/JSON_ARRAY). That hint does not
    -- survive being stored in a variable first, even one itself
    -- populated via JSON_EXTRACT.
    -- Complements fractal_optimize_portfolio's own audit-chain entry:
    -- the optimizer logs the raw decision, this logs the narrated one.
    SET v_audit = fractal_audit_log('agent_allocate', JSON_OBJECT(
        'sharpe', v_sharpe, 'cardinality', p_cardinality, 'rationale', v_reasoning));

    SET p_result = JSON_OBJECT('allocation', JSON_EXTRACT(v_opt, '$'), 'sharpe', v_sharpe, 'rationale', v_reasoning);
END$$

-- =====================================================================
-- Engine C: fractal_agent_route_task
-- fractal_search_telemetry + fractal_reason. Finds the capability
-- whose embedding is nearest to task_emb, derives confidence from the
-- real distance, accounts the budget, and reasons a routing rationale.
-- =====================================================================
CREATE PROCEDURE fractal_agent_route_task(
    IN  p_task_emb       JSON,
    IN  p_cap_table      VARCHAR(128),
    IN  p_cap_emb_col    VARCHAR(64),
    IN  p_budget         INT,
    IN  p_cost_per_route INT,
    OUT p_result         JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_telemetry TEXT;
    DECLARE v_routed_to VARCHAR(255);
    DECLARE v_dist       DOUBLE;
    DECLARE v_confidence DOUBLE;
    DECLARE v_rationale  TEXT;
    DECLARE v_cost       INT DEFAULT IFNULL(p_cost_per_route, 150);
    DECLARE v_audit      BIGINT DEFAULT 0;

    IF p_cap_table IS NULL OR p_cap_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_route_task: identifier arguments must not be NULL';
    END IF;

    CALL fractal_search_telemetry(p_cap_table, p_cap_emb_col, p_task_emb, 1, v_telemetry);
    IF v_telemetry IS NULL OR JSON_LENGTH(v_telemetry) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_route_task: no capability rows found';
    END IF;

    SET v_routed_to = JSON_VALUE(v_telemetry, '$[0].doc_id');
    SET v_dist       = JSON_VALUE(v_telemetry, '$[0].dist');
    SET v_confidence  = 1.0 / (1.0 + v_dist);

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Route this task to capability ', IFNULL(v_routed_to, '?'),
               ' (cosine distance ', v_dist, '). Justify the routing in one sentence.'),
        JSON_OBJECT('budget', p_budget, 'cost_per_route', v_cost));

    SET v_audit = fractal_audit_log('agent_route_task', JSON_OBJECT(
        'routed_to', v_routed_to, 'confidence', v_confidence,
        'remaining_budget', p_budget - v_cost, 'rationale', v_rationale));

    SET p_result = JSON_OBJECT(
        'routed_to', v_routed_to, 'confidence', v_confidence,
        'remaining_budget', p_budget - v_cost, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine D: fractal_agent_outlier_intercept
-- fractal_search_telemetry + fractal_reason. intercepted = (nearest
-- known-bad-state distance < threshold), a real comparison.
-- =====================================================================
CREATE PROCEDURE fractal_agent_outlier_intercept(
    IN  p_state_vec     JSON,
    IN  p_history_table VARCHAR(128),
    IN  p_emb_col       VARCHAR(64),
    IN  p_threshold     DOUBLE,
    OUT p_result        JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_telemetry TEXT;
    DECLARE v_dist       DOUBLE;
    DECLARE v_intercepted BOOLEAN;
    DECLARE v_reason     TEXT;
    DECLARE v_audit      BIGINT DEFAULT 0;

    IF p_history_table IS NULL OR p_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_outlier_intercept: identifier arguments must not be NULL';
    END IF;

    CALL fractal_search_telemetry(p_history_table, p_emb_col, p_state_vec, 1, v_telemetry);
    IF v_telemetry IS NULL OR JSON_LENGTH(v_telemetry) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_outlier_intercept: no bad-state rows found';
    END IF;

    SET v_dist = JSON_VALUE(v_telemetry, '$[0].dist');
    SET v_intercepted = (v_dist < p_threshold);

    SET v_reason = fractal_reason(v_session_id,
        CONCAT('Outlier intercept: nearest known-bad state is at cosine distance ', v_dist,
               ', threshold ', p_threshold, ', so ',
               IF(v_intercepted, 'INTERCEPT', 'allow'),
               '. Justify the decision in one sentence.'),
        JSON_OBJECT('threshold', p_threshold, 'intercepted', v_intercepted));

    -- High-value trail: this engine can block a proposed state/action.
    SET v_audit = fractal_audit_log('agent_outlier_intercept', JSON_OBJECT(
        'intercepted', v_intercepted, 'nearest_distance', v_dist,
        'threshold', p_threshold, 'reason', v_reason));

    SET p_result = JSON_OBJECT('intercepted', v_intercepted, 'reason', v_reason);
END$$

-- =====================================================================
-- Engine E: fractal_agent_recall_hybrid (pure retrieval, no LLM step)
-- fractal_hybrid_clinical_search restricted to an optional metadata
-- filter's cohort. Returns a JSON array of {"mem_id":..,"content":..}.
-- =====================================================================
CREATE PROCEDURE fractal_agent_recall_hybrid(
    IN  p_mem_table   VARCHAR(128),
    IN  p_vec_col     VARCHAR(64),
    IN  p_query_vec   JSON,
    IN  p_filter_col  VARCHAR(64),
    IN  p_filter_val  VARCHAR(255),
    IN  p_k           INT,
    IN  p_content_col VARCHAR(64),
    OUT p_result      JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_pk_col   VARCHAR(64);
    DECLARE v_pk_count INT DEFAULT 0;
    DECLARE v_cohort   JSON;
    DECLARE v_hits     TEXT;

    IF p_mem_table IS NULL OR p_vec_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_recall_hybrid: identifier arguments must not be NULL';
    END IF;

    SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_mem_table AND constraint_name = 'PRIMARY';
    IF v_pk_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_recall_hybrid: mem_table must have exactly one single-column PRIMARY KEY';
    END IF;
    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_mem_table AND constraint_name = 'PRIMARY' LIMIT 1;

    -- The "hybrid" is the cohort: a strict SQL filter (filter_col =
    -- filter_val), or every row when filter_col is NULL. This uses the
    -- table's own real PK values (see this file's header, point 1).
    IF p_filter_col IS NULL THEN
        SET @_fractalsql_rh_sql = CONCAT(
            'SELECT JSON_ARRAYAGG(', _fractalsql_quote_ident(v_pk_col), ') INTO @_fractalsql_rh_cohort FROM ',
            _fractalsql_quote_ident(p_mem_table));
    ELSE
        SET @_fractalsql_rh_sql = CONCAT(
            'SELECT JSON_ARRAYAGG(', _fractalsql_quote_ident(v_pk_col), ') INTO @_fractalsql_rh_cohort FROM ',
            _fractalsql_quote_ident(p_mem_table), ' WHERE ', _fractalsql_quote_ident(p_filter_col),
            ' = ', QUOTE(p_filter_val));
    END IF;
    SET @_fractalsql_rh_cohort = NULL;
    PREPARE _fractalsql_rh_stmt FROM @_fractalsql_rh_sql;
    EXECUTE _fractalsql_rh_stmt;
    DEALLOCATE PREPARE _fractalsql_rh_stmt;
    SET v_cohort = @_fractalsql_rh_cohort;

    IF v_cohort IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_recall_hybrid: filter matched no rows';
    END IF;

    CALL fractal_hybrid_clinical_search(p_mem_table, p_vec_col, p_query_vec, v_cohort, IFNULL(p_k, 5), v_hits);

    IF p_content_col IS NULL THEN
        SELECT JSON_ARRAYAGG(JSON_OBJECT('mem_id', h.doc_id, 'content', NULL))
          INTO p_result
        FROM JSON_TABLE(v_hits, '$[*]' COLUMNS (doc_id VARCHAR(255) PATH '$.doc_id', dist DOUBLE PATH '$.dist')) h;
    ELSE
        SET @_fractalsql_rh_sql2 = CONCAT(
            'SELECT JSON_ARRAYAGG(JSON_OBJECT(''mem_id'', h.doc_id, ''content'', t.',
            _fractalsql_quote_ident(p_content_col), ')) INTO @_fractalsql_rh_result ',
            'FROM JSON_TABLE(@_fractalsql_rh_hits, ''$[*]'' COLUMNS (doc_id VARCHAR(255) PATH ''$.doc_id'', ord FOR ORDINALITY)) h ',
            'JOIN ', _fractalsql_quote_ident(p_mem_table), ' t ON t.', _fractalsql_quote_ident(v_pk_col), ' = h.doc_id ',
            'ORDER BY h.ord');
        SET @_fractalsql_rh_hits = v_hits;
        SET @_fractalsql_rh_result = NULL;
        PREPARE _fractalsql_rh_stmt2 FROM @_fractalsql_rh_sql2;
        EXECUTE _fractalsql_rh_stmt2;
        DEALLOCATE PREPARE _fractalsql_rh_stmt2;
        SET p_result = @_fractalsql_rh_result;
    END IF;

    IF p_result IS NULL THEN SET p_result = JSON_ARRAY(); END IF;
END$$

-- =====================================================================
-- Engine F: fractal_agent_recommend_diverse (pure retrieval, no LLM)
-- Enables session-global repulsion, then telemetry top-k (repulsion-
-- diverse per fractal_search_telemetry's own docstring). Returns a
-- JSON array of {"item_id":..,"score":..}. Caller owns resetting
-- diversify state (fractal_diversify_disable); this engine leaves it
-- on by design.
-- =====================================================================
CREATE PROCEDURE fractal_agent_recommend_diverse(
    IN  p_catalog_table VARCHAR(128),
    IN  p_emb_col       VARCHAR(64),
    IN  p_query_vec     JSON,
    IN  p_k             INT,
    OUT p_result        JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_telemetry TEXT;

    IF p_catalog_table IS NULL OR p_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_recommend_diverse: identifier arguments must not be NULL';
    END IF;

    SELECT fractal_diversify_enable(v_session_id) INTO @_fractalsql_rd_unused;

    CALL fractal_search_telemetry(p_catalog_table, p_emb_col, p_query_vec, IFNULL(p_k, 10), v_telemetry);

    SELECT JSON_ARRAYAGG(JSON_OBJECT('item_id', h.doc_id, 'score', 1.0 - h.dist))
      INTO p_result
    FROM JSON_TABLE(v_telemetry, '$[*]' COLUMNS (doc_id VARCHAR(255) PATH '$.doc_id', dist DOUBLE PATH '$.dist')) h;

    IF p_result IS NULL THEN SET p_result = JSON_ARRAY(); END IF;
END$$

-- =====================================================================
-- Engine G: fractal_agent_data_analyst (horizontal catch-all)
-- fractal_sql_agent + fractal_reason.
-- =====================================================================
CREATE PROCEDURE fractal_agent_data_analyst(
    IN  p_question    TEXT,
    IN  p_table_names JSON,
    IN  p_max_retries INT,
    IN  p_context     TEXT,
    OUT p_result      JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_sql        TEXT;
    DECLARE v_status      VARCHAR(20);
    DECLARE v_result_json JSON;
    DECLARE v_analysis    TEXT;
    DECLARE v_audit       BIGINT DEFAULT 0;

    CALL fractal_sql_agent(p_question, p_table_names, IFNULL(p_max_retries, 2), TRUE, v_sql, v_status, v_result_json);

    SET v_analysis = fractal_reason(v_session_id,
        CONCAT('Analyze this database query result and answer in one paragraph: ',
               IFNULL(CAST(v_result_json AS CHAR), 'null')),
        IFNULL(p_context, '{}'));

    -- High-value trail: this engine auto-executes LLM-generated SQL.
    SET v_audit = fractal_audit_log('agent_data_analyst', JSON_OBJECT(
        'question', p_question, 'generated_sql', v_sql,
        'execution_status', v_status, 'analysis', v_analysis));

    -- JSON_EXTRACT(v_result_json, '$'): see Engine B's identical comment above.
    SET p_result = JSON_OBJECT('analysis', v_analysis, 'generated_sql', v_sql, 'result_json', JSON_EXTRACT(v_result_json, '$'));
END$$

-- =====================================================================
-- Engine H: fractal_agent_patient_deterioration_triage
-- fractal_hybrid_clinical_search + fractal_search_trajectory + reason.
-- =====================================================================
CREATE PROCEDURE fractal_agent_patient_deterioration_triage(
    IN  p_patient_table  VARCHAR(128),
    IN  p_vec_col        VARCHAR(64),
    IN  p_query_vec      JSON,
    IN  p_baseline_vec   JSON,
    IN  p_current_vec    JSON,
    IN  p_cohort_doc_ids JSON,
    IN  p_k              INT,
    OUT p_result         JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_pk_col     VARCHAR(64);
    DECLARE v_pk_count   INT DEFAULT 0;
    DECLARE v_cohort     JSON;
    DECLARE v_hybrid     TEXT;
    DECLARE v_traj       TEXT;
    DECLARE v_cohort_id  VARCHAR(255);
    DECLARE v_cohort_dist DOUBLE;
    DECLARE v_traj_dist   DOUBLE;
    DECLARE v_rationale   TEXT;
    DECLARE v_cohort_matches JSON;
    DECLARE v_audit        BIGINT DEFAULT 0;

    IF p_patient_table IS NULL OR p_vec_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_patient_deterioration_triage: identifier arguments must not be NULL';
    END IF;

    IF p_cohort_doc_ids IS NOT NULL THEN
        SET v_cohort = p_cohort_doc_ids;
    ELSE
        SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
        WHERE table_schema = DATABASE() AND table_name = p_patient_table AND constraint_name = 'PRIMARY';
        IF v_pk_count <> 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_patient_deterioration_triage: patient_table must have exactly one single-column PRIMARY KEY';
        END IF;
        SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
        WHERE table_schema = DATABASE() AND table_name = p_patient_table AND constraint_name = 'PRIMARY' LIMIT 1;

        SET @_fractalsql_pt_sql = CONCAT('SELECT JSON_ARRAYAGG(', _fractalsql_quote_ident(v_pk_col),
            ') INTO @_fractalsql_pt_cohort FROM ', _fractalsql_quote_ident(p_patient_table));
        SET @_fractalsql_pt_cohort = NULL;
        PREPARE _fractalsql_pt_stmt FROM @_fractalsql_pt_sql;
        EXECUTE _fractalsql_pt_stmt;
        DEALLOCATE PREPARE _fractalsql_pt_stmt;
        SET v_cohort = @_fractalsql_pt_cohort;
    END IF;

    IF v_cohort IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_patient_deterioration_triage: cohort matched no rows';
    END IF;

    CALL fractal_hybrid_clinical_search(p_patient_table, p_vec_col, p_query_vec, v_cohort, IFNULL(p_k, 5), v_hybrid);
    IF v_hybrid IS NULL OR JSON_LENGTH(v_hybrid) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_patient_deterioration_triage: hybrid search returned no row';
    END IF;
    CALL fractal_search_trajectory(p_patient_table, p_vec_col, p_baseline_vec, p_current_vec, 1, v_traj);

    SET v_cohort_id   = JSON_VALUE(v_hybrid, '$[0].doc_id');
    SET v_cohort_dist = JSON_VALUE(v_hybrid, '$[0].dist');
    SET v_traj_dist   = JSON_VALUE(v_traj, '$[0].dist');

    -- v_hybrid already carries up to IFNULL(p_k, 5) ranked cohort matches
    -- (ascending by distance); re-key doc_id/dist as id/distance rather than
    -- leaking the primitive's raw field names, matching every other agent's
    -- convention (recall_hybrid -> mem_id, recommend_diverse -> item_id/score).
    SELECT JSON_ARRAYAGG(JSON_OBJECT('id', h.doc_id, 'distance', h.dist) ORDER BY h.dist)
      INTO v_cohort_matches
    FROM JSON_TABLE(v_hybrid, '$[*]' COLUMNS (doc_id VARCHAR(255) PATH '$.doc_id', dist DOUBLE PATH '$.dist')) h;

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Triage this patient: nearest cohort match is id ', IFNULL(v_cohort_id, '?'),
               ' at cosine distance ', v_cohort_dist, '; baseline->current drift distance is ', v_traj_dist,
               '. Justify the deterioration triage in one sentence.'),
        JSON_OBJECT('cohort_distance', v_cohort_dist, 'drift_distance', v_traj_dist));

    -- JSON_OBJECT() treats a JSON-typed variable as a plain string and
    -- re-escapes it rather than nesting it (MariaDB's JSON type is a
    -- LONGTEXT alias, not a real binary type, so JSON_OBJECT only embeds
    -- values it can see are JSON-producing expressions). Wrapping in
    -- JSON_EXTRACT(..., '$') makes it nest v_cohort_matches as a real
    -- array instead of a JSON-encoded string.
    SET v_audit = fractal_audit_log('agent_patient_deterioration_triage', JSON_OBJECT(
        'nearest_cohort_id', v_cohort_id, 'cohort_distance', v_cohort_dist,
        'drift_distance', v_traj_dist, 'rationale', v_rationale,
        'cohort_matches', JSON_EXTRACT(v_cohort_matches, '$')));

    SET p_result = JSON_OBJECT(
        'nearest_cohort_id', v_cohort_id, 'cohort_distance', v_cohort_dist,
        'drift_distance', v_traj_dist, 'rationale', v_rationale,
        'cohort_matches', JSON_EXTRACT(v_cohort_matches, '$'));
END$$

-- =====================================================================
-- Engine I: fractal_agent_feedback_audit (pure analytics, NO LLM)
-- Enables repulsion, warms the D_q rolling window, reports negative
-- feedback on the audit target, reads back D_q + diagnostics, then
-- disables diversify itself (a complete, self-contained audit cycle,
-- unlike Engine F which leaves diversify on for the caller).
-- =====================================================================
CREATE PROCEDURE fractal_agent_feedback_audit(
    IN  p_catalog_table  VARCHAR(128),
    IN  p_emb_col        VARCHAR(64),
    IN  p_query_vec      JSON,
    IN  p_warmup_table   VARCHAR(128),
    IN  p_warmup_vec_col VARCHAR(64),
    IN  p_warmup_count   INT,
    IN  p_k              INT,
    OUT p_result         JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_done       BOOLEAN DEFAULT FALSE;
    DECLARE v_warmup_vec TEXT;
    DECLARE v_target_telemetry TEXT;
    DECLARE v_target_id  VARCHAR(255);
    DECLARE v_dq         DOUBLE;
    DECLARE v_diag       TEXT;
    DECLARE v_ignored    TEXT;
    DECLARE cur CURSOR FOR
        SELECT vc FROM _fractalsql_fa_warmup ORDER BY ord;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    IF p_catalog_table IS NULL OR p_emb_col IS NULL OR p_warmup_table IS NULL OR p_warmup_vec_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_feedback_audit: identifier arguments must not be NULL';
    END IF;

    SELECT fractal_diversify_enable(v_session_id) INTO v_ignored;
    SELECT fractal_diversify_set_params(v_session_id,
        JSON_OBJECT('window_n', 5, 'repulsion_sigma', 0.3, 'repulsion_weight', 0.5)) INTO v_ignored;

    DROP TEMPORARY TABLE IF EXISTS _fractalsql_fa_warmup;
    CREATE TEMPORARY TABLE _fractalsql_fa_warmup (ord INT AUTO_INCREMENT PRIMARY KEY, vc TEXT);
    SET @_fractalsql_fa_sql = CONCAT(
        'INSERT INTO _fractalsql_fa_warmup (vc) SELECT ', _fractalsql_quote_ident(p_warmup_vec_col),
        ' FROM ', _fractalsql_quote_ident(p_warmup_table), ' LIMIT ', IFNULL(p_warmup_count, 8));
    PREPARE _fractalsql_fa_stmt FROM @_fractalsql_fa_sql;
    EXECUTE _fractalsql_fa_stmt;
    DEALLOCATE PREPARE _fractalsql_fa_stmt;

    -- Warm the D_q rolling window with varied queries. The window is
    -- empty until several searches have run, and detect_collapse
    -- returns NaN otherwise.
    OPEN cur;
    warmup_loop: LOOP
        FETCH cur INTO v_warmup_vec;
        IF v_done THEN LEAVE warmup_loop; END IF;
        CALL fractal_search_telemetry(p_catalog_table, p_emb_col, v_warmup_vec, IFNULL(p_k, 3), v_ignored);
    END LOOP;
    CLOSE cur;
    DROP TEMPORARY TABLE IF EXISTS _fractalsql_fa_warmup;

    -- Capture the audit target's top doc_id and report negative
    -- feedback on it. fractal_isolate_background takes the doc_id
    -- (the k=1 telemetry doc_id is the handle).
    CALL fractal_search_telemetry(p_catalog_table, p_emb_col, p_query_vec, 1, v_target_telemetry);
    IF v_target_telemetry IS NOT NULL AND JSON_LENGTH(v_target_telemetry) > 0 THEN
        SET v_target_id = JSON_VALUE(v_target_telemetry, '$[0].doc_id');
        SELECT fractal_isolate_background(v_session_id, v_target_id) INTO v_ignored;
    END IF;

    SET v_dq   = fractal_detect_collapse(v_session_id);
    SET v_diag = fractal_explain_result(v_session_id);

    SELECT fractal_diversify_disable(v_session_id) INTO v_ignored;

    -- JSON_EXTRACT(..., '$'): see Engine B's identical comment.
    SET p_result = JSON_OBJECT('diversity_quotient', v_dq, 'explanation', JSON_EXTRACT(IFNULL(v_diag, '{}'), '$'));
END$$

-- =====================================================================
-- Engine J: fractal_agent_schedule_workload
-- fractal_search (sniper refinement) + fractal_search_telemetry +
-- reason. Like Engine C but with the fractal_search refinement step
-- route_task lacks.
-- =====================================================================
CREATE PROCEDURE fractal_agent_schedule_workload(
    IN  p_task_vec     JSON,
    IN  p_node_table   VARCHAR(128),
    IN  p_node_emb_col VARCHAR(64),
    IN  p_iterations   INT,
    IN  p_population    INT,
    IN  p_k             INT,
    IN  p_context       TEXT,
    OUT p_result        JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_refined_json TEXT;
    DECLARE v_refined      JSON;
    DECLARE v_telemetry    TEXT;
    DECLARE v_assigned     VARCHAR(255);
    DECLARE v_dist          DOUBLE;
    DECLARE v_confidence    DOUBLE;
    DECLARE v_rationale     TEXT;
    DECLARE v_audit         BIGINT DEFAULT 0;

    IF p_node_table IS NULL OR p_node_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_schedule_workload: identifier arguments must not be NULL';
    END IF;

    -- fractal_search's own corpus/query shape: a single-row corpus (the
    -- task vector itself) refines toward its own local optimum, the
    -- "sniper search" idea behind fractal_search(task_vec, ...).
    -- NOTE: wrapping via plain CONCAT, not JSON_ARRAY(p_task_vec).
    -- JSON_ARRAY() on an already-JSON-text argument double-encodes it
    -- as a quoted STRING element ('["[0.9,0.1,0]"]'), not a real
    -- nested array ('[[0.9,0.1,0]]'). This is the same class of gap as
    -- sql/install_udf.sql's CAST(x AS JSON)/JSON_ARRAYAGG note:
    -- MariaDB's JSON type has no distinct binary representation that a
    -- JSON-producing function can recognize and nest verbatim.
    SET v_refined_json = fractal_search(
        CONCAT('[', p_task_vec, ']'), p_task_vec,
        IFNULL(p_iterations, 30),
        JSON_OBJECT('population_size', IFNULL(p_population, 50), 'diffusion_factor', 2));
    SET v_refined = JSON_EXTRACT(v_refined_json, '$.best_point');

    CALL fractal_search_telemetry(p_node_table, p_node_emb_col, v_refined, 1, v_telemetry);
    IF v_telemetry IS NULL OR JSON_LENGTH(v_telemetry) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_schedule_workload: no node rows found';
    END IF;

    SET v_assigned   = JSON_VALUE(v_telemetry, '$[0].doc_id');
    SET v_dist        = JSON_VALUE(v_telemetry, '$[0].dist');
    SET v_confidence   = 1.0 / (1.0 + v_dist);

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Schedule this workload onto node ', IFNULL(v_assigned, '?'),
               ' (cosine distance ', v_dist, ' after fractal_search refinement). ',
               'Justify the placement in one sentence.'),
        IFNULL(p_context, '{}'));

    SET v_audit = fractal_audit_log('agent_schedule_workload', JSON_OBJECT(
        'assigned_node', v_assigned, 'confidence', v_confidence, 'rationale', v_rationale));

    SET p_result = JSON_OBJECT('assigned_node', v_assigned, 'confidence', v_confidence, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine K: fractal_agent_rebalance_sibling
-- fractal_optimize_portfolio + fractal_search_trajectory + reason.
-- =====================================================================
CREATE PROCEDURE fractal_agent_rebalance_sibling(
    IN  p_mu            JSON,
    IN  p_cov           JSON,
    IN  p_cardinality   INT,
    IN  p_alloc_table   VARCHAR(128),
    IN  p_alloc_emb_col VARCHAR(64),
    IN  p_baseline_vec  JSON,
    IN  p_seed          BIGINT,
    IN  p_context       TEXT,
    OUT p_result        JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_opt      TEXT;
    DECLARE v_sharpe    DOUBLE;
    DECLARE v_weights   JSON;
    DECLARE v_traj      TEXT;
    DECLARE v_alloc_id  VARCHAR(255);
    DECLARE v_dist       DOUBLE;
    DECLARE v_rationale  TEXT;
    DECLARE v_audit      BIGINT DEFAULT 0;

    IF p_alloc_table IS NULL OR p_alloc_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_rebalance_sibling: identifier arguments must not be NULL';
    END IF;

    SET v_opt = fractal_optimize_portfolio(p_mu, p_cov, p_cardinality,
        JSON_OBJECT('seed', IFNULL(p_seed, 0)));
    SET v_sharpe  = IFNULL(JSON_VALUE(v_opt, '$.sharpe'), 0.0);
    SET v_weights = JSON_EXTRACT(v_opt, '$.weights');

    CALL fractal_search_trajectory(p_alloc_table, p_alloc_emb_col, p_baseline_vec, v_weights, 1, v_traj);
    IF v_traj IS NULL OR JSON_LENGTH(v_traj) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_rebalance_sibling: no allocation rows found';
    END IF;
    SET v_alloc_id = JSON_VALUE(v_traj, '$[0].doc_id');
    SET v_dist      = JSON_VALUE(v_traj, '$[0].dist');

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Rebalance triage: the optimized portfolio has Sharpe ', v_sharpe,
               ' and is nearest to historical allocation id ', IFNULL(v_alloc_id, '?'),
               ' (cosine distance ', v_dist, '). Justify the rebalance in one sentence.'),
        IFNULL(p_context, '{}'));

    -- JSON_EXTRACT(v_weights, '$'): see Engine B's identical comment.
    SET v_audit = fractal_audit_log('agent_rebalance_sibling', JSON_OBJECT(
        'sharpe', v_sharpe, 'nearest_alloc_id', v_alloc_id,
        'nearest_distance', v_dist, 'rationale', v_rationale));

    SET p_result = JSON_OBJECT(
        'sharpe', v_sharpe, 'weights', JSON_EXTRACT(v_weights, '$'),
        'nearest_alloc_id', v_alloc_id, 'nearest_distance', v_dist, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine L: fractal_agent_detour_classify
-- fractal_search_trajectory + fractal_dimension_boxcount + reason.
-- =====================================================================
CREATE PROCEDURE fractal_agent_detour_classify(
    IN  p_vehicle_table VARCHAR(128),
    IN  p_emb_col       VARCHAR(64),
    IN  p_baseline_vec  JSON,
    IN  p_current_vec   JSON,
    IN  p_gps_trace     JSON,
    IN  p_boxcount_dim  INT,
    OUT p_result        JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_traj     TEXT;
    DECLARE v_fleet_id VARCHAR(255);
    DECLARE v_dist      DOUBLE;
    DECLARE v_bc         DOUBLE;
    DECLARE v_rationale  TEXT;
    DECLARE v_audit      BIGINT DEFAULT 0;

    IF p_vehicle_table IS NULL OR p_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_detour_classify: identifier arguments must not be NULL';
    END IF;

    CALL fractal_search_trajectory(p_vehicle_table, p_emb_col, p_baseline_vec, p_current_vec, 1, v_traj);
    IF v_traj IS NULL OR JSON_LENGTH(v_traj) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_detour_classify: no vehicle rows found';
    END IF;
    SET v_fleet_id = JSON_VALUE(v_traj, '$[0].doc_id');
    SET v_dist      = JSON_VALUE(v_traj, '$[0].dist');

    SET v_bc = fractal_dimension_boxcount(p_gps_trace, IFNULL(p_boxcount_dim, 2));

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Detour classify: vehicle ', IFNULL(v_fleet_id, '?'),
               ' deviates from its baseline by cosine distance ', v_dist,
               ' (nearest fleet peer); its GPS trace has box-counting dimension ', v_bc,
               '. Classify the detour in one sentence.'),
        JSON_OBJECT('trajectory_distance', v_dist, 'trace_complexity', v_bc));

    SET v_audit = fractal_audit_log('agent_detour_classify', JSON_OBJECT(
        'nearest_fleet_id', v_fleet_id, 'trajectory_distance', v_dist,
        'trace_complexity', v_bc, 'rationale', v_rationale));

    SET p_result = JSON_OBJECT(
        'nearest_fleet_id', v_fleet_id, 'trajectory_distance', v_dist,
        'trace_complexity', v_bc, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine M: fractal_agent_track_anomaly
-- fractal_search_trajectory + fractal_dimension_dfa + reason.
-- =====================================================================
CREATE PROCEDURE fractal_agent_track_anomaly(
    IN  p_track_table    VARCHAR(128),
    IN  p_emb_col        VARCHAR(64),
    IN  p_baseline_vec   JSON,
    IN  p_current_vec    JSON,
    IN  p_heading_series JSON,
    OUT p_result         JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_traj     TEXT;
    DECLARE v_track_id VARCHAR(255);
    DECLARE v_dist      DOUBLE;
    DECLARE v_dfa        DOUBLE;
    DECLARE v_rationale   TEXT;
    DECLARE v_audit       BIGINT DEFAULT 0;

    IF p_track_table IS NULL OR p_emb_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_track_anomaly: identifier arguments must not be NULL';
    END IF;

    CALL fractal_search_trajectory(p_track_table, p_emb_col, p_baseline_vec, p_current_vec, 1, v_traj);
    IF v_traj IS NULL OR JSON_LENGTH(v_traj) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_track_anomaly: no track rows found';
    END IF;
    SET v_track_id = JSON_VALUE(v_traj, '$[0].doc_id');
    SET v_dist      = JSON_VALUE(v_traj, '$[0].dist');

    SET v_dfa = fractal_dimension_dfa(p_heading_series);

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Track anomaly: vessel/host ', IFNULL(v_track_id, '?'),
               ' deviates from baseline by cosine distance ', v_dist,
               '; its heading-change series has DFA exponent ', v_dfa,
               ' (dfa=-1 means insufficient window). Triage the track in one sentence.'),
        JSON_OBJECT('trajectory_distance', v_dist, 'dfa_exponent', v_dfa));

    SET v_audit = fractal_audit_log('agent_track_anomaly', JSON_OBJECT(
        'nearest_fleet_id', v_track_id, 'trajectory_distance', v_dist,
        'dfa_exponent', v_dfa, 'rationale', v_rationale));

    SET p_result = JSON_OBJECT(
        'nearest_fleet_id', v_track_id, 'trajectory_distance', v_dist,
        'dfa_exponent', v_dfa, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine N: fractal_agent_network_coverage_alert
-- fractal_morphological_complexity + fractal_dimension_drift + reason.
-- No table args: pass the point cloud and drift series directly.
-- =====================================================================
CREATE PROCEDURE fractal_agent_network_coverage_alert(
    IN  p_point_cloud     JSON,
    IN  p_drift_series    JSON,
    IN  p_boxcount_dim    INT,
    IN  p_drift_win       INT,
    IN  p_drift_threshold DOUBLE,
    IN  p_context         TEXT,
    OUT p_result          JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_morph    TEXT;
    DECLARE v_drift     TEXT;
    DECLARE v_md         DOUBLE;
    DECLARE v_lac         DOUBLE;
    DECLARE v_dv           DOUBLE;
    DECLARE v_dd            BOOLEAN;
    DECLARE v_threshold      DOUBLE DEFAULT IFNULL(p_drift_threshold, 0.5);
    DECLARE v_rationale       TEXT;
    DECLARE v_audit           BIGINT DEFAULT 0;

    IF p_point_cloud IS NULL OR p_drift_series IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_network_coverage_alert: point_cloud and drift_series are required';
    END IF;

    SET v_morph = fractal_morphological_complexity(p_point_cloud, IFNULL(p_boxcount_dim, 2));
    SET v_md = IFNULL(JSON_VALUE(v_morph, '$.dimension'), 0.0);
    SET v_lac = IFNULL(JSON_VALUE(v_morph, '$.lacunarity'), 0.0);

    SET v_drift = fractal_dimension_drift(p_drift_series, IFNULL(p_drift_win, 48));
    SET v_dv = IFNULL(JSON_VALUE(v_drift, '$.drift'), 0.0);
    SET v_dd = (ABS(v_dv) > v_threshold);

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Network coverage alert: the sensor grid has morphological dimension ', v_md,
               ' and lacunarity ', v_lac, '; the telemetry drift is ', v_dv,
               ' (drift_detected=', v_dd, ', threshold ', v_threshold, '). ',
               'Issue the coverage alert in one sentence.'),
        IFNULL(p_context, '{}'));

    SET v_audit = fractal_audit_log('agent_network_coverage_alert', JSON_OBJECT(
        'morph_dimension', v_md, 'lacunarity', v_lac,
        'drift_detected', v_dd, 'rationale', v_rationale));

    SET p_result = JSON_OBJECT(
        'morph_dimension', v_md, 'lacunarity', v_lac,
        'drift_detected', v_dd, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine O: fractal_agent_regime_triage (general-purpose)
-- fractal_dimension_dfa + fractal_dimension_drift + reason. No table
-- args: fits any single series.
-- =====================================================================
CREATE PROCEDURE fractal_agent_regime_triage(
    IN  p_series          JSON,
    IN  p_win             INT,
    IN  p_drift_threshold DOUBLE,
    IN  p_context         TEXT,
    OUT p_result          JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_dfa      DOUBLE;
    DECLARE v_drift     TEXT;
    DECLARE v_dv         DOUBLE;
    DECLARE v_dd          BOOLEAN;
    DECLARE v_ra           DOUBLE;
    DECLARE v_ba            DOUBLE;
    DECLARE v_threshold      DOUBLE DEFAULT IFNULL(p_drift_threshold, 0.5);
    DECLARE v_rationale       TEXT;
    DECLARE v_audit           BIGINT DEFAULT 0;

    IF p_series IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_regime_triage: series is required';
    END IF;

    SET v_dfa = fractal_dimension_dfa(p_series);
    SET v_drift = fractal_dimension_drift(p_series, IFNULL(p_win, 64));
    SET v_dv = IFNULL(JSON_VALUE(v_drift, '$.drift'), 0.0);
    SET v_dd = (ABS(v_dv) > v_threshold);
    SET v_ra = IFNULL(JSON_VALUE(v_drift, '$.recent_alpha'), 0.0);
    SET v_ba = IFNULL(JSON_VALUE(v_drift, '$.baseline_alpha'), 0.0);

    SET v_rationale = fractal_reason(v_session_id,
        CONCAT('Regime triage: the series has DFA exponent ', v_dfa,
               ' and drift ', v_dv, ' (drift_detected=', v_dd, ', recent_alpha=', v_ra,
               ', baseline_alpha=', v_ba, '). Triage the regime change in one sentence.'),
        IFNULL(p_context, '{}'));

    SET v_audit = fractal_audit_log('agent_regime_triage', JSON_OBJECT(
        'dfa_exponent', v_dfa, 'drift_detected', v_dd, 'drift', v_dv,
        'rationale', v_rationale));

    SET p_result = JSON_OBJECT(
        'dfa_exponent', v_dfa, 'drift_detected', v_dd,
        'recent_alpha', v_ra, 'baseline_alpha', v_ba, 'rationale', v_rationale);
END$$

-- =====================================================================
-- Engine P: fractal_agent_diverse_portfolios
-- fractal_optimize_portfolio_multimodal(_pareto) + fractal_reason. Same
-- composition shape as Engine B (fractal_agent_allocate), but returns a
-- diverse SET of candidate allocations instead of one, and narrates the
-- trade-offs across them. p_objective_mode selects the objective:
-- 'sharpe' (default, NULL accepted) ranks candidates by scalar Sharpe
-- with asset-overlap diversity; 'pareto' scores each by decomposed
-- (return, risk) and reduces them to a genuine non-dominated Pareto
-- front. Enterprise-tier: both backing functions return NULL when no
-- enterprise library is loaded, in which case this procedure signals a
-- clean error rather than passing a NULL straight to fractal_reason as
-- if it were real data.
-- =====================================================================
CREATE PROCEDURE fractal_agent_diverse_portfolios(
    IN  p_mu                JSON,
    IN  p_cov                JSON,
    IN  p_cardinality        INT,
    IN  p_n_restarts         INT,
    IN  p_overlap_threshold  DOUBLE,
    IN  p_quality_frac       DOUBLE,
    IN  p_context            TEXT,
    IN  p_objective_mode     TEXT,
    OUT p_result             JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_opt      TEXT;
    DECLARE v_n_found   INT;
    DECLARE v_reasoning TEXT;
    DECLARE v_mode      TEXT;
    DECLARE v_audit     BIGINT DEFAULT 0;

    SET v_mode = LOWER(IFNULL(p_objective_mode, 'sharpe'));
    IF v_mode NOT IN ('sharpe', 'pareto') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_agent_diverse_portfolios: objective_mode must be ''sharpe'' or ''pareto''';
    END IF;

    IF v_mode = 'pareto' THEN
        SET v_opt = fractal_optimize_portfolio_multimodal_pareto(
            p_mu, p_cov, p_cardinality,
            IFNULL(p_n_restarts, 8),
            8,                        -- max_front cap on the returned front
            0, 0, 'gaussian');        -- seed / use_obl / diffusion_mode
        IF v_opt IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
                'fractal_agent_diverse_portfolios: enterprise tier not loaded (fractal_optimize_portfolio_multimodal_pareto returned NULL) -- set FRACTALSQL_ENTERPRISE_LIB and restart, see docs/enterprise.md';
        END IF;

        SET v_n_found = IFNULL(JSON_VALUE(v_opt, '$.n_found'), 0);
        SET v_reasoning = fractal_reason(v_session_id,
            CONCAT('Explain the trade-offs across these ', v_n_found,
                   ' diverse cardinality-constrained portfolio candidates on the non-dominated return/risk Pareto front: ', v_opt),
            IFNULL(p_context, '{}'));
    ELSE
        SET v_opt = fractal_optimize_portfolio_multimodal(
            p_mu, p_cov, p_cardinality,
            IFNULL(p_n_restarts, 8),
            IFNULL(p_overlap_threshold, 0.3),
            IFNULL(p_quality_frac, 0.8),
            0);

        IF v_opt IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
                'fractal_agent_diverse_portfolios: enterprise tier not loaded (fractal_optimize_portfolio_multimodal returned NULL) -- set FRACTALSQL_ENTERPRISE_LIB and restart, see docs/enterprise.md';
        END IF;

        SET v_n_found = IFNULL(JSON_VALUE(v_opt, '$.n_found'), 0);
        SET v_reasoning = fractal_reason(v_session_id,
            CONCAT('Explain the trade-offs across these ', v_n_found,
                   ' diverse cardinality-constrained portfolio candidates, ranked by Sharpe: ', v_opt),
            IFNULL(p_context, '{}'));
    END IF;

    SET v_audit = fractal_audit_log('agent_diverse_portfolios', JSON_OBJECT(
        'objective_mode', v_mode, 'n_found', v_n_found,
        'cardinality', p_cardinality, 'rationale', v_reasoning));

    -- v_opt is the full {"n_found":..,"candidates":[..]} object, nested
    -- under 'optimization' rather than 'candidates' to avoid a
    -- misleading key name. Same JSON_EXTRACT(v_opt, '$') convention as
    -- Engine B above -- see that procedure's own comment for why
    -- CAST(v_opt AS CHAR) does not nest v_opt as a real JSON sub-object
    -- here.
    SET p_result = JSON_OBJECT('optimization', JSON_EXTRACT(v_opt, '$'), 'rationale', v_reasoning);
END$$

-- =====================================================================
-- fractal_agent_trajectory_predict
-- Composed as a stored PROCEDURE rather than a C function: resolving
-- a table's primary key or reading rows needs SQL execution against
-- the calling session, which a MariaDB C UDF cannot do, so this lands
-- here as a composition instead, the same "capability gap ->
-- composition" move this whole file already makes for every other
-- agent.
--
-- Resolves table_name's PK, reads the baseline row (PK = baseline_id)
-- and the current row (max PK), computes delta = current - baseline,
-- scans the whole table as a corpus, and searches it for the single
-- nearest point to delta: the same two-step "resolve PK -> search the
-- delta against the whole table" fractal_search_trajectory (above,
-- this file) already implements as a primitive, plus baseline_id/
-- current-row resolution (fractal_search_trajectory takes explicit
-- baseline/current vectors, not a baseline_id to look up) and a
-- join-back from the winning doc_id to its stored vector (same
-- technique Engine E's content_col join uses), so the result carries
-- predicted_state_vector, projected_drift_delta, and
-- risk_threshold_exceeded together.
--
-- p_risk_threshold: defaults to 0.5 (IFNULL'd when NULL is passed),
-- exposed as an optional argument rather than hardcoded.
--
-- p_forecast_steps: accepted for signature symmetry with
-- fractal_agent_trajectory_predict(table_name, vector_col, baseline_id,
-- forecast_steps) but not currently used in the computation. Flagging
-- this rather than silently dropping the parameter, in case a future
-- revision starts using it.
-- =====================================================================
CREATE PROCEDURE fractal_agent_trajectory_predict(
    IN  p_table          VARCHAR(128),
    IN  p_vec_col        VARCHAR(64),
    IN  p_baseline_id    BIGINT,
    IN  p_forecast_steps INT,
    IN  p_risk_threshold DOUBLE,
    OUT p_result         JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_pk_col        VARCHAR(64);
    DECLARE v_pk_count      INT DEFAULT 0;
    DECLARE v_type          VARCHAR(64);
    DECLARE v_is_vec        BOOLEAN;
    DECLARE v_col_expr      TEXT;
    DECLARE v_baseline_vec  JSON;
    DECLARE v_current_vec   JSON;
    DECLARE v_traj          TEXT;
    DECLARE v_predicted_id  VARCHAR(255);
    DECLARE v_predicted_vec JSON;
    DECLARE v_drift         DOUBLE;
    DECLARE v_threshold     DOUBLE DEFAULT IFNULL(p_risk_threshold, 0.5);

    IF p_table IS NULL OR p_vec_col IS NULL OR p_baseline_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_trajectory_predict: table, vector_col and baseline_id must not be NULL';
    END IF;

    SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table AND constraint_name = 'PRIMARY';
    IF v_pk_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_trajectory_predict: table must have exactly one single-column PRIMARY KEY';
    END IF;
    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table AND constraint_name = 'PRIMARY' LIMIT 1;

    -- Same native-VECTOR(n) detection as _fractalsql_scan_corpus (sql/
    -- install_udf.sql, above): a plain SELECT of a VECTOR column returns
    -- its raw binary representation, not JSON-compatible text, so it
    -- must be read through VEC_TOTEXT() whenever vec_col is that type.
    SELECT MIN(data_type) INTO v_type FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_table AND column_name = p_vec_col;
    IF v_type IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_trajectory_predict: vector_col not found on table';
    END IF;
    SET v_is_vec = (LOWER(v_type) = 'vector');
    SET v_col_expr = IF(v_is_vec,
        CONCAT('VEC_TOTEXT(', _fractalsql_quote_ident(p_vec_col), ')'),
        _fractalsql_quote_ident(p_vec_col));

    SET @_fractalsql_tp_sql = CONCAT(
        'SELECT ', v_col_expr, ' INTO @_fractalsql_tp_baseline FROM ',
        _fractalsql_quote_ident(p_table), ' WHERE ', _fractalsql_quote_ident(v_pk_col), ' = ', p_baseline_id);
    SET @_fractalsql_tp_baseline = NULL;
    PREPARE _fractalsql_tp_stmt FROM @_fractalsql_tp_sql;
    EXECUTE _fractalsql_tp_stmt;
    DEALLOCATE PREPARE _fractalsql_tp_stmt;
    SET v_baseline_vec = @_fractalsql_tp_baseline;

    IF v_baseline_vec IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_trajectory_predict: no row with the given baseline_id, or its vector is NULL';
    END IF;

    SET @_fractalsql_tp_sql2 = CONCAT(
        'SELECT ', v_col_expr, ' INTO @_fractalsql_tp_current FROM ',
        _fractalsql_quote_ident(p_table), ' ORDER BY ', _fractalsql_quote_ident(v_pk_col), ' DESC LIMIT 1');
    SET @_fractalsql_tp_current = NULL;
    PREPARE _fractalsql_tp_stmt2 FROM @_fractalsql_tp_sql2;
    EXECUTE _fractalsql_tp_stmt2;
    DEALLOCATE PREPARE _fractalsql_tp_stmt2;
    SET v_current_vec = @_fractalsql_tp_current;

    IF v_current_vec IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_trajectory_predict: table has no rows, or its vector is NULL';
    END IF;

    CALL fractal_search_trajectory(p_table, p_vec_col, v_baseline_vec, v_current_vec, 1, v_traj);
    IF v_traj IS NULL OR JSON_LENGTH(v_traj) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_trajectory_predict: no predicted state found';
    END IF;
    SET v_predicted_id = JSON_VALUE(v_traj, '$[0].doc_id');
    SET v_drift         = JSON_VALUE(v_traj, '$[0].dist');

    SET @_fractalsql_tp_sql3 = CONCAT(
        'SELECT ', v_col_expr, ' INTO @_fractalsql_tp_predicted FROM ',
        _fractalsql_quote_ident(p_table), ' WHERE ', _fractalsql_quote_ident(v_pk_col), ' = ', QUOTE(v_predicted_id));
    SET @_fractalsql_tp_predicted = NULL;
    PREPARE _fractalsql_tp_stmt3 FROM @_fractalsql_tp_sql3;
    EXECUTE _fractalsql_tp_stmt3;
    DEALLOCATE PREPARE _fractalsql_tp_stmt3;
    SET v_predicted_vec = @_fractalsql_tp_predicted;

    -- JSON_EXTRACT(..., '$'): see Engine B's identical comment, above.
    SET p_result = JSON_OBJECT(
        'predicted_state_vector', JSON_EXTRACT(IFNULL(v_predicted_vec, JSON_ARRAY()), '$'),
        'projected_drift_delta', v_drift,
        'risk_threshold_exceeded', (v_drift > v_threshold));
END$$

-- fractal_search_agent(query, table_name, vector_col, pop_size, iterations, OUT result)
-- Embed the query, Scout-search a caller-named table's vector column
-- for the top pop_size nearest rows, reason over the MATCHED ROWS'
-- CONTENT (never the raw vectors -- an LLM should never see a raw
-- embedding array, and it's useless to it anyway; see
-- _fractalsql_fetch_row_context's own header comment,
-- sql/install_udf.sql), return the answer plus which rows fed it.
-- execution_time_ms is a real wall-clock measurement (SYSDATE(6)
-- start/end).
CREATE PROCEDURE fractal_search_agent(
    IN  p_query       TEXT,
    IN  p_table_name  VARCHAR(128),
    IN  p_vector_col  VARCHAR(64),
    IN  p_pop_size    INT,
    IN  p_iterations  INT,
    OUT p_result      JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_query_vec  JSON;
    DECLARE v_corpus     JSON;
    DECLARE v_ids        JSON;
    DECLARE v_k          INT DEFAULT IFNULL(p_pop_size, 50);
    DECLARE v_topk       JSON;
    DECLARE v_doc_ids    JSON;
    DECLARE v_context    JSON;
    DECLARE v_answer     TEXT;
    DECLARE v_started    DATETIME(6);

    -- p_iterations is accepted for signature symmetry, but
    -- _fractalsql_telemetry_topk (the shared search core every
    -- table-backed composition in this repo already goes through)
    -- hardcodes max_generation=15 itself, same as
    -- fractal_search_telemetry/_hybrid_clinical_search/_search_trajectory.
    IF p_query IS NULL OR p_table_name IS NULL OR p_vector_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_search_agent: query, table_name and vector_col must not be NULL';
    END IF;
    SET v_started = SYSDATE(6);

    SET v_query_vec = fractal_embed(v_session_id, p_query);
    IF v_query_vec IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_search_agent: embedding failed';
    END IF;

    CALL _fractalsql_scan_corpus(p_table_name, p_vector_col, v_corpus, v_ids);
    CALL _fractalsql_telemetry_topk(v_corpus, v_ids, v_query_vec, v_k, v_topk);

    SET v_doc_ids = IFNULL(JSON_EXTRACT(v_topk, '$[*].doc_id'), JSON_ARRAY());
    CALL _fractalsql_fetch_row_context(p_table_name, p_vector_col, v_doc_ids, v_context);

    SET v_answer = fractal_reason(v_session_id, p_query, v_context);

    SET p_result = JSON_OBJECT(
        'answer', v_answer,
        'source_doc_ids', JSON_EXTRACT(v_doc_ids, '$'),
        'execution_time_ms', TIMESTAMPDIFF(MICROSECOND, v_started, SYSDATE(6)) / 1000.0);
END$$

-- fractal_rag_agent(query, table_name, vector_col, meta_filter, OUT answer)
-- Same embed -> scan -> Scout search -> content-refetch -> reason
-- pipeline as fractal_search_agent above, with pop_size=50/
-- iterations=15 hardcoded instead of caller-configurable, returning
-- only the answer text (not source_doc_ids/execution_time_ms).
-- Implemented as a thin wrapper around fractal_search_agent rather
-- than a second copy of the same pipeline. p_meta_filter is accepted
-- for future use but currently UNUSED: reserved for a future WHERE
-- clause; for now the whole corpus is scanned.
CREATE PROCEDURE fractal_rag_agent(
    IN  p_query        TEXT,
    IN  p_table_name   VARCHAR(128),
    IN  p_vector_col   VARCHAR(64),
    IN  p_meta_filter  JSON,
    OUT p_answer       TEXT
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_result JSON;
    CALL fractal_search_agent(p_query, p_table_name, p_vector_col, 50, 15, v_result);
    SET p_answer = JSON_UNQUOTE(JSON_EXTRACT(v_result, '$.answer'));
END$$

-- fractal_agent_plan_explore(initial_state, strategy_table, vector_col, max_branches, OUT result)
-- Embed initial_state, Scout-search a caller-named
-- strategy_table/vector_col corpus for max_branches candidate
-- branches, return each branch's own matched-row id, its OWN vector
-- (the branch's plan_trajectory -- NOT the query vector; each branch
-- is a distinct corpus row exploring a distinct strategy), and score =
-- 1 - distance. MariaDB has no set-returning UDFs and this extension's
-- own house convention is OUT-JSON, not RETURNS TABLE (see this file's
-- own header comment, point 3), so the branches come back as a JSON
-- array in p_result rather than a multi-row result set.
CREATE PROCEDURE fractal_agent_plan_explore(
    IN  p_initial_state   TEXT,
    IN  p_strategy_table  VARCHAR(128),
    IN  p_vector_col      VARCHAR(64),
    IN  p_max_branches    INT,
    OUT p_result          JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_session_id BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_query_vec  JSON;
    DECLARE v_corpus     JSON;
    DECLARE v_ids        JSON;
    DECLARE v_k          INT DEFAULT IFNULL(p_max_branches, 10);
    DECLARE v_topk       JSON;
    DECLARE v_pk_col     VARCHAR(64);
    DECLARE v_type       VARCHAR(64);
    DECLARE v_is_vec     BOOLEAN;
    DECLARE v_col_expr   TEXT;
    DECLARE v_branches   JSON DEFAULT JSON_ARRAY();
    DECLARE v_n          INT DEFAULT 0;
    DECLARE v_i          INT DEFAULT 0;
    DECLARE v_doc_id     JSON;
    DECLARE v_dist       DOUBLE;
    DECLARE v_vec        JSON;

    IF p_initial_state IS NULL OR p_strategy_table IS NULL OR p_vector_col IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_plan_explore: initial_state, strategy_table and vector_col must not be NULL';
    END IF;

    SET v_query_vec = fractal_embed(v_session_id, p_initial_state);
    IF v_query_vec IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_plan_explore: embedding failed';
    END IF;

    CALL _fractalsql_scan_corpus(p_strategy_table, p_vector_col, v_corpus, v_ids);
    CALL _fractalsql_telemetry_topk(v_corpus, v_ids, v_query_vec, v_k, v_topk);

    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_strategy_table AND constraint_name = 'PRIMARY' LIMIT 1;
    SELECT MIN(data_type) INTO v_type FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_strategy_table AND column_name = p_vector_col;
    SET v_is_vec = (LOWER(v_type) = 'vector');
    SET v_col_expr = IF(v_is_vec,
        CONCAT('VEC_TOTEXT(', _fractalsql_quote_ident(p_vector_col), ')'),
        _fractalsql_quote_ident(p_vector_col));

    SET v_n = JSON_LENGTH(v_topk);
    WHILE v_i < v_n DO
        SET v_doc_id = JSON_EXTRACT(v_topk, CONCAT('$[', v_i, '].doc_id'));
        SET v_dist   = JSON_VALUE(v_topk, CONCAT('$[', v_i, '].dist'));

        SET @_fractalsql_pe_sql = CONCAT(
            'SELECT ', v_col_expr, ' INTO @_fractalsql_pe_vec FROM ',
            _fractalsql_quote_ident(p_strategy_table), ' WHERE ', _fractalsql_quote_ident(v_pk_col),
            ' = ', QUOTE(JSON_UNQUOTE(v_doc_id)));
        SET @_fractalsql_pe_vec = NULL;
        PREPARE _fractalsql_pe_stmt FROM @_fractalsql_pe_sql;
        EXECUTE _fractalsql_pe_stmt;
        DEALLOCATE PREPARE _fractalsql_pe_stmt;
        SET v_vec = @_fractalsql_pe_vec;

        -- JSON_MERGE_PRESERVE of two real JSON arrays concatenates
        -- elements by JSON semantics, not text munging -- see
        -- _fractalsql_scan_corpus's comment (sql/install_udf.sql) on why
        -- naive string concatenation of JSON fragments is unsafe here.
        SET v_branches = JSON_MERGE_PRESERVE(v_branches, JSON_ARRAY(JSON_OBJECT(
            'doc_id', JSON_EXTRACT(v_doc_id, '$'),
            'plan_trajectory', JSON_EXTRACT(IFNULL(v_vec, JSON_ARRAY()), '$'),
            'score', 1.0 - v_dist)));
        SET v_i = v_i + 1;
    END WHILE;

    SET p_result = v_branches;
END$$

-- fractal_agent_detect_loop(log_hashes, OUT result)
-- A pure numeric function, no table access at all (unlike the four
-- table-backed Universal Agent procedures above, this one needs no
-- dynamic SQL). log_hashes is a JSON array of integer state hashes
-- (e.g. a session/action log). Flags a loop if EITHER the DFA scaling
-- exponent exceeds 0.9 (drift-to-chaos / random-walk-like cycling, via
-- the existing fractal_dimension_dfa UDF) OR a tight discrete
-- repetition period is found (clean toggles like 12345<->67890 that
-- DFA scores as low alpha). Period search is capped at n/4.
CREATE PROCEDURE fractal_agent_detect_loop(
    IN  p_log_hashes  JSON,
    OUT p_result      JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_n      INT;
    DECLARE v_series TEXT DEFAULT '';
    DECLARE v_i      INT DEFAULT 0;
    DECLARE v_alpha  DOUBLE;
    DECLARE v_max_p  INT;
    DECLARE v_period INT DEFAULT 0;
    DECLARE v_p      INT DEFAULT 1;
    DECLARE v_ok     BOOLEAN;
    DECLARE v_j      INT;

    IF p_log_hashes IS NULL OR JSON_LENGTH(p_log_hashes) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_agent_detect_loop: log_hashes must be a non-empty JSON array';
    END IF;
    SET v_n = JSON_LENGTH(p_log_hashes);

    WHILE v_i < v_n DO
        IF v_i > 0 THEN
            SET v_series = CONCAT(v_series, ',');
        END IF;
        SET v_series = CONCAT(v_series, CAST(JSON_VALUE(p_log_hashes, CONCAT('$[', v_i, ']')) AS CHAR));
        SET v_i = v_i + 1;
    END WHILE;

    SET v_alpha = fractal_dimension_dfa(v_series);

    SET v_max_p = v_n DIV 4;
    WHILE v_p <= v_max_p AND v_period = 0 DO
        SET v_ok = TRUE;
        SET v_j = 0;
        WHILE v_j < v_n - v_p AND v_ok DO
            IF JSON_VALUE(p_log_hashes, CONCAT('$[', v_j, ']')) <> JSON_VALUE(p_log_hashes, CONCAT('$[', v_j + v_p, ']')) THEN
                SET v_ok = FALSE;
            END IF;
            SET v_j = v_j + 1;
        END WHILE;
        IF v_ok THEN
            SET v_period = v_p;
        END IF;
        SET v_p = v_p + 1;
    END WHILE;

    SET p_result = JSON_OBJECT(
        'recommendation', 'monitor',
        'dfa_exponent', v_alpha,
        'loop_detected', (v_alpha > 0.9 OR v_period > 0));
END$$

DELIMITER ;

-- Verify installation:
--   SELECT ROUTINE_NAME FROM information_schema.routines
--    WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME LIKE 'fractal_agent_%';
--
-- Example (Engine O, no table args needed):
--   SET @series = '[1,2,1,3,2,4,3,5,4,6,5,7,6,8,7,9,8,10,9,11,10,12,11,13,12,14,13,15,14,16,15,17,16,18,17,19,18,20,19,21,20,22,21,23,22,24,23,25,24,26,25,27,26,28,27,29,28,30,29,31,30,32]';
--   CALL fractal_agent_regime_triage(@series, 32, 0.5, '{}', @result);
--   SELECT @result;
