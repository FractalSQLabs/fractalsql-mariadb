-- demo/demo-fractal-vector.sql
--
-- This extension ships two ways to store a vector: MariaDB 11.7+'s own
-- VECTOR(n)/VEC_FROMTEXT/VEC_TOTEXT/VEC_DISTANCE_* native type (see
-- test_vector_type.py) alongside a portable JSON path:
--   * Portable path (works on every 10.6-12.2 major): fractal_vector
--     is a JSON-array-string (sql/install_udf.sql). No custom SQL
--     type, no typmod, no operators, every vector operation is a
--     plain function call, which Section 5 below exercises.
--     fractal_vector_scale(vec, factor) exists too (the
--     scalar-multiply equivalent), see sql/install_udf.sql.
--   * Native path (MariaDB 11.7+ only): wrap any fractal_vector_*
--     result in VEC_FROMTEXT() to store it in a real VECTOR(n) column
--     (dimension enforced by MariaDB itself, a hard error on
--     mismatch, see test_vector_type.py Scenario 3), or VEC_TOTEXT()
--     a native column straight into these functions. This file sticks
--     to the portable JSON path throughout, since it must run on the
--     full 10.6-12.2 compat floor. See docs/vectorizer-setup.md and
--     sql/install_udf.sql's own comment block for the native-path
--     worked example.
-- Sections 1 and 3 (dimension enforcement) and 6 (storage comparison)
-- are kept as portable-path CHECK-constraint / JSON demos below rather
-- than pretending a typmod exists, matching what's real.

-- === Section 1: dimension enforcement, portable path ===
-- No typmod on the portable JSON path. Dimension checking is an
-- explicit CHECK constraint (MariaDB 10.2+), evaluated with
-- JSON_LENGTH(embedding) = <expected> on every insert/update, not part
-- of the column's declared type the way MariaDB's own native
-- VECTOR(n) is, on 11.7+ (see header).

DROP TABLE IF EXISTS docs_fv;
DROP TABLE IF EXISTS docs_fv_float8;

CREATE TABLE docs_fv (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    body      TEXT NOT NULL,
    embedding JSON
) COMMENT = 'Same shape as demo/demo-vectorizer.sql''s docs table, no distinct fractal_vector type on the portable path, see header note';

