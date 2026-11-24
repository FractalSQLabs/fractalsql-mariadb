-- demo/demo-fractal-index.sql
--
-- The native IVF index (fractal_index_create / _rebuild / _refresh / _drop
-- / _info / _list / _candidates) and the INDEXED fractal_search, on MariaDB.
--
-- The shape of the surface (sql/install_udf.sql has the reference):
--   * fractal_search(table, vector_col, query, k, options) is a stored
--     PROCEDURE: a MariaDB UDF cannot read a table, so the table I/O
--     lives in the procedure and the IVF maths in the fractalsqld
--     daemon. It returns the same {doc_id, dist} shape as
--     fractal_search_telemetry, plus a stats OUT parameter with
--     used_index / rows_scanned / cells_probed.
--   * EVERY distance the index returns is EXACT: each candidate is
--     verified against the base table with the shared double-precision
--     cosine (src/fsql_precision.h), so the index only ever narrows
--     the candidates -- it never answers with an approximate distance.
--   * Indexed search does NOT apply Diversify repulsion.
--   * The table-free convergence function was RENAMED:
--     fractal_search(vector_csv, query_csv, k, params) is now
--     fractal_sfs_converge(...) and the old call is refused with a
--     message that says so.
--
-- The index needs a core that carries the IVF maths. On a core without
-- it, every index call reports "this build of fractalsql-core does not
-- carry the IVF index (rebuild the core and refresh
-- include/<platform>)" -- the SQL surface is identical either way.

-- === Section 1: the corpus ===
DROP TABLE IF EXISTS demo_idx_docs;

CREATE TABLE demo_idx_docs (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    body      TEXT NOT NULL,
    embedding JSON NOT NULL
);

-- Twelve points around three centres, in 8 dimensions.
INSERT INTO demo_idx_docs (body, embedding) VALUES
 ('alpha 1', '[1,0,0,0,0,0,0,0]'),
 ('alpha 2', '[0.9,0.1,0,0,0,0,0,0]'),
 ('alpha 3', '[0.8,0.2,0,0,0,0,0,0]'),
 ('beta 1',  '[0,1,0,0,0,0,0,0]'),
 ('beta 2',  '[0.1,0.9,0,0,0,0,0,0]'),
 ('beta 3',  '[0.2,0.8,0,0,0,0,0,0]'),
 ('gamma 1', '[0,0,1,0,0,0,0,0]'),
 ('gamma 2', '[0,0,0.9,0.1,0,0,0,0]'),
 ('gamma 3', '[0,0,0.8,0.2,0,0,0,0]'),
 ('delta 1', '[0,0,0,1,0,0,0,0]'),
 ('delta 2', '[0,0,0,0.9,0.1,0,0,0]'),
 ('delta 3', '[0,0,0,0.8,0.2,0,0,0]');

SELECT id, body FROM demo_idx_docs ORDER BY id;

-- === Section 2: the exact fallback (no index yet) ===
-- With no index on the table, fractal_search scans every row and
-- scores it with the shared double-precision cosine. The stats say so:
-- used_index = false.
CALL fractal_search('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]', 3, '{}', @r, @s);
SELECT @r AS exact_rows;
SELECT @s AS exact_stats;

-- === Section 3: build the index ===
CALL fractal_index_create('demo_idx_docs', 'embedding',
                          '{"name":"demo_ix","vector_format":"FP32","nlist":4}', @r);
SELECT @r AS build_report;

CALL fractal_index_info('demo_ix', @r);
SELECT @r AS index_info;

-- === Section 4: the indexed search ===
-- The same rows, the same distances -- but the index did the narrowing,
-- and the stats say how much it scanned.
CALL fractal_search('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]', 3,
                    '{"index":"demo_ix"}', @r, @s);
SELECT @r AS indexed_rows;
SELECT @s AS indexed_stats;

-- === Section 5: the indexed distances are the EXACT distances ===
-- The indexed answer and the exact scan agree to the last bit: the
-- index only ever narrows the candidates.
CALL fractal_search('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]', 3,
                    '{"index":"demo_ix"}', @r, @s);
SET @indexed = @r;
CALL fractal_search('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]', 3,
                    '{"use_index":false}', @r2, @s2);
