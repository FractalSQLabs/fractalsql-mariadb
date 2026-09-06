-- demo/text-to-sql-spike-2-review.sql
--
-- Part 2 of 4 of the text-to-sql validation spike. Requires Part 1 to
-- have already run (reads from spike_candidates).
--
-- See text-to-sql-spike-1-generate.sql's header for why this spike
-- tests one model per mariadbd process rather than comparing several
-- in a single run. No restart needed here: fractal_t2s_review()
-- manages its own RESPONSE_MODE internally (plain chat, not the
-- code-fence extraction GENERATE uses), the same process and the same
-- already-loaded reasoning plugin as Part 1.

UPDATE spike_candidates SET review = fractal_t2s_review(
    CONNECTION_ID(),
    'For each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.',
    sql_text
);

SELECT model, review FROM spike_candidates;

-- fractal_t2s_review()'s verdict convention: NULL = PASS, non-NULL =
-- FAIL (the string IS the rejection reason), the same convention
-- fractal_t2s_check_allowlist() uses (sql/install_udf.sql). The column
-- above will show NULL for a candidate review approved, not literal
-- text "PASS".

-- Next: run demo/text-to-sql-spike-3-validate.sql (no restart needed).
