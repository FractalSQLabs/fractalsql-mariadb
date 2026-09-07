-- demo/response-modes.sql
--
-- FractalSQL reasoning response shapes: plain text, and fenced-code
-- extraction.
--
-- This extension's response-shape story, checked directly in
-- src/fractalsql_cognition.c and src/fractalsql_textsql.c:
--   - fractal_reason() ALWAYS unsets FSQL_REASONING_HTTP_RESPONSE_MODE
--     before dispatching (apply_reason_env_locked): there is no
--     per-call or per-session way to put fractal_reason() itself into
--     a fenced-extraction mode. It only ever returns raw model text.
--   - Fenced-code extraction (RESPONSE_MODE=code) is set internally by
--     fractal_t2s_generate() ONLY (apply_generate_env_locked,
--     src/fractalsql_textsql.c), not exposed as a general "response
--     mode" callers can opt into for arbitrary prompts. Section 2
--     below demonstrates it through fractal_t2s_generate() directly
--     instead, which is the only function that actually has this
--     behavior.
--   - There is no "json" mode anywhere in this extension's C source.
--     Section 3 is reframed as prompt-level JSON (ask for JSON,
--     validate the reply client-side with JSON_VALID()) rather than a
--     server-side mode, which is the only way to get JSON output from
--     fractal_reason() here.
-- No mariadbd restart is needed for anything below: none of this needs
-- FSQL_REASONING_HTTP_RESPONSE_MODE touched from the outside at all.
--
-- Prerequisites:
--   1. Run demo.sql first, this reuses its demo_alerts table.
--   2. Reasoning configured as process environment variables in
--      mariadbd's own environment (MariaDB has no live-reloadable
--      config mechanism a dlopen'd UDF library can hook into); see
--      docs/reasoning-setup.md and build_test.sh's mdb_setup.

-- ============================================================
-- Plain text: raw model output, unchanged. This is what demo.sql and
-- every other fractal_reason() example in this repo already uses.
-- ============================================================

SELECT fractal_reason(
    CONNECTION_ID(),
    'summarize what happened in demo_alerts in one sentence',
    (SELECT JSON_ARRAYAGG(JSON_OBJECT(
                'service', service, 'message', message,
                'severity', severity, 'created_at', created_at))
       FROM demo_alerts)
);

-- ============================================================
-- Fenced-code extraction: fractal_t2s_generate() ONLY (see header),
-- not fractal_reason(). The plugin auto-appends an instruction telling
-- the model to answer with a single fenced code block, then strips the
-- fence markers on extraction. Expect back a bare SQL statement, no
-- "Here's a query that does that:" preamble, no explanation, no
-- visible ``` markers. This is exactly the GENERATE step
-- fractal_text_to_sql() itself calls internally; demonstrated directly
-- here rather than through the full pipeline.
-- ============================================================

SELECT fractal_t2s_generate(
    CONNECTION_ID(),
    'write a SQL query that selects all rows from demo_alerts where severity is critical',
    'Schema: demo_alerts(id INT AUTO_INCREMENT PK, service VARCHAR, message TEXT, severity VARCHAR, created_at TIMESTAMP).',
    NULL
);

-- ============================================================
-- JSON output: no server-side "json mode" exists in this extension
-- (see header), this is plain fractal_reason() with a prompt that ASKS
-- for JSON, validated client-side with JSON_VALID(). Unlike the fenced-
-- code path above, nothing strips markdown fencing here, so a model
-- that wraps its JSON in ```json ... ``` will fail JSON_VALID(), and
-- that's a real, expected outcome this demo surfaces, not a bug to
-- work around: MariaDB's own JSON_VALID() catches invalid JSON here
-- instead of silently accepting bad output.
-- ============================================================

SELECT
    fractal_reason(
        CONNECTION_ID(),
        'return ONLY a raw JSON object (no markdown fencing, no explanation) with keys critical_count, warning_count, and info_count summarizing the severities present',
        (SELECT JSON_ARRAYAGG(JSON_OBJECT('severity', severity)) FROM demo_alerts)
    ) AS reply,
    JSON_VALID(fractal_reason(
        CONNECTION_ID(),
        'return ONLY a raw JSON object (no markdown fencing, no explanation) with keys critical_count, warning_count, and info_count summarizing the severities present',
        (SELECT JSON_ARRAYAGG(JSON_OBJECT('severity', severity)) FROM demo_alerts)
    )) AS reply_is_valid_json;
