-- demo/demo-text-to-sql.sql
--
-- Runnable walkthrough of the REAL fractal_text_to_sql() feature,
-- against a richer schema with real foreign keys, distinct from
-- demo/text-to-sql-spike-*.sql, which are throwaway hand-rolled
-- validation spikes (single-table, no FKs, driving
-- fractal_t2s_generate()/fractal_t2s_review() directly).
-- See docs/text-to-sql-setup.md for the full pipeline explanation, the
-- config reference, and the security model.
--
-- Prerequisites: UDFs registered (SOURCE sql/install_udf.sql;),
-- reasoning configured as process environment variables in mariadbd's
-- own environment BEFORE it starts (MariaDB has no live-reloadable
-- config mechanism a dlopen'd UDF library can hook into, so this can't
-- be a SET GLOBAL; see docs/COOKBOOK.md and build_test.sh's mdb_setup
-- for the export pattern). Confirm with:
--   SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation that this connection works');
-- before running this script.
--
-- fractal_schema_context() and fractal_text_to_sql() are both
-- PROCEDUREs here (trailing OUT params), not scalar functions: every
-- call below uses CALL ...(..., @out_var) then reads @out_var back,
-- not SELECT fractal_text_to_sql(...) directly.
--
-- Safe to re-run: the schema is dropped and recreated at the top.

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    name    VARCHAR(128) NOT NULL,
    status  VARCHAR(16) NOT NULL DEFAULT 'active'
        COMMENT 'one of: active, churned'
) COMMENT = 'People or companies who place orders';

CREATE TABLE orders (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    customer_id INT NOT NULL,
    placed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status      VARCHAR(16) NOT NULL DEFAULT 'pending'
        COMMENT 'one of: pending, paid, refunded, cancelled',
    FOREIGN KEY (customer_id) REFERENCES customers(id)
);

CREATE TABLE order_items (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    order_id    INT NOT NULL,
    sku         VARCHAR(64) NOT NULL,
    quantity    INT NOT NULL,
    unit_cents  INT NOT NULL,
    FOREIGN KEY (order_id) REFERENCES orders(id)
) COMMENT = 'Line items within an order; total = quantity * unit_cents';

INSERT INTO customers (name, status) VALUES
    ('acme',       'active'),
    ('globex',     'active'),
    ('initech',    'churned');

INSERT INTO orders (customer_id, status) VALUES
    (1, 'paid'), (1, 'paid'), (1, 'refunded'),
    (2, 'paid'),
    (3, 'cancelled');

INSERT INTO order_items (order_id, sku, quantity, unit_cents) VALUES
    (1, 'widget-a', 3, 500),
    (1, 'widget-b', 1, 1200),
    (2, 'widget-a', 2, 500),
    (3, 'widget-c', 1, 4000),
    (4, 'widget-b', 5, 1200);

-- === Section 1: schema context (what GENERATE actually sees) ===
CALL fractal_schema_context('["customers", "orders", "order_items"]', @ctx);
SELECT @ctx AS schema_context;

-- === Section 2: a simple single-table question ===
CALL fractal_text_to_sql(
    'How many customers have status active?',
    '["customers"]', @sql2, @err2);
SELECT @sql2 AS generated_sql, @err2 AS out_error;

-- === Section 3: a question requiring a join across the FK chain ===
CALL fractal_text_to_sql(
    'List the names of customers who have at least one paid order, with how many paid orders each has.',
    '["customers", "orders"]', @sql3, @err3);
SELECT @sql3 AS generated_sql, @err3 AS out_error;

-- === Section 4: a question requiring all three tables ===
CALL fractal_text_to_sql(
    'For each customer, what is the total value in cents of their paid orders (quantity times unit price, summed across all line items)?',
    '["customers", "orders", "order_items"]', @sql4, @err4);
SELECT @sql4 AS generated_sql, @err4 AS out_error;

-- === Section 5: run the generated SQL yourself ===
-- fractal_text_to_sql() never executes what it generates, that is
-- always a separate, explicit step. A user variable captured from the
-- OUT param straight into PREPARE/EXECUTE is arguably closer to what
-- production callers should do anyway (see docs/text-to-sql-setup.md's
-- execution-role grant guidance).
CALL fractal_text_to_sql(
    'What is the average number of line items per order?',
    '["orders", "order_items"]', @generated_sql, @err5);
SELECT @generated_sql AS generated, @err5 AS out_error;

PREPARE t2s_stmt FROM @generated_sql;
EXECUTE t2s_stmt;
DEALLOCATE PREPARE t2s_stmt;

-- Next: docs/text-to-sql-setup.md for the config reference, the
-- execution-role grant pattern (do not run generated SQL as root in
-- production), and how to validate against your own local models with
-- tests/test_text_to_sql_shadow.py.
--
-- Clean up: DROP TABLE order_items, orders, customers;
