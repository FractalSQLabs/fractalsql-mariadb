-- demo/text-to-sql-spike-4-negative-control.sql
--
-- Part 4 of 4: negative control for the review step. Does
-- fractal_t2s_review() correctly FAIL (non-NULL) a deliberately WRONG
-- candidate, or does it rubber-stamp anything? Parts 1-3 only proved
-- review passes GOOD SQL, this is the harder, more valuable check.
--
-- See text-to-sql-spike-1-generate.sql's header for why this spike
-- tests one model per mariadbd process. No restart needed here.
--
-- The wrong candidate is the SAME query as the correct answer with the
-- critical-only filter simply removed: syntactically perfect SQL
-- that answers a DIFFERENT, wrong question (includes payments and
-- auth-service, which have no critical alerts and should be excluded).

DROP TABLE IF EXISTS spike_negative_control;
CREATE TABLE spike_negative_control (
    id       INT PRIMARY KEY AUTO_INCREMENT,
    sql_text TEXT,
    review   TEXT
);

INSERT INTO spike_negative_control (sql_text) VALUES
    ('SELECT service, severity, COUNT(*) FROM demo_alerts GROUP BY service, severity;');

-- === What the wrong candidate actually produces (for reference) ===
SELECT service, severity, COUNT(*) AS n
FROM demo_alerts GROUP BY service, severity ORDER BY service, severity;
-- Note payments and auth-service present, that is the bug review should catch.

-- === REVIEW (wrong candidate) ===
UPDATE spike_negative_control SET review = fractal_t2s_review(
    CONNECTION_ID(),
    'For each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.',
    sql_text
);

SELECT id, review FROM spike_negative_control;

-- Interpretation (review's convention: NULL = PASS, non-NULL text = FAIL):
--   - non-NULL, correctly citing the missing critical-only filter ->
--     review is discriminating, not rubber-stamping. Strong signal.
--   - NULL (PASS) on this obviously-wrong candidate -> review is not
--     reliable for this model/prompt, do not depend on it as a real
--     gate (fractal_text_to_sql defaults use_review=FALSE precisely
--     because this isn't guaranteed reliable across models).
--
-- Clean up: DROP TABLE spike_negative_control;
-- (spike_candidates from parts 1-3 is untouched by this file.)
