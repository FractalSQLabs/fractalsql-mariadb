-- demo/text-to-sql-spike-3-validate.sql
--
-- Part 3 of 4 of the text-to-sql validation spike. Requires Parts 1
-- and 2 to have already run. No mode dependency, no restart needed.
--
-- REWRITTEN 2026-08-30 -- see text-to-sql-spike-1-generate.sql's
-- header for the single-model-per-process constraint (Open Decision
-- D1) this spike now reflects throughout.
--
-- Correct result: exactly 2 rows in the EXECUTE output, service=
-- api-gateway, (severity=info, count=2) and (severity=critical,
-- count=2). payments and auth-service must NOT appear.
--
-- PREPARE/EXECUTE is this repo's own EXPLAIN-equivalent mechanism
-- (fractal_text_to_sql's own header comment, sql/install_udf.sql) --
-- used here identically, by hand, to double-check the spike candidate
-- the same way the real procedure validates internally.

-- === EXPLAIN ===
SET @sql = (SELECT CONCAT('EXPLAIN ', sql_text) FROM spike_candidates LIMIT 1);
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ================================================================
-- EXECUTE (manual validation only -- the real feature never
-- auto-executes; this is us checking the answer is actually correct,
-- not just syntactically valid).
-- ================================================================

SET @sql = (SELECT sql_text FROM spike_candidates LIMIT 1);
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Interpretation:
--   - EXPLAIN failed -> syntactically broken SQL, a real problem
--     (fractal_text_to_sql's own PREPARE-only check would have caught
--     it and retried GENERATE -- see out_error in that case).
--   - EXPLAIN passed but EXECUTE shows payments/auth-service rows ->
--     syntactically valid, semantically WRONG. This is exactly the gap
--     REVIEW (Part 2) exists to catch -- check whether spike_candidates
--     .review was NULL (PASS) for this candidate despite it being wrong.
--   - review was NULL (PASS) on a candidate that executes wrong -> the
--     review step itself is not reliable for this model/prompt.
--   - EXPLAIN passes, EXECUTE shows only api-gateway (info=2,
--     critical=2) -> strong go signal for this model.
--
-- To compare against a different model, restart mariadbd with a
-- different FRACTALSQL_HTTP_MODEL and re-run Parts 1-3 from scratch
-- (spike_candidates is DROPped and recreated at the top of Part 1).
--
-- Clean up when done: DROP TABLE spike_candidates;
