-- demo/demo-business-intelligence.sql
--
-- A business-intelligence walkthrough, not just a text-to-sql
-- walkthrough: ask a plain-English business question, generate SQL,
-- EXECUTE it, and feed the real result back into fractal_reason() for
-- a narrative answer. Also covers Sniper Search (target customer
-- archetype) and Scout Discovery (find + name real customer segments).
--
-- Prerequisites: UDFs registered, reasoning configured, see
-- docs/reasoning-setup.md and confirm with:
--   SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation that this connection works');
--
-- Safe to re-run: the schema is dropped and recreated at the top.
--
-- Two structural notes worth knowing before reading this file:
--   1. fractal_text_to_sql() is a PROCEDURE here (question, table_names_
--      json, OUT out_sql, OUT out_error), not a scalar function.
--      MariaDB stored FUNCTIONs can't CALL a procedure at all, so
--      wrapping it in a function with a HANDLER FOR SQLEXCEPTION isn't
--      just extra ceremony, it's structurally impossible to write as a
--      function in the first place.
--   2. That kind of wrapper turns out to be unnecessary anyway:
--      fractal_text_to_sql() never SIGNALs on failure. It returns
--      cleanly with out_sql=NULL and out_error
--      set to a message (see sql/install_udf.sql's own header comment
--      on this procedure). Sections 2 and 3 below just CALL it
--      directly and branch on `out_error IS NOT NULL`, no exception
--      handler needed.
-- MariaDB's CLI still has no client-side \if/\gset the way psql does.
-- Sections 2 and 3 (which need "execute the generated SQL only if
-- generation succeeded") stay wrapped in stored PROCEDUREs with a
-- server-side IF for that reason, same as the original draft's
-- rationale, just without the now-removed function wrapper.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Schema + seed data. 18 months of orders across 60 customers, with
-- two patterns deliberately built in: a real revenue dip 4 months
-- back, and five RFM (recency/frequency/monetary) customer archetypes
-- spread across SFS's [-1,1] operating box.
-- ------------------------------------------------------------------
-- === 1. Schema + 18 months of order history, 60 customers ===

DROP TABLE IF EXISTS bi_customer_features;
DROP TABLE IF EXISTS bi_orders;
DROP TABLE IF EXISTS bi_customers;

CREATE TABLE bi_customers (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(64) NOT NULL,
    segment  VARCHAR(32) NOT NULL COMMENT 'ground truth, for narrating results below, not fed to Scout/Sniper',
    status   VARCHAR(16) NOT NULL DEFAULT 'active'
) COMMENT = 'Customers, with a ground-truth RFM segment label for narrating results below';

CREATE TABLE bi_orders (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    customer_id   INT NOT NULL,
    total_cents   INT NOT NULL,
    placed_at     TIMESTAMP NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES bi_customers(id)
) COMMENT = 'Order history; total_cents is order value in cents';

-- Five RFM archetypes, each roughly in [-0.8, 0.8].
CREATE TEMPORARY TABLE bi_archetypes (segment VARCHAR(32) PRIMARY KEY, r DOUBLE, f DOUBLE, m DOUBLE, n_customers INT);
INSERT INTO bi_archetypes (segment, r, f, m, n_customers) VALUES
    ('Champions',        -0.7,  0.7,  0.7, 14),
    ('At-Risk',           0.6,  0.5,  0.6, 10),
    ('New & Exploring',  -0.6, -0.6, -0.5, 12),
    ('Lost',               0.7, -0.7, -0.6, 14),
    ('Loyal & Modest',   -0.3,  0.4, -0.2, 10);

-- generate_series(1, n) has no MariaDB equivalent. A recursive CTE
-- bounded by a per-archetype max, joined back with a row filter,
-- replaces the CROSS JOIN LATERAL generate_series pattern.
INSERT INTO bi_customers (name, segment)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < (SELECT MAX(n_customers) FROM bi_archetypes)
)
SELECT CONCAT('customer_', ROW_NUMBER() OVER (ORDER BY a.segment, seq.n)), a.segment
FROM bi_archetypes a
JOIN seq ON seq.n <= a.n_customers
ORDER BY a.segment, seq.n;

CREATE TABLE bi_customer_features (customer_id INT PRIMARY KEY, feature_vec JSON,
    FOREIGN KEY (customer_id) REFERENCES bi_customers(id));
