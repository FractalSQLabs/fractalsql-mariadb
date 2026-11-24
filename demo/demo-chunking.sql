-- demo/demo-chunking.sql
-- Long text, chunked: split documents into passages, embed the passages, and answer a question from the right passages.
--
--   1. fractal_chunk_text on its own: how a text is cut (no model needed).
--   2. A vectorizer with chunk_size: the chunks go into a table and are embedded.
--   3. A question answered from one document only (meta_filter on parent_id), with the passages it was drawn from.
--   4. The same table through an index: fractal_index_ensure, then the session key agent_use_index.
--
-- Prerequisites: extension and daemon running, reasoning AND embedding configured (see demo/demo-vectorizer.sql for the local-Ollama example).
-- Confirm before running:   SELECT JSON_LENGTH(fractal_embed(CONNECTION_ID(), 'hello world'));
-- Safe to re-run: the demo tables are dropped and recreated.

-- === 1. How fractal_chunk_text cuts a text ===
-- paragraphs are packed into a chunk while it stays within the size
SELECT j.no, j.start, j.end_pos, j.chunk
  FROM JSON_TABLE(fractal_chunk_text(CONCAT('First paragraph here.', CHAR(10), CHAR(10), 'Second one is short.', CHAR(10), CHAR(10),
                                            'Third paragraph is a bit longer than the others are.'), 40, 0),
                  '$[*]' COLUMNS (no INT PATH '$.no', start INT PATH '$.start', end_pos INT PATH '$.end', chunk TEXT PATH '$.text')) j;
-- sentences, with a long sentence cut into overlapping pieces
SELECT j.no, j.chunk
  FROM JSON_TABLE(fractal_chunk_text('One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.', 30, 5, 'sentence'),
                  '$[*]' COLUMNS (no INT PATH '$.no', chunk TEXT PATH '$.text')) j;

-- === 2. A vectorizer that chunks ===
DROP TABLE IF EXISTS chunk_demo_docs_chunks;
DROP TABLE IF EXISTS chunk_demo_docs;
CREATE TABLE chunk_demo_docs (id BIGINT PRIMARY KEY, title VARCHAR(100), body TEXT);
INSERT INTO chunk_demo_docs VALUES
 (1, 'Heartbeat runbook', CONCAT(
  'A node that stops heartbeating is first marked suspect. The coordinator waits for three missed beats before it acts.', CHAR(10), CHAR(10),
  'If the node is still silent, drain its work to the other nodes and open an incident. Do not restart it until the drain has finished, or its in-flight work is lost.', CHAR(10), CHAR(10),
  'After the restart, watch the node for ten minutes. If it misses another beat, replace the hardware.')),
 (2, 'Backup runbook', CONCAT(
  'Backups run nightly at two in the morning. Each backup is verified by restoring it into a scratch database and comparing row counts.', CHAR(10), CHAR(10),
  'A failed verification pages the on-call engineer. Never delete the previous good backup until the next one has verified.')),
 (3, 'Billing runbook',
  'Invoices are generated on the first of the month. A customer who disputes an invoice gets it frozen until the dispute is closed.');
CALL fractal_vectorizer_create('chunk_demo_docs', 'body', 'embedding',
     '{"chunk_size": 220, "chunk_overlap": 20, "chunk_mode": "paragraph"}', @vectorizer_id);
SELECT @vectorizer_id AS vectorizer_id, COUNT(*) AS chunks_created FROM chunk_demo_docs_chunks;
CALL fractal_vectorizer_process_queue(50, 600);
SELECT parent_id, chunk_no, CHAR_LENGTH(chunk_text) AS chars, JSON_LENGTH(embedding) AS dims
  FROM chunk_demo_docs_chunks ORDER BY parent_id, chunk_no;

-- === 3. A question answered from one document, with the passages it used ===
-- the whole corpus
CALL fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', NULL, @r);
SELECT JSON_VALUE(@r, '$.answer') AS answer, JSON_EXTRACT(@r, '$.source_row_ids') AS source_row_ids, JSON_VALUE(@r, '$.used_index') AS used_index;
-- only the passages of document 1 (meta_filter)
CALL fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{"parent_id": 1}', @r);
SELECT JSON_VALUE(@r, '$.answer') AS answer, JSON_EXTRACT(@r, '$.source_row_ids') AS source_row_ids;
-- the passages those row ids name
SELECT c.id AS row_id, c.parent_id, c.chunk_no, CONCAT(LEFT(c.chunk_text, 70), '...') AS passage
  FROM chunk_demo_docs_chunks c
 WHERE JSON_CONTAINS(JSON_EXTRACT(@r, '$.source_row_ids'), CAST(c.id AS CHAR));

-- === 4. The same table through an index ===
CALL fractal_index_ensure('chunk_demo_docs_chunks', 'embedding', '{"vector_format": "FP32"}', @e);
SELECT @e AS ensured;
-- calling it again changes nothing
CALL fractal_index_ensure('chunk_demo_docs_chunks', 'embedding', NULL, @e);
SELECT @e AS ensured_again;
SELECT fractal_config_set('agent_use_index', 'on', CONNECTION_ID());
CALL fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', NULL, @r);
SELECT JSON_VALUE(@r, '$.used_index') AS used_index, JSON_EXTRACT(@r, '$.source_row_ids') AS source_row_ids;
SELECT fractal_config_set('agent_use_index', 'off', CONNECTION_ID());

-- Tables left in place for inspection. Clean up with:
--   CALL fractal_index_drop('chunk_demo_docs_chunks_embedding', @d); DROP TABLE chunk_demo_docs_chunks; DROP TABLE chunk_demo_docs;