SET @exact = @r2;
SELECT JSON_EXTRACT(@indexed, '$[0].dist') AS indexed_dist,
       JSON_EXTRACT(@exact,   '$[0].dist') AS exact_dist,
       JSON_EXTRACT(@indexed, '$[0].dist') = JSON_EXTRACT(@exact, '$[0].dist') AS same_bits;

-- === Section 6: the delta (a row added after the build) ===
-- A row added after the build is not in the index. It is found anyway:
-- the rows above the id watermark are scanned exactly.
INSERT INTO demo_idx_docs (body, embedding) VALUES ('epsilon 1', '[1,0.05,0,0,0,0,0,0]');
CALL fractal_search('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]', 3,
                    '{"index":"demo_ix"}', @r, @s);
SELECT @r AS with_delta;
CALL fractal_index_info('demo_ix', @r);
SELECT JSON_EXTRACT(@r, '$.stale')   AS stale,
       JSON_EXTRACT(@r, '$.has_delta') AS has_delta,
       JSON_UNQUOTE(JSON_EXTRACT(@r, '$.status')) AS status,
       JSON_EXTRACT(@r, '$.advice')    AS advice;

-- The list shows every index with its status:
CALL fractal_index_list(@r);
SELECT @r AS indexes;

-- === Section 7: refresh folds the new row in, without retraining ===
CALL fractal_index_refresh('demo_ix', @r);
SELECT JSON_EXTRACT(@r, '$.added')      AS added,
       JSON_EXTRACT(@r, '$.generation') AS generation;
CALL fractal_index_info('demo_ix', @r);
SELECT JSON_UNQUOTE(JSON_EXTRACT(@r, '$.status')) AS status_after_refresh,
       JSON_EXTRACT(@r, '$.rows_indexed')         AS rows_indexed;

-- === Section 7a: one call that keeps an index fit to use: fractal_index_ensure ===
-- It looks at the index on a table and column and does only what is needed (created, refreshed, rebuilt or unchanged), so it suits a
-- setup script or a scheduled job:
CALL fractal_index_ensure('demo_idx_docs', 'embedding', NULL, @r);
SELECT JSON_UNQUOTE(JSON_EXTRACT(@r, '$.action')) AS ensure_action,
       JSON_UNQUOTE(JSON_EXTRACT(@r, '$.status')) AS ensure_status;

-- === Section 7b: search only some rows (the ids option) ===
CALL fractal_search('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]', 3,
                    '{"ids":[2,3,4,13]}', @r, @s);
SELECT @r AS among_these_rows, JSON_EXTRACT(@s, '$.rows_scanned') AS rows_scanned;

-- === Section 7c: a rebuild retrains from the current rows ===
CALL fractal_index_rebuild('demo_ix', @r);
SELECT JSON_EXTRACT(@r, '$.generation') AS generation,
       JSON_EXTRACT(@r, '$.rows')       AS rows_indexed;
CALL fractal_index_info('demo_ix', @r);
SELECT JSON_EXTRACT(@r, '$.stale') AS stale_after_rebuild;

-- === Section 8: the candidates for a Scout pass ===
CALL fractal_index_candidates('demo_idx_docs', 'embedding', '[1,0,0,0,0,0,0,0]',
                              '{"near":1,"per_cell":1}', @r);
SELECT @r AS candidate_ids;

-- === Section 9: drop it ===
CALL fractal_index_drop('demo_ix', @r);
SELECT @r AS dropped;
-- the index is gone, so asking about it is refused (the next line prints that error, on purpose):
CALL fractal_index_info('demo_ix', @r);

-- === Section 10: the renamed convergence function ===
-- fractal_sfs_converge is the table-free convergence function (it runs
-- SFS toward the query direction; it is not a retrieval function). The
-- old fractal_search(vector_csv, query_csv, k, params) call is refused,
-- and the message names the new name.
SELECT fractal_sfs_converge('[[1,0],[0,1],[0.6,0.8]]', '[0.6,0.8]', 3,
                             '{"iterations":50,"population_size":30}') AS convergence;

-- The old call fails on purpose -- run it on its own to see the message:
--   SELECT fractal_search('[[1,0],[0,1]]', '[1,0]', 1, '{}');

DROP TABLE IF EXISTS demo_idx_docs;