INSERT INTO bi_customer_features (customer_id, feature_vec)
SELECT c.id, JSON_ARRAY(a.r + (RAND() - 0.5) * 0.15, a.f + (RAND() - 0.5) * 0.15, a.m + (RAND() - 0.5) * 0.15)
FROM bi_customers c
JOIN bi_archetypes a ON a.segment = c.segment;

-- Order history: order count/value roughly follows each customer's own
-- frequency/monetary features. Month 4 (of 18, counting back from
-- today) gets a deliberate ~40% revenue dip.
INSERT INTO bi_orders (customer_id, total_cents, placed_at)
SELECT c.id,
       (3000 + (RAND() * 12000)) * CASE WHEN mo.n = 4 THEN 0.6 ELSE 1.0 END,
       NOW() - INTERVAL mo.n MONTH + INTERVAL (RAND() * 25) DAY
FROM bi_customers c
JOIN bi_customer_features f ON f.customer_id = c.id
CROSS JOIN (
    WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 18)
    SELECT n FROM seq
) mo
WHERE RAND() < (0.15 + 0.5 * ((JSON_VALUE(f.feature_vec, '$[1]') + 1) / 2));

-- Seed data summary.
SELECT (SELECT COUNT(*) FROM bi_customers) AS customers,
       (SELECT COUNT(*) FROM bi_orders) AS orders,
       (SELECT FORMAT(SUM(total_cents) / 100.0, 2) FROM bi_orders) AS total_revenue;

-- ------------------------------------------------------------------
-- 2. Simple fact lookup: generate -> execute -> show the raw result.
-- ------------------------------------------------------------------
-- === 2. Simple fact lookup: generate, then execute ===
DROP PROCEDURE IF EXISTS demo_bi_section2;
DELIMITER $$
CREATE PROCEDURE demo_bi_section2()
BEGIN
    DECLARE generated_sql TEXT;
    DECLARE gen_error     TEXT;
    CALL fractal_text_to_sql(
        'how many customers do we have and what is our total revenue?',
        '["bi_customers", "bi_orders"]', generated_sql, gen_error);
    SELECT generated_sql, gen_error;

    IF gen_error IS NULL THEN
        SET @sql = generated_sql;
        PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        SELECT 'Worth noticing: if the customer count above is lower than the 60 from the seed summary in Section 1, the model chose an INNER JOIN between customers and orders, quietly narrowing "how many customers do we have" to "how many customers have ordered". fractal_text_to_sql() never auto-executes precisely so the SQL is always worth reading first.' AS note;
    ELSE
        SELECT 'Skipped execution: generation itself failed for this question.' AS note;
    END IF;
END$$
DELIMITER ;
CALL demo_bi_section2();
DROP PROCEDURE demo_bi_section2;

-- ------------------------------------------------------------------
-- 3. The full BI loop: generate -> execute -> reason over the REAL
-- result. Excludes the current in-progress month, not just "last 6
-- months", otherwise whatever partial month is running when this
-- script executes always looks like a fake dip.
-- ------------------------------------------------------------------
-- === 3. The full loop: generate, execute, then reason over the real result ===
DROP TEMPORARY TABLE IF EXISTS bi_trend_result;
-- mon is VARCHAR, not TIMESTAMP/DATE: the idiomatic MariaDB answer to
-- "group by calendar month" is DATE_FORMAT(dt, '%Y-%m') (no date_trunc()
-- in this dialect), which returns a string label like '2026-03', not a
-- real date value -- confirmed against a live fractal_text_to_sql() run.
CREATE TEMPORARY TABLE bi_trend_result (mon VARCHAR(32), total_revenue DOUBLE);

DROP PROCEDURE IF EXISTS demo_bi_section3;
DELIMITER $$
CREATE PROCEDURE demo_bi_section3()
BEGIN
    DECLARE trend_sql   TEXT;
    DECLARE trend_error TEXT;
    CALL fractal_text_to_sql(
        'show total revenue for each of the 6 most recent FULLY COMPLETED calendar months, excluding the current in-progress month, oldest first',
        '["bi_orders"]', trend_sql, trend_error);
    SELECT trend_sql, trend_error;

    IF trend_error IS NULL THEN
        SET @sql = CONCAT('INSERT INTO bi_trend_result ', trend_sql);
        PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        SELECT * FROM bi_trend_result;

        SELECT fractal_reason(
            CONNECTION_ID(),
            'this is our last 6 months of revenue by month, what happened, and does it need attention?',
            (SELECT JSON_ARRAYAGG(JSON_OBJECT('mon', mon, 'total_revenue', total_revenue)) FROM bi_trend_result)
        );
    ELSE
        SELECT 'Skipped execution and reasoning: generation itself failed for this question.' AS note;
    END IF;