INSERT INTO docs_fv (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside MariaDB.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.');

SELECT id, body FROM docs_fv ORDER BY id;

-- === Section 2: create the vectorizer, exactly like the float8[] demo ===
-- fractal_vectorizer_create/_process_queue are PROCEDURES (trailing
-- OUT params / a plain result set respectively), not scalar functions.
-- Drop any leftover fractal_vectorizers row from a previous run first.
-- DROP TABLE docs_fv above already destroyed the trigger-backed table
-- itself, but NOT the vectorizer's own catalog row, which
-- fractal_vectorizer_create() refuses to duplicate (this file's own
-- closing comment claims re-runnability; this is what actually makes
-- that true).
DELETE FROM fractal_vectorizers WHERE source_table = 'docs_fv';
CALL fractal_vectorizer_create('docs_fv', 'body', 'embedding', NULL, @vzid);
CALL fractal_vectorizer_process_queue(100, 600);

SELECT id, body, embedding IS NOT NULL AS has_embedding,
       JSON_LENGTH(embedding) AS dim
FROM docs_fv
ORDER BY id;

-- === Section 3: the hard-fail, live (portable path, CHECK constraint) ===
-- No typmod on the portable JSON path. The equivalent guarantee is
-- an explicit CHECK constraint. docs_fv's own embedding column is left
-- unconstrained deliberately: its real dimension depends on whatever
-- embedding model the vectorizer above actually called (768 for
-- nomic-embed-text, a different width for another model/provider), so
-- a demo hardcoding one dimension against that live column would break
-- the moment someone points this file at a different endpoint. A
-- SEPARATE small fixture table demonstrates the CHECK mechanism itself
-- against a fixed, known dimension instead:
DROP TABLE IF EXISTS docs_fv_dimcheck;
CREATE TABLE docs_fv_dimcheck (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    embedding JSON,
    CONSTRAINT chk_docs_fv_dimcheck_dim3 CHECK (embedding IS NULL OR JSON_LENGTH(embedding) = 3)
);
INSERT INTO docs_fv_dimcheck (embedding) VALUES ('[0.1, 0.2, 0.3]');
SELECT * FROM docs_fv_dimcheck;
-- This INSERT is expected to fail with a CONSTRAINT violation,
-- that's the demo, not a bug in this script:
--   INSERT INTO docs_fv_dimcheck (embedding)
--     VALUES ('[0.1, 0.2]');  -- deliberately wrong dimension
-- On MariaDB 11.7+, the native path enforces the SAME guarantee at the
-- column-type level instead (VECTOR(3), confirmed live, see
-- test_vector_type.py Scenario 3), no CHECK constraint needed there.

-- === Section 4: fractal_search_trajectory over the embedding column ===
-- fractal_search_trajectory is a PROCEDURE here (trailing OUT p_result
-- JSON), and its result shape is [{"doc_id":...,"dist":...}, ...], the
-- same doc_id/dist convention every search primitive in this extension
-- uses (sql/install_udf.sql).
-- baseline = row 1's embedding, current = row 2's: two DIFFERENT
-- points, so dist actually varies by row below (passing the same
-- LIMIT-1 subquery for both arguments would make every row's dist
-- identical, which this demo deliberately avoids).
CALL fractal_search_trajectory(
    'docs_fv', 'embedding',
    (SELECT embedding FROM docs_fv ORDER BY id LIMIT 1),
    (SELECT embedding FROM docs_fv ORDER BY id LIMIT 1 OFFSET 1),
    2, @r);
SELECT * FROM JSON_TABLE(
    @r,
    '$[*]' COLUMNS (
        doc_id INT    PATH '$.doc_id',
        dist   DOUBLE PATH '$.dist'
    )
) AS jt;

-- === Section 5: fractal_vector operators and functions ===
-- Exercise the public vector-math surface: MariaDB UDFs can't define
-- new operators, so every one below is a plain function call instead
-- of <->/<=>/<#>/+/-/scalar *. Names match sql/install_udf.sql.
SELECT
    fractal_vector_l2_distance(a.embedding, b.embedding)            AS l2_distance,
    fractal_vector_cosine_distance(a.embedding, b.embedding)        AS cosine_distance,
    fractal_vector_negative_inner_product(a.embedding, b.embedding) AS neg_inner_product,
    fractal_vector_l2_squared(a.embedding, b.embedding)             AS l2_squared,
    fractal_vector_cosine_similarity(a.embedding, b.embedding)      AS cosine_similarity
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2
  AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL;

-- fractal_vector_add/normalize/scale return a JSON array (a
-- "fractal_vector" on the portable path is just JSON); dims confirms
-- the element count is preserved. fractal_vector_scale(vec, factor) is
-- in the shipped function set (the scalar `*` operator equivalent),
-- exercised here alongside add/normalize.
SELECT
    JSON_LENGTH(fractal_vector_add(a.embedding, b.embedding))       AS add_dims,
    JSON_LENGTH(fractal_vector_normalize(a.embedding))              AS normalize_dims,
    JSON_LENGTH(fractal_vector_scale(a.embedding, 2.0))              AS scale_dims
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2
  AND a.embedding IS NOT NULL AND b.embedding IS NOT NULL;

-- The float8[]<->fractal_vector cast pair (fractal_vector_from_float8_array
-- / fractal_vector_to_float8_array) collapses to a no-op on the
-- portable path, since both sides are already the same JSON
-- representation. pg_typeof has no MariaDB equivalent (no
-- UDF-return-type introspection function), so it's simply dropped.

-- === Section 6: storage comparison (portable path) ===
-- Both columns below are JSON text on the portable path, so
-- OCTET_LENGTH() shows near-identical sizes for equivalent data: no
-- compactness win here. That win does exist on MariaDB 11.7+'s native
-- VECTOR(n) (a real packed binary format: VEC_TOTEXT(embedding)
-- round-trips through the same bracket-comma text this section
-- compares, but the COLUMN itself stores packed float4s, not JSON
-- text). This comparison isn't meaningful on the portable JSON path
-- every major below 11.7 is stuck
-- with, so it's kept as a same-size sanity check, not a real "which is
-- smaller" measurement.
CREATE TABLE docs_fv_float8 (id INT AUTO_INCREMENT PRIMARY KEY, embedding JSON);
INSERT INTO docs_fv_float8 (embedding)
    SELECT embedding FROM docs_fv WHERE embedding IS NOT NULL;

SELECT
    (SELECT OCTET_LENGTH(embedding) FROM docs_fv WHERE embedding IS NOT NULL LIMIT 1)
        AS fractal_vector_bytes_json,
    (SELECT OCTET_LENGTH(embedding) FROM docs_fv_float8 LIMIT 1)
        AS float8_array_bytes_json;

-- This demo is re-runnable: the vectorizer config + queue + tables are
-- torn down at the top of the file (Section 1), so it can be re-run
-- without manual cleanup.
