-- demo/text-to-sql-spike-1-generate.sql
--
-- Part 1 of 4 of the text-to-sql validation spike (see -2-review.sql,
-- -3-validate.sql, -4-negative-control.sql for the rest).
--
-- FRACTALSQL_HTTP_MODEL (and FRACTALSQL_REASONING_PLUGIN / HTTP_URL /
-- HTTP_ALLOW_PLAINTEXT) are process environment variables read ONCE by
-- mariadbd at first use and cached for that process's entire lifetime
-- (src/fractalsql_textsql.c's ensure_env_config, pthread_once). There
-- is NO SQL statement, GUC, or sysvar that changes which model answers
-- a query. This file tests exactly ONE model: whichever
-- FRACTALSQL_HTTP_MODEL the CURRENTLY RUNNING mariadbd was started
-- with. To compare multiple models, restart mariadbd with a different
-- FRACTALSQL_HTTP_MODEL and re-run this whole spike from Part 1. See
-- build_test.sh's mdb_setup for the export pattern this expects
-- already in place before mariadbd starts.
--
-- Prerequisites: reasoning configured (FRACTALSQL_REASONING_PLUGIN /
-- HTTP_URL / HTTP_MODEL / HTTP_ALLOW_PLAINTEXT exported before
-- mariadbd started), demo_alerts table present (run demo.sql first if
-- you haven't).
--
-- Uses fractal_t2s_generate() directly, not fractal_reason(), since
-- fractal_reason is the general Cognition-tier chat function while
-- fractal_t2s_generate is the actual GENERATE step of the Text-to-SQL
-- pipeline: it sets RESPONSE_MODE=code internally so the fenced ```sql
-- block gets extracted automatically, no separate response-mode env
-- var or restart needed.

DROP TABLE IF EXISTS spike_candidates;
CREATE TABLE spike_candidates (
    model    VARCHAR(64) PRIMARY KEY,
    sql_text TEXT,
    review   TEXT
);

-- No SQL-level way to read back FRACTALSQL_HTTP_MODEL's value.
-- fractal_t2s_config() reports max_attempts/allowed_statements/
-- use_review only, not the model name (src/fractalsql_textsql.c). The
-- label below is just a run marker for this table's PRIMARY KEY, not
-- a real introspection of which model answered; know that from
-- however you set FRACTALSQL_HTTP_MODEL for this mariadbd process.
INSERT INTO spike_candidates (model, sql_text) VALUES (
    CONCAT('run @ ', NOW()),
    fractal_t2s_generate(
        CONNECTION_ID(),
        'Write a single MariaDB SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, wrapped in a ```sql fenced code block.',
        'Schema: demo_alerts(id INT AUTO_INCREMENT PK, service VARCHAR, message TEXT, severity VARCHAR CHECK IN (''info'',''warning'',''critical''), created_at TIMESTAMP). No foreign keys, this is the only table.',
        NULL
    )
);

SELECT model, sql_text FROM spike_candidates;

-- Next: run demo/text-to-sql-spike-2-review.sql (no restart needed --
-- fractal_t2s_review() manages its own RESPONSE_MODE internally, same
-- process, same reasoning plugin already loaded).