END$$
DELIMITER ;
CALL demo_bi_section3();
DROP PROCEDURE demo_bi_section3;

-- ------------------------------------------------------------------
-- 4. General data reasoning: synthesize across SEVERAL facts in one call.
-- ------------------------------------------------------------------
-- === 4. General reasoning: synthesize multiple facts into one narrative ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'given revenue trend, customer segment mix, and status breakdown together, what is the state of the business and what would you look into first?',
    JSON_OBJECT(
        'monthly_revenue', (SELECT JSON_ARRAYAGG(JSON_OBJECT('mon', mon, 'total_revenue', total_revenue)) FROM bi_trend_result),
        'segment_mix', (SELECT JSON_ARRAYAGG(JSON_OBJECT('segment', segment, 'customers', customers)) FROM (
            SELECT segment, COUNT(*) AS customers FROM bi_customers GROUP BY segment ORDER BY segment
        ) s),
        'status_breakdown', (SELECT JSON_ARRAYAGG(JSON_OBJECT('status', status, 'customers', customers)) FROM (
            SELECT status, COUNT(*) AS customers FROM bi_customers GROUP BY status
        ) u)
    )
);

-- ------------------------------------------------------------------
-- 5. Sniper Search: converge toward a TARGET customer archetype.
-- ------------------------------------------------------------------
-- === 5. Sniper Search: converge toward an ideal-customer profile ===
-- Query: recent + frequent + high-value (a "Champions"-shaped target).
-- fractal_search is 4-arg here (corpus, query, k, params); corpus=''
-- (empty corpus, src/fractalsql.c's own documented convention) + k=1
-- runs Sniper mode with no real corpus, same as demo.sql Section 2.
SELECT fractal_search('', '[-0.7, 0.7, 0.7]', 1, '{"iterations": 50}') AS ideal_profile;
-- Read the result as a DIRECTION to aim for, not a literal target
-- coordinate. Cosine similarity (what Sniper optimizes for) is
-- scale-invariant, so every point along the same ray as the query
-- scores identically; the magnitude returned varies run to run.

-- ------------------------------------------------------------------
-- 6. Scout Discovery: find real, DIVERSE customer segments, then have
-- fractal_reason() name them in business language.
-- ------------------------------------------------------------------
-- === 6. Scout Discovery: find and name real customer segments ===
-- fractal_explore(corpus, query, params) takes the corpus inline
-- rather than as a table/column reference (same
-- as demo.sql Section 4). Aggregate bi_customer_features.feature_vec
-- into that shape first, then explode the "population" array in the
-- JSON result back into rows via JSON_TABLE.
DROP TEMPORARY TABLE IF EXISTS bi_scout_result;
CREATE TEMPORARY TABLE bi_scout_result (particle_id INT, feature_vec JSON);
SET @bi_scout_corpus = (SELECT JSON_ARRAYAGG(feature_vec) FROM bi_customer_features);
INSERT INTO bi_scout_result (particle_id, feature_vec)
SELECT ROW_NUMBER() OVER (), p
FROM JSON_TABLE(
    (SELECT fractal_explore(
        @bi_scout_corpus, '[0, 0, 0]',
        '{"population_size": 8, "iterations": 10, "walk": 0}')),
    '$.population[*]' COLUMNS (p JSON PATH '$')
) AS jt;

SELECT * FROM bi_scout_result;

SELECT fractal_reason(
    CONNECTION_ID(),
    'each item is a (recency, frequency, monetary) customer profile in [-1,1], where recency -1 is very recent, frequency/monetary +1 is high. Name and describe each distinct segment in one line.',
    (SELECT JSON_ARRAYAGG(feature_vec) FROM bi_scout_result)
);

-- Demo complete. Tables left in place for inspection. Clean up with:
--   DROP TABLE bi_customer_features, bi_orders, bi_customers;
