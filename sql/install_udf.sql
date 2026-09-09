-- fractalsql-mariadb UDF registration.
--
-- Prerequisite: fractalsql.so (Linux) or fractalsql.dll (Windows) is
-- in MariaDB's plugin_dir. The release packages handle this for you:
--   Linux:   /usr/lib/mysql/plugin/fractalsql.so
--   Windows: C:\Program Files\MariaDB <VER>\lib\plugin\fractalsql.dll
--
-- Run once, as a user with CREATE FUNCTION privilege:
--   mysql -u root -p < sql/install_udf.sql
--
-- Or from an interactive session:
--   SOURCE /usr/share/fractalsql-mariadb/install_udf.sql;
--
-- A single fractalsql.so covers all supported MariaDB majors
-- (10.6 / 10.11 / 11.4 LTS, 12.3 LTS): the UDF ABI is stable
-- across them.

DROP FUNCTION IF EXISTS fractal_search;
DROP FUNCTION IF EXISTS fractal_explore;
DROP FUNCTION IF EXISTS fractalsql_edition;
DROP FUNCTION IF EXISTS fractalsql_version;
DROP FUNCTION IF EXISTS fractal_dimension_dfa;
DROP FUNCTION IF EXISTS fractal_dimension_boxcount;
DROP FUNCTION IF EXISTS fractal_dimension_drift;
DROP FUNCTION IF EXISTS fractal_optimize_portfolio;
DROP FUNCTION IF EXISTS fractal_optimize_portfolio_multimodal;
DROP FUNCTION IF EXISTS fractal_optimize_portfolio_multimodal_ex;
DROP FUNCTION IF EXISTS fractal_optimize_portfolio_multimodal_pareto;
DROP FUNCTION IF EXISTS fractal_vascular_network;
DROP FUNCTION IF EXISTS fractal_cortical_folding;
DROP FUNCTION IF EXISTS fractal_nerve_plexus_metric;
DROP FUNCTION IF EXISTS fractal_morphological_complexity;
DROP FUNCTION IF EXISTS fractal_diversify_enable;
DROP FUNCTION IF EXISTS fractal_diversify_disable;
DROP FUNCTION IF EXISTS fractal_diversify_set_params;
DROP FUNCTION IF EXISTS fractal_detect_collapse;
DROP FUNCTION IF EXISTS fractal_explain_result;
DROP FUNCTION IF EXISTS fractal_session_close;
DROP FUNCTION IF EXISTS fractal_vector_dims;
DROP FUNCTION IF EXISTS fractal_vector_norm;
DROP FUNCTION IF EXISTS fractal_vector_normalize;
DROP FUNCTION IF EXISTS fractal_vector_add;
DROP FUNCTION IF EXISTS fractal_vector_sub;
DROP FUNCTION IF EXISTS fractal_vector_scale;
DROP FUNCTION IF EXISTS fractal_vector_l2_distance;
DROP FUNCTION IF EXISTS fractal_vector_l2_squared;
DROP FUNCTION IF EXISTS fractal_vector_cosine_distance;
DROP FUNCTION IF EXISTS fractal_vector_cosine_similarity;
DROP FUNCTION IF EXISTS fractal_vector_negative_inner_product;
DROP FUNCTION IF EXISTS fractal_vector_from_float8_array;
DROP FUNCTION IF EXISTS fractal_vector_to_float8_array;
DROP FUNCTION IF EXISTS fractal_reason;
DROP FUNCTION IF EXISTS fractal_embed;
DROP FUNCTION IF EXISTS fractal_t2s_config;
DROP FUNCTION IF EXISTS fractal_t2s_generate;
DROP FUNCTION IF EXISTS fractal_t2s_review;
DROP FUNCTION IF EXISTS fractal_t2s_check_allowlist;
DROP PROCEDURE IF EXISTS fractal_schema_context;
DROP PROCEDURE IF EXISTS fractal_text_to_sql;
DROP FUNCTION IF EXISTS _fractalsql_quote_ident;
DROP PROCEDURE IF EXISTS _fractalsql_vectorizer_enqueue;
DROP PROCEDURE IF EXISTS fractal_vectorizer_create;
DROP PROCEDURE IF EXISTS fractal_vectorizer_pause;
DROP PROCEDURE IF EXISTS fractal_vectorizer_resume;
DROP PROCEDURE IF EXISTS fractal_vectorizer_drop;
DROP PROCEDURE IF EXISTS fractal_vectorizer_process_queue;
DROP VIEW IF EXISTS fractal_vectorizer_status;
DROP FUNCTION IF EXISTS fractal_feedback_report;
DROP FUNCTION IF EXISTS fractal_isolate_background;
DROP PROCEDURE IF EXISTS _fractalsql_telemetry_topk;
DROP PROCEDURE IF EXISTS _fractalsql_scan_corpus;
DROP PROCEDURE IF EXISTS _fractalsql_fetch_row_context;
DROP PROCEDURE IF EXISTS fractal_search_telemetry;
DROP PROCEDURE IF EXISTS fractal_hybrid_clinical_search;
DROP PROCEDURE IF EXISTS fractal_search_trajectory;
DROP PROCEDURE IF EXISTS fractal_cross_modal_search;
DROP PROCEDURE IF EXISTS fractal_sql_agent;
DROP FUNCTION IF EXISTS fractal_ledger_flush;
DROP FUNCTION IF EXISTS fractal_ledger_load;
DROP FUNCTION IF EXISTS fractal_ledger_compact;
DROP FUNCTION IF EXISTS fractal_ledger_reset_soft;
DROP FUNCTION IF EXISTS fractal_ledger_reset_hard;
DROP FUNCTION IF EXISTS fractal_ledger_truth_count;
DROP FUNCTION IF EXISTS fractal_ledger_shadow_count;
DROP FUNCTION IF EXISTS fractal_ledger_verify;
DROP FUNCTION IF EXISTS fractal_audit_log;
DROP FUNCTION IF EXISTS fractal_audit_unpack;

-- fractal_search(vector_csv, query_csv, k, params) -> JSON STRING
CREATE FUNCTION fractal_search    RETURNS STRING SONAME 'fractalsql.so';

-- Scout Mode: fractal_explore(corpus, query, params) -> JSON STRING
-- (walk=0 dispersion; result JSON carries the additive "population")
CREATE FUNCTION fractal_explore   RETURNS STRING SONAME 'fractalsql.so';

-- fractalsql_edition() -> 'Community'
CREATE FUNCTION fractalsql_edition RETURNS STRING SONAME 'fractalsql.so';

-- fractalsql_version() -> '2.0.0'
CREATE FUNCTION fractalsql_version RETURNS STRING SONAME 'fractalsql.so';

-- ---------------------------------------------------------------------
-- Analytics tier (fractal dimension / geometry / portfolio)
--
-- MariaDB has no float8[]/int4[] array types and no DEFAULT-argument
-- syntax for CREATE FUNCTION. Array arguments are a CSV-or-JSON-array
-- STRING (the same convention fractal_search's own vector_csv/
-- query_csv arguments use), and optional scalar arguments (seed /
-- use_obl / diffusion_mode on fractal_optimize_portfolio) are bundled
-- into one trailing JSON params STRING instead. JSON return values are
-- JSON-valid STRING results: MariaDB's JSON type is itself a validated
-- LONGTEXT, not a distinct binary format, so no information is lost.
-- ---------------------------------------------------------------------

-- fractal_dimension_dfa(series_csv) -> DOUBLE
-- Detrended Fluctuation Analysis scaling exponent (Peng et al. 1994).
-- ~0.5 uncorrelated, ~1.0 1/f "pink" noise, ~1.5 Brownian motion.
-- Requires >= 16 points.
CREATE FUNCTION fractal_dimension_dfa RETURNS REAL SONAME 'fractalsql.so';

-- fractal_dimension_boxcount(points_csv, dim) -> DOUBLE
-- Box-counting (Minkowski-Bouligand) fractal dimension. points_csv is
-- a flat, row-major n_points*dim CSV/JSON-array. Requires >= 8 points
-- and a non-degenerate bounding box.
CREATE FUNCTION fractal_dimension_boxcount RETURNS REAL SONAME 'fractalsql.so';

-- fractal_dimension_drift(series_csv, win) -> JSON STRING
-- {"drift":.., "recent_alpha":.., "baseline_alpha":..}. DFA drift
-- between a series' recent `win` points and everything before them.
-- Positive drift = increasing complexity/irregularity. Requires
-- n >= win + 16, win >= 16.
CREATE FUNCTION fractal_dimension_drift RETURNS STRING SONAME 'fractalsql.so';

-- fractal_optimize_portfolio(mu_csv, cov_csv, k, params) -> JSON STRING
-- {"sharpe":.., "weights":[..]}. Cardinality-constrained Sharpe-ratio
-- maximization: at most k of n_assets get nonzero weight. params is a
-- JSON object, all keys optional:
--   {"seed": <int, default 0>, "use_obl": <bool, default false>,
--    "diffusion_mode": <"gaussian"|"levy", default "gaussian">}
-- Pass '{}' for defaults. mu: n_assets expected returns. cov: flat,
-- row-major n_assets x n_assets covariance matrix.
CREATE FUNCTION fractal_optimize_portfolio RETURNS STRING SONAME 'fractalsql.so';

-- fractal_optimize_portfolio_multimodal(mu_csv, cov_csv, k, n_restarts,
--   overlap_threshold, quality_frac, seed) -> JSON STRING
-- {"n_found":N,"candidates":[{"sharpe":..,"weights":[..]},...]}, Sharpe
-- descending. Enterprise-tier: runs fractal_optimize_portfolio's search
-- n_restarts times (1-64) with different derived seeds, then greedy
-- diverse-selects the results by asset-overlap (overlap_threshold,
-- 0.0-1.0 Jaccard-style) and a quality_frac floor (0.0 exclusive-1.0,
-- relative to the best Sharpe found). Returns NULL, cleanly, when no
-- enterprise library is loaded via FRACTALSQL_ENTERPRISE_LIB -- see
-- docs/enterprise.md. All 7 arguments are required and positional
-- (MariaDB UDFs have no default-argument syntax and this file has no
-- trailing params-JSON convention here, unlike fractal_optimize_portfolio
-- above). Also logs a best-effort audit-chain entry (kind=2) with the
-- full candidate set, same as fractal_optimize_portfolio does for its
-- one result, see docs/enterprise.md.
CREATE FUNCTION fractal_optimize_portfolio_multimodal RETURNS STRING SONAME 'fractalsql.so';

-- fractal_optimize_portfolio_multimodal_ex(mu_csv, cov_csv, k, n_restarts,
--   overlap_threshold, quality_frac, seed, use_obl, diffusion_mode)
--   -> JSON STRING
-- {"n_found":N,"candidates":[{"sharpe":..,"weights":[..]},...]}, Sharpe
-- descending. OBL/Levy-flight-capable sibling of the function above:
-- same n_restarts search and diverse selection, with the two extra knobs
-- applied uniformly to every restart's search. use_obl is 0/1 (evaluate
-- each SFS trial candidate's bound-reflected opposite, keep whichever
-- fits better); diffusion_mode is 'gaussian' (default) or 'levy', a
-- heavy-tailed step that can help escape local optima on highly
-- multimodal problems. All 9 arguments are required and positional
-- (MariaDB UDFs have no default-argument syntax), same NULL-dormant and
-- audit-chain behavior as the function above. When the enterprise
-- library predates the _ex symbol, passing the default knobs (use_obl=0,
-- diffusion_mode='gaussian') falls back to the base function's identical
-- search; requesting either knob on such a library returns NULL.
-- See docs/enterprise.md.
CREATE FUNCTION fractal_optimize_portfolio_multimodal_ex RETURNS STRING SONAME 'fractalsql.so';

-- fractal_optimize_portfolio_multimodal_pareto(mu_csv, cov_csv, k,
--   n_restarts, max_front, seed, use_obl, diffusion_mode) -> JSON STRING
-- {"n_found":N,"candidates":[{"return":..,"risk":..,"sharpe":..,
-- "weights":[..]},...]}, Sharpe descending. Pareto-front sibling of the
-- function above: same n_restarts independent searches, but each
-- candidate is scored by decomposed (return, risk) instead of scalar
-- Sharpe and the results are reduced to a genuine non-dominated Pareto
-- front (NSGA-II crowding-distance truncation past max_front) instead
-- of the sharpe-threshold + asset-overlap selection. Purely additive:
-- does not change that sibling's semantics or output shape.
-- 1 <= max_front <= n_restarts. All 8 arguments are required and
-- positional, same NULL-dormant and audit-chain behavior as above; this
-- one has no fallback to the base symbol (there is no non-Pareto shape
-- of this result to fall back to). See docs/enterprise.md.
CREATE FUNCTION fractal_optimize_portfolio_multimodal_pareto RETURNS STRING SONAME 'fractalsql.so';

-- fractal_vascular_network(node_coords_csv, edges_csv, edge_arc_length_csv)
--   -> JSON STRING {"mean_tortuosity":.., "branch_density":..,
--                   "fractal_dimension":..}
-- node_coords: flat n_nodes*3 (x,y,z). edges: flat n_edges*2
-- node-index pairs. edge_arc_length: n_edges true centerline arc
-- lengths (e.g. from VMTK). Pre-extracted vessel geometry only, not
-- raw medical imaging data.
CREATE FUNCTION fractal_vascular_network RETURNS STRING SONAME 'fractalsql.so';

-- fractal_cortical_folding(vertices_csv, faces_csv) -> JSON STRING
-- {"mesh_area":.., "hull_area":.., "gyrification_index":..}
-- Gyrification Index (Zilles et al. 1988): mesh surface area / convex
-- hull surface area. vertices: flat n_vertices*3. faces: flat
-- n_faces*3 triangle vertex indices. Requires >= 4 non-coplanar
-- vertices.
CREATE FUNCTION fractal_cortical_folding RETURNS STRING SONAME 'fractalsql.so';

-- fractal_nerve_plexus_metric(node_coords_csv, dim, edges_csv)
--   -> JSON STRING {"fiber_length_density":.., "branch_density":..,
--                   "fractal_dimension":..}
-- Nerve fiber plexus metrics (corneal confocal microscopy convention).
-- node_coords: flat n_nodes*dim (dim typically 2). edges: flat
-- n_edges*2 node-index pairs.
CREATE FUNCTION fractal_nerve_plexus_metric RETURNS STRING SONAME 'fractalsql.so';

-- fractal_morphological_complexity(points_csv, dim) -> JSON STRING
-- {"dimension":.., "lacunarity":..}
-- Box-counting dimension + fixed-grid lacunarity of a pre-segmented
-- mask. points_csv: flat n_points*dim occupied mask points.
CREATE FUNCTION fractal_morphological_complexity RETURNS STRING SONAME 'fractalsql.so';

-- ---------------------------------------------------------------------
-- Discovery tier
--
-- fractal_explore covers table/column-scan discovery, using the same
-- "Scout" walk=0 dispersion and corpus-as-argument convention
-- fractal_search itself uses. MariaDB UDFs cannot scan a table or
-- column directly, so the caller builds the corpus and passes it in.
--
-- fractal_search's own JSON output already carries a top_k array, so
-- JSON_TABLE() over fractal_search(...) gets per-row (idx, dist)
-- results in plain SQL, with no separate telemetry function needed:
--
--   SELECT t.idx, t.dist
--   FROM JSON_TABLE(
--          (SELECT fractal_search(@corpus, @query, 5, '{}')),
--          '$.top_k[*]' COLUMNS (idx INT PATH '$.idx', dist DOUBLE PATH '$.dist')
--        ) t;
--
-- fractal_diversify_enable/disable/set_params, fractal_detect_collapse,
-- and fractal_explain_result each take an explicit session_id BIGINT
-- as their first argument, backed by a connection-scoped ctx registry
-- (src/fractalsql_session.c). MariaDB is one shared multithreaded
-- process serving every connection, so per-connection Diversify tuning
-- (and its rolling D_q/overhead stats) needs an explicit key rather
-- than a single shared static. Convention: pass CONNECTION_ID() as
-- session_id. fractal_search / fractal_explore pick up that same
-- session's ctx via an optional "session_id" key in their own params
-- JSON, so Diversify settings actually affect real searches:
--
--   SELECT fractal_diversify_enable(CONNECTION_ID());
--   SELECT fractal_diversify_set_params(CONNECTION_ID(),
--            '{"window_n": 8, "repulsion_weight": 0.7}');
--   SELECT fractal_search(@corpus, @query, 5,
--            JSON_SET('{}', '$.session_id', CONNECTION_ID()));
--   SELECT fractal_detect_collapse(CONNECTION_ID()) AS dq;
--   SELECT fractal_explain_result(CONNECTION_ID()) AS diagnostics;
--   SELECT fractal_diversify_disable(CONNECTION_ID());
--   SELECT fractal_session_close(CONNECTION_ID());  -- (optional early cleanup)
--
-- KNOWN LIMITATION: MariaDB gives UDFs no on-disconnect hook, so a
-- session's registry entry can only be reclaimed by an idle-TTL sweep
-- or LRU eviction, not exactly on disconnect, and MariaDB can reuse
-- CONNECTION_ID() values over the server's lifetime under sustained
-- churn. See src/fractalsql_session.h for the full reasoning and the
-- bounded, documented residual risk. Call fractal_session_close(...)
-- explicitly at the end of a logical session (e.g. from a connection
-- pool's release hook) to avoid relying on the idle sweep at all.
-- ---------------------------------------------------------------------

-- fractal_diversify_enable(session_id) -> INT (0)
CREATE FUNCTION fractal_diversify_enable  RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_diversify_disable(session_id) -> INT (0)
CREATE FUNCTION fractal_diversify_disable RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_diversify_set_params(session_id, params_json) -> INT (0)
-- params_json: JSON object, all keys optional (only supplied keys
-- override the session's current value):
--   {"window_n": <uint, default 5, max 32>,
--    "stall_threshold": <double, default 0.15>,
--    "repulsion_sigma": <double, default f(dim)>,
--    "repulsion_weight": <double>,
--    "max_shadows_considered": <uint, default 64>,
--    "tail_buffer_cap": <uint, default 256, max 1024>}
CREATE FUNCTION fractal_diversify_set_params RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_detect_collapse(session_id) -> DOUBLE (current D_q, NULL if
-- Diversify disabled or no diversify-aware search has run yet)
CREATE FUNCTION fractal_detect_collapse RETURNS REAL SONAME 'fractalsql.so';

-- fractal_explain_result(session_id) -> JSON STRING
-- {"dq":.., "diversify_enabled":.., "overhead_p99_us":..}
CREATE FUNCTION fractal_explain_result RETURNS STRING SONAME 'fractalsql.so';

-- fractal_session_close(session_id) -> INT (0)
-- Explicit early cleanup of a session's registry entry (Diversify
-- state). Optional, see the idle-TTL note above.
CREATE FUNCTION fractal_session_close RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_feedback_report(session_id, result_handle, kind [, dwell_ms])
--   -> INT (0). kind: 'dwell' | 'positive' | 'negative'. Writes into the
-- same per-session rolling state fractal_detect_collapse/
-- fractal_explain_result read. Inert until fractal_diversify_enable()
-- has been called on this session; also used by the Agency tier's
-- fractal_agent_feedback_audit, which needs the convenience wrapper
-- below.
CREATE FUNCTION fractal_feedback_report RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_isolate_background(session_id, result_handle) -> INT (0)
-- Convenience wrapper: fractal_feedback_report(session_id,
-- result_handle, 'negative', 0).
CREATE FUNCTION fractal_isolate_background RETURNS INTEGER SONAME 'fractalsql.so';

-- ---------------------------------------------------------------------
-- v2.0.0, Discovery tier, Vector group
--
-- REPRESENTATION: a fractal_vector is a JSON-array-of-numbers STRING,
-- e.g. '[1,2,3]', the same convention fractalsql.c's parse_vector_csv
-- already uses for query_csv/corpus rows, which also accepts bare CSV
-- ('1,2,3'). This is the PORTABLE path: every function below works on
-- the full 10.6-12.3 compatibility floor. The math itself is
-- fractalsql-core's fsql_vector_* module (float32 storage width, so
-- precision behaves consistently wherever a vector value travels).
--
-- The NATIVE path (MariaDB 11.7.1+, GA in 11.8 LTS) is MariaDB's own
-- VECTOR(n) column type plus the built-in VEC_FROMTEXT()/VEC_TOTEXT()/
-- VEC_DISTANCE_EUCLIDEAN()/VEC_DISTANCE_COSINE() functions, confirmed
-- to use the SAME bracket-comma text grammar this module emits and
-- accepts, so no conversion UDF is needed: wrap any
-- fractal_vector_* result in VEC_FROMTEXT() to get a native, index-
-- accelerated VECTOR value, or VEC_TOTEXT() a native column straight
-- into these functions. Worked example (11.7+ only):
--
--   CREATE TABLE docs (
--     id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
--     embedding VECTOR(3) NOT NULL,
--     VECTOR INDEX (embedding)
--   );
--   INSERT INTO docs (embedding) VALUES
--     (VEC_FROMTEXT(fractal_vector_normalize('[3,4,0]')));
--   SELECT id, VEC_DISTANCE_COSINE(embedding, VEC_FROMTEXT('[1,0,0]'))
--     FROM docs ORDER BY 2 LIMIT 5;
--   -- or, staying entirely on the portable path:
--   SELECT fractal_vector_cosine_distance(
--            VEC_TOTEXT(embedding), '[1,0,0]') FROM docs;
--
-- Below 11.7, skip VECTOR(n)/VEC_* entirely and store the JSON string
-- in a plain TEXT/JSON column: every fractal_vector_* function below
-- works unchanged either way.
-- ---------------------------------------------------------------------

-- fractal_vector_dims(vec) -> INT
CREATE FUNCTION fractal_vector_dims RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_vector_norm(vec) -> DOUBLE (L2 / Euclidean norm)
CREATE FUNCTION fractal_vector_norm RETURNS REAL SONAME 'fractalsql.so';

-- fractal_vector_normalize(vec) -> fractal_vector (JSON STRING), unit norm
CREATE FUNCTION fractal_vector_normalize RETURNS STRING SONAME 'fractalsql.so';

-- fractal_vector_add(a, b) -> fractal_vector, elementwise sum
CREATE FUNCTION fractal_vector_add RETURNS STRING SONAME 'fractalsql.so';

-- fractal_vector_sub(a, b) -> fractal_vector, elementwise difference
CREATE FUNCTION fractal_vector_sub RETURNS STRING SONAME 'fractalsql.so';

-- fractal_vector_scale(vec, scalar) -> fractal_vector
CREATE FUNCTION fractal_vector_scale RETURNS STRING SONAME 'fractalsql.so';

-- fractal_vector_l2_distance(a, b) -> DOUBLE (Euclidean distance)
CREATE FUNCTION fractal_vector_l2_distance RETURNS REAL SONAME 'fractalsql.so';

-- fractal_vector_l2_squared(a, b) -> DOUBLE (Euclidean distance, squared)
CREATE FUNCTION fractal_vector_l2_squared RETURNS REAL SONAME 'fractalsql.so';

-- fractal_vector_cosine_distance(a, b) -> DOUBLE (1 - cosine similarity)
CREATE FUNCTION fractal_vector_cosine_distance RETURNS REAL SONAME 'fractalsql.so';

-- fractal_vector_cosine_similarity(a, b) -> DOUBLE
CREATE FUNCTION fractal_vector_cosine_similarity RETURNS REAL SONAME 'fractalsql.so';

-- fractal_vector_negative_inner_product(a, b) -> DOUBLE (-dot(a,b))
CREATE FUNCTION fractal_vector_negative_inner_product RETURNS REAL SONAME 'fractalsql.so';

-- fractal_vector_from_float8_array(vec) -> fractal_vector
-- Validates and canonicalizes a JSON-array-of-numbers. Same operation
-- as fractal_vector_to_float8_array below (MariaDB has no float8[]
-- array type distinct from this module's own JSON convention); kept
-- as two names for API symmetry.
CREATE FUNCTION fractal_vector_from_float8_array RETURNS STRING SONAME 'fractalsql.so';

-- fractal_vector_to_float8_array(vec) -> fractal_vector (see above)
CREATE FUNCTION fractal_vector_to_float8_array RETURNS STRING SONAME 'fractalsql.so';

-- v2.0.0, Cognition tier
--
-- Config: see src/fractalsql_cognition.c's file header for the full
-- account of why this is process environment variables rather than
-- my.cnf system variables (MariaDB has no live-reloadable, GUC-style
-- config surface a UDF can read at query time). Set these in mysqld's
-- environment before start (systemd Environment=, Docker
-- `environment:`):
--   FRACTALSQL_REASONING_PLUGIN   absolute path to a fsql_reasoning_
--                                 init-exporting .so (required)
--   FRACTALSQL_HTTP_URL           chat-completions endpoint URL
--   FRACTALSQL_HTTP_TOKEN         bearer/api-key token
--   FRACTALSQL_HTTP_MODEL         chat model name
--   FRACTALSQL_HTTP_EMBED_URL     embeddings endpoint URL, for
--                                 fractal_embed() (no fallback to
--                                 HTTP_URL; the embeddings endpoint
--                                 has a different shape)
--   FRACTALSQL_HTTP_EMBED_MODEL   embedding model name
--   FRACTALSQL_HTTP_ALLOW_PLAINTEXT  "1" to allow a non-TLS URL
-- Both functions take session_id BIGINT as their first argument (pass
-- CONNECTION_ID() by convention, same as fractal_diversify_enable and
-- fractal_search's own session_id), since each session gets its own
-- reasoning-dispatch ctx.
--
-- fractal_reason(session_id, query [, context]) -> TEXT
CREATE FUNCTION fractal_reason RETURNS STRING SONAME 'fractalsql.so';

-- fractal_embed(session_id, input) -> fractal_vector (JSON-array-string,
-- same grammar as fractal_vector_*, feeds straight into those
-- functions or VEC_FROMTEXT() with no conversion step)
CREATE FUNCTION fractal_embed RETURNS STRING SONAME 'fractalsql.so';

-- ---------------------------------------------------------------------
-- v2.0.0, Text-to-SQL tier
--
-- ARCHITECTURE: validating a candidate query (EXPLAIN) and reading
-- catalog introspection for schema context both need to run under the
-- CALLING role's own privileges. A plain MariaDB UDF cannot run SQL
-- against the session that called it at all, so fractal_text_to_sql
-- and fractal_schema_context are SQL SECURITY INVOKER stored
-- PROCEDUREs (CALL, not SELECT, a deliberate departure from every
-- other function above): their PREPARE/EXPLAIN-equivalent and
-- information_schema queries run under the CALLING user's own grants.
-- See src/fractalsql_textsql.c's file header for the full account,
-- including why a C-UDF-with-loopback-connection alternative was
-- rejected (privilege-model mismatch for a safety-gated feature).
--
-- Config (same env-var convention as the Cognition tier above):
--   FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS        int, default 2
--   FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS  "select" (default) |
--                                               "select_insert_update"
--   FRACTALSQL_TEXT_TO_SQL_USE_REVIEW          "1" to enable, default off
-- (plus the FRACTALSQL_REASONING_PLUGIN / HTTP_* vars the Cognition
-- tier above already uses: same plugin, same endpoint).
--
-- Usage:
--   CALL fractal_text_to_sql('how many orders shipped last week?',
--                             NULL, @sql, @err);
--   SELECT @sql, @err;
--
--   CALL fractal_schema_context('["orders","customers"]', @ctx);
--   SELECT @ctx;
-- ---------------------------------------------------------------------

-- fractal_t2s_config() -> JSON STRING (internal, read by the
-- fractal_text_to_sql procedure below; not meant to be called directly,
-- though nothing prevents it)
CREATE FUNCTION fractal_t2s_config RETURNS STRING SONAME 'fractalsql.so';

-- fractal_t2s_generate(session_id, prompt, context_text, system_tag)
--   -> TEXT (candidate SQL, code-mode-extracted). Internal, called by
--   fractal_text_to_sql's GENERATE step.
CREATE FUNCTION fractal_t2s_generate RETURNS STRING SONAME 'fractalsql.so';

-- fractal_t2s_review(session_id, question, candidate_sql) -> TEXT
--   NULL = PASS, else the model's critique. Internal, called by
--   fractal_text_to_sql's optional REVIEW step
--   (FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=1).
CREATE FUNCTION fractal_t2s_review RETURNS STRING SONAME 'fractalsql.so';

-- fractal_t2s_check_allowlist(sql) -> TEXT
--   NULL = passes, else a human-readable rejection reason. Pure
--   text/lexical validation, no database access. A MariaDB-dialect
--   statement-shape allowlist (see src/fractalsql_textsql.c for the
--   full rationale: MariaDB CTEs can't embed DML, but MariaDB has its
--   own "SELECT ... INTO OUTFILE" filesystem-write hazard to guard
--   against instead). Exposed directly, with no reason to
--   hide it: callers building their own text-to-sql flow around the
--   raw fractal_t2s_generate output can reuse this gate standalone.
CREATE FUNCTION fractal_t2s_check_allowlist RETURNS STRING SONAME 'fractalsql.so';

DELIMITER $$

-- fractal_schema_context(table_names_json, out_context)
--   table_names_json: JSON array of table names, e.g.
--   '["orders","customers"]', or NULL to auto-discover every base
--   table visible to the caller. out_context: plain-text schema
--   description (columns, PK/NOT NULL, comments, foreign keys), for
--   use as fractal_reason()/fractal_text_to_sql() prompt context.
-- SQL SECURITY INVOKER: information_schema rows are already filtered
-- to what the CALLING user can see, so no separate privilege check is
-- needed; MariaDB does that filtering for us as a property of
-- information_schema itself.
--
-- Every statement below runs after "SET NAMES utf8mb4": without it,
-- a stored routine's charset (params, DECLAREd variables, string
-- literals) is frozen to character_set_client/character_set_connection
-- AT CREATE TIME. A client installing this file with a legacy codepage
-- charset (e.g. cp850, which the Windows mariadb client auto-detects
-- from the console codepage) then bakes cp850 into every routine, and
-- any CONCAT mixing those variables with information_schema data
-- (utf8) fails at CALL time with "Illegal mix of collations for
-- operation 'concat'" -- even though the identical CONCAT works when
-- run standalone. utf8mb4 is the aggregation superset of every charset
-- this file's routines can mix with, so pinning it makes installation
-- charset-independent.
SET NAMES utf8mb4;
CREATE PROCEDURE fractal_schema_context(
    IN  table_names_json JSON,
    OUT out_context      LONGTEXT
)
SQL SECURITY INVOKER

BEGIN
    DECLARE done        BOOLEAN DEFAULT FALSE;
    DECLARE tbl_name     VARCHAR(64);
    DECLARE tbl_comment  TEXT;
    DECLARE cols_text    TEXT;
    DECLARE fks_text     TEXT;
    DECLARE n_tables     INT DEFAULT 0;
    DECLARE n_requested  INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT name FROM _fractalsql_t2s_schema_tmp ORDER BY name;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    IF table_names_json IS NOT NULL AND JSON_LENGTH(table_names_json) > 512 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'fractal_schema_context: too many tables requested, exceeds the limit of 512';
    END IF;

    DROP TEMPORARY TABLE IF EXISTS _fractalsql_t2s_schema_tmp;
    CREATE TEMPORARY TABLE _fractalsql_t2s_schema_tmp (name VARCHAR(64) PRIMARY KEY);

    IF table_names_json IS NOT NULL THEN
        SET n_requested = JSON_LENGTH(table_names_json);
        INSERT IGNORE INTO _fractalsql_t2s_schema_tmp (name)
        SELECT jt.name
        FROM JSON_TABLE(table_names_json, '$[*]' COLUMNS (name VARCHAR(64) PATH '$')) jt
        JOIN information_schema.tables t
          ON t.table_schema = DATABASE() AND t.table_name = jt.name AND t.table_type = 'BASE TABLE';

        IF (SELECT COUNT(*) FROM _fractalsql_t2s_schema_tmp) <> n_requested THEN
            DROP TEMPORARY TABLE IF EXISTS _fractalsql_t2s_schema_tmp;
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'fractal_schema_context: one or more requested tables not found or not visible';
        END IF;
    ELSE
        INSERT INTO _fractalsql_t2s_schema_tmp (name)
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE';
    END IF;

    SET out_context = '';

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO tbl_name;
        IF done THEN
            LEAVE read_loop;
        END IF;

        SELECT table_comment INTO tbl_comment
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = tbl_name;

        SELECT GROUP_CONCAT(
                 CONCAT('    ', column_name, ' ', column_type,
                        IF(column_key = 'PRI', ' PK', ''),
                        IF(is_nullable = 'NO', ' NOT NULL', ''),
                        IF(column_comment <> '', CONCAT(' -- ', column_comment), ''))
                 ORDER BY ordinal_position SEPARATOR '\n')
          INTO cols_text
        FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = tbl_name;

        SELECT GROUP_CONCAT(
                 CONCAT('    ', tbl_name, ': FOREIGN KEY (', column_name, ') REFERENCES ',
                        referenced_table_name, '(', referenced_column_name, ')')
                 SEPARATOR '\n')
          INTO fks_text
        FROM information_schema.key_column_usage
        WHERE table_schema = DATABASE() AND table_name = tbl_name
          AND referenced_table_name IS NOT NULL;

        SET out_context = CONCAT(out_context, 'Table: ', tbl_name, '\n');
        IF tbl_comment IS NOT NULL AND tbl_comment <> '' THEN
            SET out_context = CONCAT(out_context, '  Comment: ', tbl_comment, '\n');
        END IF;
        SET out_context = CONCAT(out_context, '  Columns:\n', IFNULL(cols_text, ''), '\n');
        IF fks_text IS NOT NULL THEN
            SET out_context = CONCAT(out_context, '  Foreign keys:\n', fks_text, '\n');
        END IF;
        SET out_context = CONCAT(out_context, '\n');

        SET n_tables = n_tables + 1;
    END LOOP;
    CLOSE cur;

    DROP TEMPORARY TABLE IF EXISTS _fractalsql_t2s_schema_tmp;

    IF n_tables = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'fractal_schema_context: no visible tables found';
    END IF;
END$$

-- fractal_text_to_sql(question, table_names_json, out_sql, out_error)
--   GENERATE/ALLOWLIST/EXPLAIN pipeline (+ optional REVIEW) returning a
--   single SQL statement in out_sql, or a rejection reason in
--   out_error. Both NULL is not a possible outcome: exactly one is
--   set on return; a hard failure like a missing reasoning plugin
--   raises a real SQL error instead of setting out_error. Never
--   auto-executed. Retries up to FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS
--   times, feeding each rejection back into the next GENERATE attempt.
--
-- The EXPLAIN-equivalent mechanical check below is PREPARE-only
-- (immediately DEALLOCATEd on success, never EXECUTEd) rather than
-- literally running EXPLAIN <candidate>: PREPARE already performs the
-- same parse and catalog-resolution work EXPLAIN relies on (unknown
-- table/column, basic type mismatches all surface as a PREPARE-time
-- error), while completely sidestepping the problem of a dynamic
-- EXPLAIN's own result set leaking out of this procedure's CALL as a
-- spurious extra result set. This is a best-effort quality gate, not
-- a complete semantic validator (a few deep
-- runtime-only checks may only surface at actual execution); real
-- security still rests on the execution role's own grants, not on
-- this check.
CREATE PROCEDURE fractal_text_to_sql(
    IN  p_question    TEXT,
    IN  p_table_names JSON,
    OUT out_sql       TEXT,
    OUT out_error     TEXT
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_session_id   BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_cfg          TEXT;
    DECLARE v_max_attempts INT DEFAULT 2;
    DECLARE v_allowed      VARCHAR(24) DEFAULT 'select';
    DECLARE v_use_review   BOOLEAN DEFAULT FALSE;
    DECLARE v_system_tag   VARCHAR(32);
    DECLARE v_schema_ctx   LONGTEXT;
    DECLARE v_feedback     TEXT DEFAULT NULL;
    DECLARE v_candidate    TEXT DEFAULT NULL;
    DECLARE v_prompt       TEXT;
    DECLARE v_check_err    TEXT DEFAULT NULL;
    DECLARE v_attempt      INT DEFAULT 1;
    DECLARE v_prep_ok      BOOLEAN DEFAULT TRUE;
    DECLARE v_done         BOOLEAN DEFAULT FALSE;
    DECLARE v_audit        BIGINT DEFAULT 0;

    SET out_sql   = NULL;
    SET out_error = NULL;

    IF p_question IS NULL OR TRIM(p_question) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_text_to_sql: question must not be empty';
    END IF;

    SET v_cfg          = fractal_t2s_config();
    SET v_max_attempts = JSON_VALUE(v_cfg, '$.max_attempts');
    SET v_allowed       = JSON_VALUE(v_cfg, '$.allowed_statements');
    SET v_use_review    = (JSON_VALUE(v_cfg, '$.use_review') = 'true');

    -- e.g. VERSION() = '10.11.10-MariaDB' becomes 'mariadb1011'. A plain UDF
    -- has no access to the connected server's version (see
    -- src/fractalsql_textsql.c's file header); this procedure does, via
    -- VERSION(), and passes it through to fractal_t2s_generate as the
    -- REASONING_HTTP_SYSTEM_TAG prompt hint.
    SET v_system_tag = CONCAT('mariadb',
        REPLACE(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(), '-', 1), '.', 2), '.', ''));

    CALL fractal_schema_context(p_table_names, v_schema_ctx);

    attempt_loop: WHILE v_attempt <= v_max_attempts AND NOT v_done DO
        SET v_prompt = CONCAT(
            'Write a single MariaDB ',
            IF(v_allowed = 'select_insert_update', 'SELECT, INSERT, or UPDATE', 'SELECT'),
            ' statement that answers this question. Return ONLY the SQL, ',
            'wrapped in a ```sql fenced code block, with no other explanation.\n\n',
            'Question: ', p_question, '\n');
        IF v_feedback IS NOT NULL THEN
            SET v_prompt = CONCAT(v_prompt,
                '\nYour previous attempt was rejected for this reason: ', v_feedback,
                '\n\nWrite a corrected statement.\n');
        END IF;

        -- ---- GENERATE ----
        SET v_candidate = fractal_t2s_generate(v_session_id, v_prompt, v_schema_ctx, v_system_tag);
        IF v_candidate IS NULL THEN
            SET out_error = 'fractal_text_to_sql: generate dispatch failed';
            SET v_done = TRUE;
            ITERATE attempt_loop;
        END IF;
        -- Strip a harmless trailing ";" (and any whitespace around it):
        -- models routinely emit one, and while MariaDB tolerates it in a
        -- top-level PREPARE, a caller (e.g. fractal_sql_agent) wrapping
        -- this returned text in "(...)  AS x" for a derived-table query
        -- would otherwise get a genuine syntax error from the embedded
        -- semicolon. Normalized here so every caller of this procedure's
        -- out_sql gets clean, embeddable SQL text, not just this
        -- procedure's own internal PREPARE check.
        SET v_candidate = TRIM(v_candidate);
        IF RIGHT(v_candidate, 1) = ';' THEN
            SET v_candidate = TRIM(LEFT(v_candidate, CHAR_LENGTH(v_candidate) - 1));
        END IF;

        -- ---- ALLOWLIST ----
        SET v_check_err = fractal_t2s_check_allowlist(v_candidate);
        IF v_check_err IS NOT NULL THEN
            SET v_feedback = v_check_err;
            IF v_attempt >= v_max_attempts THEN
                SET out_error = CONCAT('fractal_text_to_sql: exhausted ', v_max_attempts,
                                        ' attempt(s), last rejection: ', v_feedback);
                SET v_done = TRUE;
            END IF;
            SET v_attempt = v_attempt + 1;
            ITERATE attempt_loop;
        END IF;

        -- ---- REVIEW (optional, default off) ----
        IF v_use_review THEN
            SET v_check_err = fractal_t2s_review(v_session_id, p_question, v_candidate);
            IF v_check_err IS NOT NULL THEN
                SET v_feedback = v_check_err;
                IF v_attempt >= v_max_attempts THEN
                    SET out_error = CONCAT('fractal_text_to_sql: exhausted ', v_max_attempts,
                                            ' attempt(s), last review verdict: ', v_feedback);
                    SET v_done = TRUE;
                END IF;
                SET v_attempt = v_attempt + 1;
                ITERATE attempt_loop;
            END IF;
        END IF;

        -- ---- EXPLAIN-equivalent (mandatory): see this procedure's
        -- own header comment for why this is PREPARE-only. ----
        SET v_prep_ok   = TRUE;
        SET v_check_err = NULL;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS CONDITION 1 v_check_err = MESSAGE_TEXT;
                SET v_prep_ok = FALSE;
            END;
            SET @_fractalsql_t2s_prep_sql = v_candidate;
            PREPARE _fractalsql_t2s_stmt FROM @_fractalsql_t2s_prep_sql;
            IF v_prep_ok THEN
                DEALLOCATE PREPARE _fractalsql_t2s_stmt;
            END IF;
        END;

        IF NOT v_prep_ok THEN
            SET v_feedback = v_check_err;
            IF v_attempt >= v_max_attempts THEN
                SET out_error = CONCAT('fractal_text_to_sql: exhausted ', v_max_attempts,
                                        ' attempt(s), last EXPLAIN error: ', v_feedback);
                SET v_done = TRUE;
            END IF;
            SET v_attempt = v_attempt + 1;
            ITERATE attempt_loop;
        END IF;

        -- ---- RETURN. Never auto-executed. ----
        -- Best-effort audit-chain provenance for this successful
        -- generation (only the winning attempt is logged, not the failed
        -- ones). Harmless NULL on a Community deployment: fractal_audit_
        -- log is enterprise-tier (see docs/enterprise.md).
        SET v_audit = fractal_audit_log('text_to_sql',
            JSON_OBJECT('question', p_question, 'generated_sql', v_candidate,
                        'attempt', v_attempt, 'allowed_statements', v_allowed));
        SET out_sql = v_candidate;
        SET v_done  = TRUE;
    END WHILE;
END$$

-- fractal_sql_agent(question, table_names, max_retries, auto_execute,
--   OUT generated_sql, OUT status, OUT result_json)
-- Self-correcting Text-to-SQL, with an OPTIONAL auto-execute step:
-- unlike fractal_text_to_sql (which is never auto-executed), this is
-- the "just run it" entry point fractal_agent_data_analyst composes.
-- status is one of 'success' (validated, not executed,
-- auto_execute=false), 'validation_failed', 'executed', or
-- 'execution_failed'. result_json carries {"rows":N} on a successful
-- execution, or {"status":"validation_failed"/"execution_failed",
-- "error":"..."} otherwise.
--
-- Deliberately NOT implemented as "CALL fractal_text_to_sql, then
-- optionally execute the result": that would silently ignore
-- max_retries (fractal_text_to_sql's own retry bound comes from
-- FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS, a process-wide env var, not a
-- per-call override) and give a caller-supplied max_retries no real
-- effect. This procedure runs its OWN GENERATE/ALLOWLIST/EXPLAIN-
-- equivalent retry loop instead, bounded by max_retries directly.
-- fractal_sql_agent and fractal_text_to_sql are independent
-- implementations sharing only the low-level generate call, not one
-- calling the other, at the cost of a small amount of duplicated loop
-- structure between them.
--
-- auto_execute's SELECT handling: unlike a literal EXECUTE of the
-- candidate (which would leak the query's own result set out of this
-- procedure's CALL as a surprise second result set: every other
-- procedure in this install script has exactly one well-defined output,
-- the OUT params), a validated SELECT is re-run wrapped in
-- "SELECT COUNT(*) FROM (<candidate>) x" so result_json can report a
-- real row count ({"status":"executed","rows":N}, never the actual
-- row data, for the same "do not silently return whatever columns an
-- LLM decided to select" reason). INSERT/UPDATE gets its row count from
-- ROW_COUNT() after a plain EXECUTE instead (no result set to worry
-- about for those statement types at all).
DELIMITER $$

CREATE PROCEDURE fractal_sql_agent(
    IN  p_question      TEXT,
    IN  p_table_names   JSON,
    IN  p_max_retries   INT,
    IN  p_auto_execute  BOOLEAN,
    OUT p_generated_sql TEXT,
    OUT p_status        VARCHAR(20),
    OUT p_result_json   JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_session_id   BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE v_max_retries  INT DEFAULT IFNULL(p_max_retries, 2);
    DECLARE v_system_tag   VARCHAR(32);
    DECLARE v_schema_ctx   LONGTEXT;
    DECLARE v_feedback     TEXT DEFAULT NULL;
    DECLARE v_candidate    TEXT DEFAULT NULL;
    DECLARE v_prompt       TEXT;
    DECLARE v_check_err    TEXT DEFAULT NULL;
    DECLARE v_attempt      INT DEFAULT 1;
    DECLARE v_prep_ok      BOOLEAN DEFAULT TRUE;
    DECLARE v_passed       BOOLEAN DEFAULT FALSE;
    DECLARE v_done         BOOLEAN DEFAULT FALSE;
    DECLARE v_kw           VARCHAR(16);
    DECLARE v_row_count    INT DEFAULT 0;
    DECLARE v_exec_ok      BOOLEAN DEFAULT TRUE;

    SET p_generated_sql = NULL;
    SET p_status        = NULL;
    SET p_result_json   = NULL;

    IF p_question IS NULL OR TRIM(p_question) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_sql_agent: question must not be empty';
    END IF;
    IF v_max_retries < 1 THEN SET v_max_retries = 1; END IF;

    SET v_system_tag = CONCAT('mariadb',
        REPLACE(SUBSTRING_INDEX(SUBSTRING_INDEX(VERSION(), '-', 1), '.', 2), '.', ''));

    CALL fractal_schema_context(p_table_names, v_schema_ctx);

    attempt_loop: WHILE v_attempt <= v_max_retries AND NOT v_done DO
        SET v_prompt = CONCAT(
            'Write a single MariaDB SELECT, INSERT, or UPDATE statement that answers ',
            'this question. Return ONLY the SQL, wrapped in a ```sql fenced code ',
            'block, with no other explanation.\n\nQuestion: ', p_question, '\n');
        IF v_feedback IS NOT NULL THEN
            SET v_prompt = CONCAT(v_prompt,
                '\nYour previous attempt was rejected for this reason: ', v_feedback,
                '\n\nWrite a corrected statement.\n');
        END IF;

        SET v_candidate = fractal_t2s_generate(v_session_id, v_prompt, v_schema_ctx, v_system_tag);
        IF v_candidate IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_sql_agent: generate dispatch failed';
        END IF;
        -- See fractal_text_to_sql's identical comment: strip a harmless
        -- trailing ";" so wrapping v_candidate in "(...) AS x" below
        -- (the SELECT-count path) doesn't get a syntax error from an
        -- embedded semicolon.
        SET v_candidate = TRIM(v_candidate);
        IF RIGHT(v_candidate, 1) = ';' THEN
            SET v_candidate = TRIM(LEFT(v_candidate, CHAR_LENGTH(v_candidate) - 1));
        END IF;
        SET p_generated_sql = v_candidate;

        SET v_check_err = fractal_t2s_check_allowlist(v_candidate);
        IF v_check_err IS NOT NULL THEN
            SET v_feedback = v_check_err;
            SET v_attempt = v_attempt + 1;
            ITERATE attempt_loop;
        END IF;

        SET v_prep_ok = TRUE;
        SET v_check_err = NULL;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS CONDITION 1 v_check_err = MESSAGE_TEXT;
                SET v_prep_ok = FALSE;
            END;
            SET @_fractalsql_sa_prep_sql = v_candidate;
            PREPARE _fractalsql_sa_stmt FROM @_fractalsql_sa_prep_sql;
            IF v_prep_ok THEN
                DEALLOCATE PREPARE _fractalsql_sa_stmt;
            END IF;
        END;

        IF NOT v_prep_ok THEN
            SET v_feedback = v_check_err;
            SET v_attempt = v_attempt + 1;
            ITERATE attempt_loop;
        END IF;

        SET v_passed = TRUE;
        SET v_done   = TRUE;
    END WHILE;

    IF NOT v_passed THEN
        SET p_status = 'validation_failed';
        SET p_result_json = JSON_OBJECT('status', 'validation_failed', 'error', v_feedback);
    ELSEIF NOT IFNULL(p_auto_execute, FALSE) THEN
        SET p_status = 'success';
    ELSE
        -- Classify the (already-allowlisted) candidate's leading keyword
        -- to decide how to execute it and how to report a row count.
        -- See this procedure's own header comment on why a SELECT is
        -- re-run wrapped in COUNT(*) rather than executed directly.
        SET v_kw = UPPER(SUBSTRING_INDEX(TRIM(v_candidate), ' ', 1));

        SET v_exec_ok = TRUE;
        SET v_check_err = NULL;
        BEGIN
            -- v_prepared: same reasoning as fractal_vectorizer_process_
            -- queue's read_text_block/write_embed_block (see that
            -- procedure's comment) -- without it, a PREPARE failure here
            -- (e.g. the executing role lacks a privilege v_candidate
            -- needs) falls through to an EXECUTE/DEALLOCATE against a
            -- never-prepared handle, and the CONTINUE HANDLER's second
            -- (and third) exception overwrites v_check_err with a
            -- confusing "Unknown prepared statement handler" instead of
            -- the real cause.
            DECLARE v_prepared BOOLEAN DEFAULT FALSE;
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS CONDITION 1 v_check_err = MESSAGE_TEXT;
                SET v_exec_ok = FALSE;
            END;

            IF v_kw = 'SELECT' OR v_kw = 'WITH' THEN
                SET @_fractalsql_sa_exec_sql = CONCAT('SELECT COUNT(*) INTO @_fractalsql_sa_rowcount FROM (', v_candidate, ') AS _fractalsql_sa_x');
                SET @_fractalsql_sa_rowcount = NULL;
                PREPARE _fractalsql_sa_exec_stmt FROM @_fractalsql_sa_exec_sql;
                IF v_exec_ok THEN
                    SET v_prepared = TRUE;
                    EXECUTE _fractalsql_sa_exec_stmt;
                END IF;
                IF v_prepared THEN
                    DEALLOCATE PREPARE _fractalsql_sa_exec_stmt;
                END IF;
                SET v_row_count = @_fractalsql_sa_rowcount;
            ELSE
                SET @_fractalsql_sa_exec_sql = v_candidate;
                PREPARE _fractalsql_sa_exec_stmt FROM @_fractalsql_sa_exec_sql;
                IF v_exec_ok THEN
                    SET v_prepared = TRUE;
                    EXECUTE _fractalsql_sa_exec_stmt;
                END IF;
                -- ROW_COUNT() must be read HERE, immediately after
                -- EXECUTE (only when it actually ran) -- DEALLOCATE
                -- PREPARE is itself a statement and resets ROW_COUNT()
                -- to 0, so reading it after that line would always
                -- report 0 regardless of how many rows the INSERT/UPDATE
                -- actually affected, even though the row itself lands in
                -- the table correctly.
                IF v_prepared THEN
                    SET v_row_count = ROW_COUNT();
                    DEALLOCATE PREPARE _fractalsql_sa_exec_stmt;
                END IF;
            END IF;
        END;

        IF v_exec_ok THEN
            SET p_status = 'executed';
            SET p_result_json = JSON_OBJECT('status', 'executed', 'rows', v_row_count);
        ELSE
            SET p_status = 'execution_failed';
            SET p_result_json = JSON_OBJECT('status', 'execution_failed', 'error', v_check_err);
        END IF;
    END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- v2.0.0, Vectorizer pipeline
--
-- Pure SQL/PSM (no new C symbols): fractal_embed() above is the only
-- C-level piece this depends on. Four notable MariaDB-specific design
-- points, each verified against a real MariaDB 11.4 server:
--
--   1. Trigger genericity. MariaDB triggers cannot take arguments and
--      are bound to exactly one table, so fractal_vectorizer_create()
--      below dynamically CREATEs two small per-table, per-vectorizer
--      triggers (AFTER INSERT, AFTER UPDATE) via PREPARE/EXECUTE, each
--      just CALLing the one shared _fractalsql_vectorizer_enqueue
--      procedure with vectorizer_id and NEW's PK value baked in as
--      literals. Verified that CREATE TRIGGER is actually valid as a
--      PREPARE/EXECUTE target in MariaDB (a real, version-dependent
--      restriction on some MySQL-family servers, so this was checked
--      directly rather than assumed) and that a trigger CALLing a
--      stored procedure fires and enqueues correctly.
--   2. "AFTER UPDATE OF text_col" has no MariaDB equivalent (no "OF
--      column_list" clause on CREATE TRIGGER), so the generated AFTER
--      UPDATE trigger instead wraps its body in
--      "IF NOT (OLD.col <=> NEW.col) THEN ... END IF" (MariaDB's
--      null-safe equality operator) to reproduce "only when text_col
--      actually changed."
--   3. Partial unique index. "At most one pending/processing row per
--      (vectorizer_id, source_pk_value)" needs a partial/filtered
--      unique index, which MariaDB has no equivalent for at all.
--      Reproduced via a VIRTUAL generated column (active_key, NULL
--      unless status is pending/processing) with a plain UNIQUE index
--      on it: multiple NULLs coexist freely in a unique index
--      (standard SQL), so done/failed rows never collide, while two
--      active rows for the same (vectorizer_id, pk) do collide.
--   4. Row-level batch claiming. Under autocommit=1 (MariaDB's
--      default), each statement inside a stored procedure commits and
--      releases its locks independently unless the procedure
--      explicitly opens a transaction, so a FOR-UPDATE-then-slow-loop
--      cursor pattern would NOT actually protect a batch from a
--      second, concurrent call to the same procedure. Implemented
--      instead as a single atomic
--      "UPDATE ... JOIN ... SET status='processing', claim_token=@token
--      ... LIMIT batch_size" that claims the whole batch in one
--      statement (no cross-statement lock-holding required at all),
--      tagged with a fresh UUID() per call so a subsequent cursor can
--      select back exactly (and only) the rows THIS call just claimed.
--      claim_token exists specifically to work around the lack of
--      UPDATE ... RETURNING.
--
-- Security model (verified directly): MariaDB stored routines and
-- triggers default to SQL SECURITY DEFINER (the CREATOR's
-- privileges). That means _fractalsql_vectorizer_enqueue and the
-- generated triggers need NO explicit security clause to get "any
-- role that can write the source table can enqueue, without needing
-- its own direct grant on fractal_vectorizer_queue." fractal_vectorizer_
-- create() below, by contrast, MUST be explicitly marked SQL SECURITY
-- INVOKER (opposite of MariaDB's own default): its CREATE TRIGGER step
-- is what actually enforces "caller must own/have TRIGGER privilege on
-- source_table," and that check only works correctly under the
-- CALLING role's own privileges. A DEFINER version would let any role
-- install a trigger on any table by riding the definer's privileges, a
-- real escalation, not a shortcut.
--
-- No PUBLIC grants: MariaDB has no PUBLIC pseudo-role/grant target at
-- all. "GRANT ... TO PUBLIC" is not valid MariaDB syntax (verified
-- directly). These tables are created by whoever runs this install
-- script (typically an admin/DBA role); grant SELECT/INSERT/
-- UPDATE on fractal_vectorizers/fractal_vectorizer_queue/fractal_
-- vectorizer_rate_window to whatever application role(s) need to call
-- fractal_vectorizer_create/_pause/_resume/_process_queue explicitly,
-- the same as any other extension-owned table: no different from how
-- every other table/function in this install script already relies on
-- the connecting role's own privileges rather than a blanket grant.
--
-- embedding_col type handling: MariaDB does not implicitly convert a
-- fractal_vector JSON-array-string into a native VECTOR(n) column on
-- assignment. fractal_vectorizer_create() checks embedding_col's actual
-- information_schema.columns.data_type ONCE at creation time and caches
-- the result (fractal_vectorizers.embedding_is_vector_type); fractal_
-- vectorizer_process_queue() then wraps the write-back in VEC_FROMTEXT()
-- only when that flag is set, so this works unchanged whether
-- embedding_col is a portable TEXT/JSON column (works on every
-- supported major, 10.6-12.3) or a native VECTOR(n) column
-- (MariaDB 11.7.1+, matching the Vector group's own documented
-- dual-path convention above).
-- ---------------------------------------------------------------------

DELIMITER $$

CREATE FUNCTION _fractalsql_quote_ident(name VARCHAR(128)) RETURNS VARCHAR(258)
    DETERMINISTIC
    SQL SECURITY INVOKER
    NO SQL

BEGIN
    RETURN CONCAT('`', REPLACE(name, '`', '``'), '`');
END$$

DELIMITER ;

CREATE TABLE IF NOT EXISTS fractal_vectorizers (
    id                        BIGINT AUTO_INCREMENT PRIMARY KEY,
    source_table              VARCHAR(128) NOT NULL,
    source_pk_col             VARCHAR(64)  NOT NULL,
    text_col                  VARCHAR(64)  NOT NULL,
    embedding_col             VARCHAR(64)  NOT NULL,
    -- Cached once at fractal_vectorizer_create() time. See this
    -- section's header comment on why the write-back path needs this.
    embedding_is_vector_type  BOOLEAN NOT NULL DEFAULT FALSE,
    options                   JSON NOT NULL DEFAULT '{}',
    -- Pause/resume: false stops BOTH future enqueueing (the generated
    -- triggers no-op) AND processing of already-pending rows
    -- (process_queue()'s claim step excludes it), a full pause, not
    -- just "stop enqueueing." Defaults true so a freshly created
    -- vectorizer is immediately active.
    enabled                   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_fractal_vectorizer (source_table, text_col, embedding_col)
) COMMENT = 'One row per fractal_vectorizer_create() call: which table/columns are being kept embedded, and how. See fractal_vectorizer_queue for the actual work queue and fractal_vectorizer_status for observability.';

CREATE TABLE IF NOT EXISTS fractal_vectorizer_queue (
    id                     BIGINT AUTO_INCREMENT PRIMARY KEY,
    vectorizer_id          BIGINT NOT NULL,
    source_pk_value        VARCHAR(255) NOT NULL,
    status                 VARCHAR(16) NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'processing', 'done', 'failed')),
    error                  TEXT,
    -- See this section's header comment (point 4) on why batch claims
    -- use a token instead of a SELECT ... FOR UPDATE cursor here.
    claim_token             CHAR(36) DEFAULT NULL,
    created_at             TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processing_started_at  TIMESTAMP NULL DEFAULT NULL,
    updated_at             TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    -- Partial-unique-index emulation. See this section's header
    -- comment (point 3). NULL for done/failed rows (freely
    -- coexist); a real value for pending/processing rows (must be
    -- unique per vectorizer+pk).
    active_key             VARCHAR(320) GENERATED ALWAYS AS (
                              CASE WHEN status IN ('pending', 'processing')
                                   THEN CONCAT(vectorizer_id, ':', source_pk_value)
                                   ELSE NULL END
                            ) VIRTUAL,
    CONSTRAINT fk_fractal_vectorizer_queue_vectorizer
        FOREIGN KEY (vectorizer_id) REFERENCES fractal_vectorizers(id) ON DELETE CASCADE,
    UNIQUE KEY uq_fractal_vectorizer_queue_active (active_key),
    KEY idx_fractal_vectorizer_queue_pending_scan (created_at)
) COMMENT = 'Work queue for the vectorizer. A status column + timestamp does the job at this scale.';

CREATE TABLE IF NOT EXISTS fractal_vectorizer_rate_window (
    vectorizer_id  BIGINT PRIMARY KEY,
    window_start   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    window_calls   INT NOT NULL DEFAULT 0,
    CONSTRAINT fk_fractal_vectorizer_rate_window_vectorizer
        FOREIGN KEY (vectorizer_id) REFERENCES fractal_vectorizers(id) ON DELETE CASCADE
) COMMENT = 'Rolling-window embed-call counter for vectorizers with options.max_embeds_per_window set.';

DELIMITER $$

-- Shared enqueue step, CALLed by every generated per-table trigger
-- (see this section's header comment, point 1). SQL SECURITY
-- DEFINER is MariaDB's default for a CREATE PROCEDURE with no explicit
-- clause; stated here explicitly anyway, so a reader doesn't have to
-- know the engine's default to understand the security posture.
CREATE PROCEDURE _fractalsql_vectorizer_enqueue(
    IN p_vectorizer_id BIGINT,
    IN p_pk_val        VARCHAR(255)
)
SQL SECURITY DEFINER

BEGIN
    DECLARE v_enabled BOOLEAN DEFAULT FALSE;

    -- COALESCE-equivalent fail-safe: if the vectorizer row is somehow
    -- gone (shouldn't happen: ON DELETE CASCADE drops queue rows
    -- together with it, but not a still-installed trigger on some
    -- other table), v_enabled stays at its DEFAULT FALSE and this is a
    -- silent no-op, not an error thrown from inside the caller's own
    -- INSERT/UPDATE.
    SELECT enabled INTO v_enabled FROM fractal_vectorizers WHERE id = p_vectorizer_id;

    IF v_enabled THEN
        INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value)
        VALUES (p_vectorizer_id, p_pk_val)
        ON DUPLICATE KEY UPDATE fractal_vectorizer_queue.id = fractal_vectorizer_queue.id;   -- no-op on an active-row conflict
    END IF;
END$$

-- fractal_vectorizer_create(source_table, text_col, embedding_col,
--   options, OUT id)
-- Starts keeping embedding_col in sync with text_col on source_table:
-- installs AFTER INSERT/UPDATE triggers that queue rows on write, and
-- immediately backfills any existing rows missing an embedding.
-- Requires source_table (a bare, unqualified name in the CURRENT
-- database: no cross-database vectorizer sources, chosen to match
-- MariaDB's own database/schema terminology) to have a single-column
-- PRIMARY KEY. Call
-- fractal_vectorizer_process_queue() on whatever schedule fits your
-- platform (OS cron, a MariaDB EVENT, your own app scheduler; this
-- installs no scheduler of its own) to actually generate the
-- embeddings.
--
-- SQL SECURITY INVOKER: see this section's header comment for why
-- this one function must NOT use MariaDB's own DEFINER default.
CREATE PROCEDURE fractal_vectorizer_create(
    IN  p_source_table  VARCHAR(128),
    IN  p_text_col      VARCHAR(64),
    IN  p_embedding_col VARCHAR(64),
    IN  p_options       JSON,
    OUT p_id            BIGINT
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_pk_col       VARCHAR(64);
    DECLARE v_pk_count     INT DEFAULT 0;
    DECLARE v_embed_type   VARCHAR(64) DEFAULT NULL;
    DECLARE v_embed_is_vec BOOLEAN DEFAULT FALSE;
    DECLARE v_found        INT DEFAULT 0;
    DECLARE v_dup_id       BIGINT DEFAULT NULL;
    DECLARE v_ins_trg      VARCHAR(80);
    DECLARE v_upd_trg      VARCHAR(80);

    IF p_source_table LIKE '%.%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_vectorizer_create: schema-qualified source_table is not supported, pass a bare table name in the current database';
    END IF;

    SELECT COUNT(*) INTO v_found FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = p_source_table AND table_type = 'BASE TABLE';
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_vectorizer_create: source_table not found in the current database';
    END IF;

    SELECT COUNT(*) INTO v_found FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_source_table AND column_name = p_text_col;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_vectorizer_create: text_col not found on source_table';
    END IF;

    SELECT COUNT(*), MIN(data_type) INTO v_found, v_embed_type FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_source_table AND column_name = p_embedding_col;
    IF v_found = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_vectorizer_create: embedding_col not found on source_table';
    END IF;
    SET v_embed_is_vec = (LOWER(v_embed_type) = 'vector');

    SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_source_table AND constraint_name = 'PRIMARY';
    IF v_pk_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_vectorizer_create: source_table must have exactly one single-column PRIMARY KEY (composite and missing-PK tables are not supported)';
    END IF;
    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_source_table AND constraint_name = 'PRIMARY'
    LIMIT 1;

    SELECT id INTO v_dup_id FROM fractal_vectorizers
    WHERE source_table = p_source_table AND text_col = p_text_col AND embedding_col = p_embedding_col;
    IF v_dup_id IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_vectorizer_create: a vectorizer for this source_table/text_col/embedding_col already exists';
    END IF;

    INSERT INTO fractal_vectorizers
        (source_table, source_pk_col, text_col, embedding_col, embedding_is_vector_type, options)
    VALUES
        (p_source_table, v_pk_col, p_text_col, p_embedding_col, v_embed_is_vec, IFNULL(p_options, JSON_OBJECT()));
    SET p_id = LAST_INSERT_ID();

    SET v_ins_trg = CONCAT('_fsql_vec_', p_id, '_ins');
    SET v_upd_trg = CONCAT('_fsql_vec_', p_id, '_upd');

    SET @_fractalsql_vec_ddl = CONCAT(
        'CREATE TRIGGER ', _fractalsql_quote_ident(v_ins_trg), ' AFTER INSERT ON ',
        _fractalsql_quote_ident(p_source_table), ' FOR EACH ROW ',
        'CALL _fractalsql_vectorizer_enqueue(', p_id, ', NEW.', _fractalsql_quote_ident(v_pk_col), ')');
    PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
    EXECUTE _fractalsql_vec_stmt;
    DEALLOCATE PREPARE _fractalsql_vec_stmt;

    SET @_fractalsql_vec_ddl = CONCAT(
        'CREATE TRIGGER ', _fractalsql_quote_ident(v_upd_trg), ' AFTER UPDATE ON ',
        _fractalsql_quote_ident(p_source_table), ' FOR EACH ROW ',
        'IF NOT (OLD.', _fractalsql_quote_ident(p_text_col), ' <=> NEW.', _fractalsql_quote_ident(p_text_col), ') THEN ',
        'CALL _fractalsql_vectorizer_enqueue(', p_id, ', NEW.', _fractalsql_quote_ident(v_pk_col), '); END IF');
    PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
    EXECUTE _fractalsql_vec_stmt;
    DEALLOCATE PREPARE _fractalsql_vec_stmt;

    -- Backfill: queue existing rows that don't have an embedding yet,
    -- not the whole table. A vectorizer retrofitted onto a table that
    -- already has some embeddings shouldn't redo them.
    SET @_fractalsql_vec_ddl = CONCAT(
        'INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value) ',
        'SELECT ', p_id, ', ', _fractalsql_quote_ident(v_pk_col),
        ' FROM ', _fractalsql_quote_ident(p_source_table),
        ' WHERE ', _fractalsql_quote_ident(p_embedding_col), ' IS NULL',
        '   AND ', _fractalsql_quote_ident(p_text_col), ' IS NOT NULL ',
        'ON DUPLICATE KEY UPDATE fractal_vectorizer_queue.id = fractal_vectorizer_queue.id');
    PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
    EXECUTE _fractalsql_vec_stmt;
    DEALLOCATE PREPARE _fractalsql_vec_stmt;
END$$

-- SQL SECURITY INVOKER: a plain UPDATE against fractal_vectorizers,
-- no elevation needed (grant SELECT/UPDATE on it to whichever role
-- calls this, per this section's header comment on grants). Idempotent
-- (pausing an already-paused vectorizer is a no-op, not an error).
CREATE PROCEDURE fractal_vectorizer_pause(IN p_vectorizer_id BIGINT)
SQL SECURITY INVOKER

BEGIN
    UPDATE fractal_vectorizers SET enabled = FALSE WHERE id = p_vectorizer_id;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_vectorizer_pause: no vectorizer with that id';
    END IF;
END$$

CREATE PROCEDURE fractal_vectorizer_resume(IN p_vectorizer_id BIGINT)
SQL SECURITY INVOKER

BEGIN
    UPDATE fractal_vectorizers SET enabled = TRUE WHERE id = p_vectorizer_id;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_vectorizer_resume: no vectorizer with that id';
    END IF;
END$$

-- fractal_vectorizer_drop(vectorizer_id)
-- Permanently deregisters a vectorizer: drops its two enqueue triggers
-- (if source_table still exists -- it may already be gone, e.g. a
-- demo/test fixture reset, in which case its triggers went with it)
-- and deletes its fractal_vectorizers row. fractal_vectorizer_queue and
-- fractal_vectorizer_rate_window rows for it cascade away via their own
-- ON DELETE CASCADE foreign keys.
-- Irreversible -- re-embedding after this needs a fresh
-- fractal_vectorizer_create() call and a full backfill. For a
-- temporary stop that keeps config/history, use
-- fractal_vectorizer_pause() instead. Exists because
-- (source_table, text_col, embedding_col) is UNIQUE on
-- fractal_vectorizers: without a drop path, a vectorizer can never be
-- retargeted or recreated for the same (table, columns) combo.
--
-- SQL SECURITY INVOKER: matches fractal_vectorizer_create's own
-- SQL SECURITY INVOKER (this section's header comment) -- DROP TRIGGER
-- runs with the caller's own privileges, not the definer's.
CREATE PROCEDURE fractal_vectorizer_drop(IN p_vectorizer_id BIGINT)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_source_table VARCHAR(128) DEFAULT NULL;
    DECLARE v_found        INT DEFAULT 0;
    DECLARE v_ins_trg      VARCHAR(80);
    DECLARE v_upd_trg      VARCHAR(80);

    SELECT source_table INTO v_source_table FROM fractal_vectorizers WHERE id = p_vectorizer_id;
    IF v_source_table IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_vectorizer_drop: no vectorizer with that id';
    END IF;

    SELECT COUNT(*) INTO v_found FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = v_source_table AND table_type = 'BASE TABLE';

    IF v_found > 0 THEN
        SET v_ins_trg = CONCAT('_fsql_vec_', p_vectorizer_id, '_ins');
        SET v_upd_trg = CONCAT('_fsql_vec_', p_vectorizer_id, '_upd');

        SET @_fractalsql_vec_ddl = CONCAT('DROP TRIGGER IF EXISTS ', _fractalsql_quote_ident(v_ins_trg));
        PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
        EXECUTE _fractalsql_vec_stmt;
        DEALLOCATE PREPARE _fractalsql_vec_stmt;

        SET @_fractalsql_vec_ddl = CONCAT('DROP TRIGGER IF EXISTS ', _fractalsql_quote_ident(v_upd_trg));
        PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
        EXECUTE _fractalsql_vec_stmt;
        DEALLOCATE PREPARE _fractalsql_vec_stmt;
    END IF;

    -- fractal_vectorizer_queue and fractal_vectorizer_rate_window rows
    -- cascade via their own REFERENCES fractal_vectorizers(id)
    -- ON DELETE CASCADE.
    DELETE FROM fractal_vectorizers WHERE id = p_vectorizer_id;
END$$

-- fractal_vectorizer_process_queue([batch_size], [stale_after_secs])
--   -> selects into @fractal_vectorizer_n_processed (see below)
-- Process up to batch_size pending queue rows: read the source text,
-- call fractal_embed(), write the vector back, mark done or failed.
-- Concurrency-safe against another simultaneous call to this same
-- procedure (see this section's header comment, point 4: the
-- atomic claim-UPDATE). Also reclaims rows stuck in
-- 'processing' for longer than stale_after_secs (a caller that crashed
-- mid-batch). Skips any vectorizer paused via fractal_vectorizer_pause,
-- and honors a per-vectorizer options.max_embeds_per_window rate cap if
-- one is set. A MariaDB PROCEDURE cannot RETURN a scalar, so the row
-- count actually processed (done +
-- failed; a row deferred by the rate cap or belonging to a paused
-- vectorizer isn't counted) is returned via a plain SELECT as this
-- procedure's own result set instead.
CREATE PROCEDURE fractal_vectorizer_process_queue(
    IN p_batch_size       INT,
    IN p_stale_after_secs INT
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_batch_size  INT DEFAULT IFNULL(p_batch_size, 100);
    DECLARE v_stale_secs  INT DEFAULT IFNULL(p_stale_after_secs, 600);
    DECLARE v_token       CHAR(36) DEFAULT UUID();
    DECLARE v_n_processed INT DEFAULT 0;

    DECLARE v_done      BOOLEAN DEFAULT FALSE;
    DECLARE v_q_id       BIGINT;
    DECLARE v_vectorizer_id BIGINT;
    DECLARE v_pk_value   VARCHAR(255);
    DECLARE v_source_table VARCHAR(128);
    DECLARE v_source_pk_col VARCHAR(64);
    DECLARE v_text_col   VARCHAR(64);
    DECLARE v_embedding_col VARCHAR(64);
    DECLARE v_embed_is_vec BOOLEAN;
    DECLARE v_options    JSON;

    DECLARE v_max_calls    INT;
    DECLARE v_window_secs  INT;
    DECLARE v_window_start TIMESTAMP;
    DECLARE v_window_calls INT;

    DECLARE v_text  TEXT;
    DECLARE v_vec   TEXT;
    DECLARE v_row_ok BOOLEAN;
    DECLARE v_row_err TEXT;

    DECLARE cur CURSOR FOR
        SELECT q.id, q.vectorizer_id, q.source_pk_value,
               v.source_table, v.source_pk_col, v.text_col, v.embedding_col,
               v.embedding_is_vector_type, v.options
        FROM fractal_vectorizer_queue q
        JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
        WHERE q.claim_token = v_token;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- Reclaim rows stranded in 'processing' by a caller that crashed or
    -- was killed mid-batch.
    UPDATE fractal_vectorizer_queue
       SET status = 'pending', processing_started_at = NULL, claim_token = NULL
     WHERE status = 'processing'
       AND processing_started_at < (NOW() - INTERVAL v_stale_secs SECOND);

    -- Atomically claim up to v_batch_size pending rows belonging to an
    -- enabled vectorizer, one statement, no cross-statement lock-
    -- holding required (see this section's header comment, divergence
    -- 4).
    UPDATE fractal_vectorizer_queue q
      JOIN fractal_vectorizers v ON v.id = q.vectorizer_id
       SET q.status = 'processing', q.processing_started_at = NOW(), q.claim_token = v_token
     WHERE q.status = 'pending' AND v.enabled
     ORDER BY q.created_at
     LIMIT v_batch_size;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_q_id, v_vectorizer_id, v_pk_value,
                       v_source_table, v_source_pk_col, v_text_col, v_embedding_col,
                       v_embed_is_vec, v_options;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        -- Per-vectorizer rate cap, read from `options` fresh on every
        -- row (not cached across the loop) so a cap edited mid-batch
        -- takes effect on the very next row. No-op (v_max_calls IS
        -- NULL) for any vectorizer that hasn't set
        -- options.max_embeds_per_window.
        SET v_max_calls = JSON_VALUE(v_options, '$.max_embeds_per_window');

        IF v_max_calls IS NOT NULL THEN
            SET v_window_secs = IFNULL(JSON_VALUE(v_options, '$.rate_window_secs'), 3600);

            INSERT IGNORE INTO fractal_vectorizer_rate_window (vectorizer_id, window_start, window_calls)
            VALUES (v_vectorizer_id, NOW(), 0);

            SELECT window_start, window_calls INTO v_window_start, v_window_calls
            FROM fractal_vectorizer_rate_window
            WHERE vectorizer_id = v_vectorizer_id;

            IF TIMESTAMPDIFF(SECOND, v_window_start, NOW()) > v_window_secs THEN
                SET v_window_start = NOW();
                SET v_window_calls = 0;
            END IF;

            IF v_window_calls >= v_max_calls THEN
                -- Cap hit for this vectorizer's current window: put the
                -- row back to 'pending' (it was claimed above but never
                -- actually processed) and move on to the next queue row,
                -- which may belong to a different, uncapped vectorizer.
                -- Not counted in v_n_processed, since it wasn't
                -- processed, just deferred.
                UPDATE fractal_vectorizer_queue
                   SET status = 'pending', processing_started_at = NULL, claim_token = NULL
                 WHERE id = v_q_id;
                ITERATE read_loop;
            END IF;

            UPDATE fractal_vectorizer_rate_window
               SET window_start = v_window_start, window_calls = v_window_calls + 1
             WHERE vectorizer_id = v_vectorizer_id;
        END IF;

        SET v_row_ok = TRUE;
        SET v_row_err = NULL;
        SET v_text = NULL;

        read_text_block: BEGIN
            -- v_prepared tracks PREPARE's own success SEPARATELY from
            -- v_row_ok: if PREPARE itself fails (e.g. permission denied
            -- on v_source_table under SQL SECURITY INVOKER -- confirmed
            -- live, gate 16), a plain CONTINUE HANDLER resumes at the
            -- very next statement, so an unguarded EXECUTE/DEALLOCATE
            -- would then fail AGAIN on the never-prepared handle,
            -- overwriting v_row_err with a confusing "Unknown prepared
            -- statement handler" instead of the real cause. Guarding
            -- EXECUTE on v_row_ok isn't enough by itself either: if
            -- EXECUTE (not PREPARE) is what fails, v_row_ok flips to
            -- FALSE but the statement WAS successfully prepared and
            -- still needs deallocating, or it leaks for the rest of the
            -- session and the next loop iteration's same-named PREPARE
            -- fails outright. v_prepared is set only once PREPARE has
            -- actually succeeded, so DEALLOCATE runs exactly when there
            -- is something to deallocate, independent of whether EXECUTE
            -- itself went on to succeed.
            DECLARE v_prepared BOOLEAN DEFAULT FALSE;
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS CONDITION 1 v_row_err = MESSAGE_TEXT;
                SET v_row_ok = FALSE;
            END;
            SET @_fractalsql_vec_ddl = CONCAT(
                'SELECT ', _fractalsql_quote_ident(v_text_col), ' INTO @_fractalsql_vec_text',
                ' FROM ', _fractalsql_quote_ident(v_source_table),
                ' WHERE ', _fractalsql_quote_ident(v_source_pk_col), ' = ', QUOTE(v_pk_value));
            SET @_fractalsql_vec_text = NULL;
            PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
            IF v_row_ok THEN
                SET v_prepared = TRUE;
                EXECUTE _fractalsql_vec_stmt;
            END IF;
            IF v_prepared THEN
                DEALLOCATE PREPARE _fractalsql_vec_stmt;
            END IF;
            SET v_text = @_fractalsql_vec_text;
        END read_text_block;

        IF NOT v_row_ok THEN
            UPDATE fractal_vectorizer_queue
               SET status = 'failed', error = v_row_err, updated_at = NOW()
             WHERE id = v_q_id;
        ELSEIF v_text IS NULL THEN
            -- Source row deleted, or its text column went NULL, since
            -- this queue entry was created: nothing to embed, not a
            -- failure.
            UPDATE fractal_vectorizer_queue
               SET status = 'done', updated_at = NOW(), error = NULL
             WHERE id = v_q_id;
        ELSE
            write_embed_block: BEGIN
                -- Same v_prepared guard as read_text_block above, same
                -- reason: an unguarded EXECUTE/DEALLOCATE after a failed
                -- PREPARE (e.g. no UPDATE privilege on v_source_table)
                -- overwrites the real error with a confusing secondary
                -- one, and an unguarded DEALLOCATE after a failed EXECUTE
                -- (PREPARE succeeded) would skip freeing a handle that
                -- genuinely needs freeing.
                DECLARE v_prepared BOOLEAN DEFAULT FALSE;
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
                BEGIN
                    GET DIAGNOSTICS CONDITION 1 v_row_err = MESSAGE_TEXT;
                    SET v_row_ok = FALSE;
                END;

                SET v_vec = fractal_embed(CONNECTION_ID(), v_text);
                IF v_vec IS NULL THEN
                    SET v_row_ok = FALSE;
                    SET v_row_err = 'fractal_embed dispatch failed';
                ELSE
                    SET @_fractalsql_vec_ddl = CONCAT(
                        'UPDATE ', _fractalsql_quote_ident(v_source_table),
                        ' SET ', _fractalsql_quote_ident(v_embedding_col), ' = ',
                        IF(v_embed_is_vec, 'VEC_FROMTEXT(?)', '?'),
                        ' WHERE ', _fractalsql_quote_ident(v_source_pk_col), ' = ', QUOTE(v_pk_value));
                    SET @_fractalsql_vec_val = v_vec;
                    PREPARE _fractalsql_vec_stmt FROM @_fractalsql_vec_ddl;
                    IF v_row_ok THEN
                        SET v_prepared = TRUE;
                        EXECUTE _fractalsql_vec_stmt USING @_fractalsql_vec_val;
                    END IF;
                    IF v_prepared THEN
                        DEALLOCATE PREPARE _fractalsql_vec_stmt;
                    END IF;
                END IF;
            END write_embed_block;

            IF v_row_ok THEN
                UPDATE fractal_vectorizer_queue
                   SET status = 'done', updated_at = NOW(), error = NULL
                 WHERE id = v_q_id;
            ELSE
                UPDATE fractal_vectorizer_queue
                   SET status = 'failed', error = v_row_err, updated_at = NOW()
                 WHERE id = v_q_id;
            END IF;
        END IF;

        SET v_n_processed = v_n_processed + 1;
    END LOOP;
    CLOSE cur;

    SELECT v_n_processed AS n_processed;
END$$

DELIMITER ;

CREATE VIEW fractal_vectorizer_status AS
SELECT v.id AS vectorizer_id,
       v.source_table,
       v.text_col,
       v.embedding_col,
       v.enabled,
       q.status,
       COUNT(*) AS n,
       MAX(CASE WHEN q.status = 'failed' THEN q.updated_at END) AS last_failure_at,
       SUBSTRING_INDEX(
         GROUP_CONCAT(CASE WHEN q.status = 'failed' THEN q.error END
                      ORDER BY q.updated_at DESC SEPARATOR ''),
         '', 1
       ) AS last_error
FROM fractal_vectorizers v
JOIN fractal_vectorizer_queue q ON q.vectorizer_id = v.id
GROUP BY v.id, v.source_table, v.text_col, v.embedding_col, v.enabled, q.status;

-- ---------------------------------------------------------------------
-- v2.0.0, Table-backed top-k telemetry search and compositions
-- (base-tier prerequisite for the Agency tier below)
--
-- fractal_search_telemetry/fractal_hybrid_clinical_search/
-- fractal_search_trajectory/fractal_cross_modal_search are not
-- separate fractalsql-core C ABI primitives: they are SQL/PSM
-- compositions that scan a real table into an in-memory corpus and
-- then call the SAME fsql_search_ptr core primitive fractal_search's
-- own C UDF already wraps, just with a different corpus (cohort-
-- filtered / delta-vector / weighted-concat) and a doc_id remap.
-- Since fractal_search already exists here as a plain SQL-callable UDF
-- (corpus_csv, query_csv, k, params) -> JSON with a
-- "top_k":[{"idx":..,"dist":..}] array, none of these four need ANY
-- new C code at all: they build the corpus in SQL (JSON_ARRAYAGG, with
-- a parallel id list to remap fractal_search's corpus-position idx
-- back to a real row id), call the existing fractal_search UDF, then
-- JSON_TABLE the result. All four return their (doc_id, dist) rows as
-- a JSON array of objects via an OUT param, not a real multi-row
-- result set: unlike a bare SELECT-ending procedure (which DOES
-- produce a real result set when CALLed from a client), a nested
-- CALL's result set cannot be consumed by the CALLING procedure's own
-- body in MariaDB SQL/PSM (no "cursor FOR CALL other_proc(...)"), and
-- the Agency tier's agents need to consume these programmatically from
-- inside their own procedure bodies, so the JSON-array-of-objects
-- convention keeps this composable (a caller wanting real rows can
-- trivially get them via
-- JSON_TABLE(@result, '$[*]' COLUMNS (doc_id BIGINT PATH '$.doc_id',
-- dist DOUBLE PATH '$.dist'))).
--
-- vector_col type handling: same information_schema.columns.data_type
-- check as the Vectorizer's embedding_is_vector_type (above). A
-- native VECTOR(n) column is read via VEC_TOTEXT() first; a portable
-- TEXT/VARCHAR column storing the fractal_vector JSON-array-string
-- convention is used as-is. Either way the per-row vector text is
-- assembled into the corpus via CONCAT('[', GROUP_CONCAT(... SEPARATOR
-- ','), ']'), plain string concatenation, not JSON_ARRAYAGG(...).
-- MariaDB has no CAST(x AS JSON) at all (JSON is an alias for
-- LONGTEXT plus a CHECK(JSON_VALID(...)) constraint, not a distinct
-- type CAST() recognizes as a target), and JSON_ARRAYAGG on a bare
-- TEXT column whose value already IS valid JSON array text produces
-- an array of quoted JSON STRING literals ("[1,2,3]"), not a real
-- nested array; fractal_search's corpus parser needs the latter.
-- The id lists (real row ids, plain scalars, never pre-JSON-encoded
-- text) use JSON_ARRAYAGG normally, with no such gap.
-- ---------------------------------------------------------------------

DELIMITER $$

-- Shared core, CALLed by all four public primitives below. p_corpus_json
-- is a JSON array of row-vectors (each a JSON array of numbers) in the
-- SAME order as p_ids_json (a parallel JSON array of the real row ids
-- fractal_search's 0-based corpus-position idx should be remapped to).
CREATE PROCEDURE _fractalsql_telemetry_topk(
    IN  p_corpus_json JSON,
    IN  p_ids_json    JSON,
    IN  p_query_json  JSON,
    IN  p_k           INT,
    OUT p_result_json JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_params VARCHAR(200);
    DECLARE v_search_result TEXT;

    IF p_k IS NULL OR p_k <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '_fractalsql_telemetry_topk: k must be > 0';
    END IF;
    IF p_corpus_json IS NULL OR JSON_LENGTH(p_corpus_json) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '_fractalsql_telemetry_topk: no corpus rows to search';
    END IF;

    -- "session_id": CONNECTION_ID(). Without this, fractal_search runs
    -- against an anonymous, session-less ctx, and Diversify/Repulsion
    -- state (fractal_diversify_enable/_set_params) enabled on THIS
    -- connection's own session never actually applies to searches made
    -- through fractal_search_telemetry/fractal_hybrid_clinical_search/
    -- fractal_search_trajectory/fractal_cross_modal_search. Without
    -- this, those searches silently run against a different ctx than
    -- the one fractal_diversify_enable(CONNECTION_ID()) configured, so
    -- fractal_agent_feedback_audit's D_q rolling window would never
    -- warm up no matter how many telemetry searches ran. See
    -- fractal_search's own "session_id" params-JSON key (fractalsql.c)
    -- for the convention this threads into.
    SET v_params = CONCAT(
        '{"max_generation":15,"population_size":50,"maximum_diffusion":2,',
        '"walk":0.5,"bound_clipping":true,"session_id":', CONNECTION_ID(), '}');

    SET v_search_result = fractal_search(p_corpus_json, p_query_json, p_k, v_params);

    -- Remap corpus-position idx -> real doc_id via p_ids_json. A
    -- fractal_search result may legitimately carry fewer than k top_k
    -- entries if the corpus itself has fewer rows; JSON_TABLE just
    -- naturally yields fewer rows in that case, nothing special needed.
    SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'doc_id', JSON_EXTRACT(p_ids_json, CONCAT('$[', t.idx, ']')),
             'dist', t.dist))
      INTO p_result_json
    FROM JSON_TABLE(v_search_result, '$.top_k[*]' COLUMNS (
           idx  INT    PATH '$.idx',
           dist DOUBLE PATH '$.dist')) t;

    IF p_result_json IS NULL THEN
        SET p_result_json = JSON_ARRAY();
    END IF;
END$$

-- Resolves table_name's single-column PK and builds a
-- (corpus_json, ids_json) pair from vector_col, ordered by that PK, for
-- the shared core above. Internal, not meant to be called directly
-- (use fractal_search_telemetry/fractal_search_trajectory/
-- fractal_cross_modal_search, which all need this same table-scan
-- shape but with a different query vector).
CREATE PROCEDURE _fractalsql_scan_corpus(
    IN  p_table_name  VARCHAR(128),
    IN  p_vector_col  VARCHAR(64),
    OUT p_corpus_json JSON,
    OUT p_ids_json    JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_pk_col   VARCHAR(64);
    DECLARE v_pk_count INT DEFAULT 0;
    DECLARE v_is_vec   BOOLEAN DEFAULT FALSE;
    DECLARE v_type     VARCHAR(64);
    DECLARE v_col_expr TEXT;
    DECLARE v_saved_gcml BIGINT UNSIGNED;

    IF p_table_name LIKE '%.%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            '_fractalsql_scan_corpus: schema-qualified table_name is not supported, pass a bare table name in the current database';
    END IF;

    SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND constraint_name = 'PRIMARY';
    IF v_pk_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            '_fractalsql_scan_corpus: table_name must have exactly one single-column PRIMARY KEY';
    END IF;
    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND constraint_name = 'PRIMARY'
    LIMIT 1;

    SELECT MIN(data_type) INTO v_type FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND column_name = p_vector_col;
    IF v_type IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '_fractalsql_scan_corpus: vector_col not found on table_name';
    END IF;
    SET v_is_vec = (LOWER(v_type) = 'vector');
    SET v_col_expr = IF(v_is_vec,
        CONCAT('VEC_TOTEXT(', _fractalsql_quote_ident(p_vector_col), ')'),
        _fractalsql_quote_ident(p_vector_col));

    -- MariaDB has no CAST(x AS JSON) (JSON is an alias for LONGTEXT
    -- plus a CHECK constraint, not a distinct type CAST() recognizes
    -- as a target). Confirmed directly: JSON_ARRAYAGG on a plain TEXT
    -- column that already holds valid JSON array text produces an
    -- array of quoted STRING elements ("[1,2,3]"), not a real nested
    -- array. Building the nested array via plain string concatenation
    -- (CONCAT('[', GROUP_CONCAT(...), ']')) sidesteps the problem
    -- entirely instead.
    --
    -- GROUP_CONCAT's own result is silently truncated at
    -- @@group_concat_max_len (default 1M bytes on stock MariaDB), with
    -- no error and no NULL: just a shorter, invalid-JSON string past
    -- that point. At dim=128 this truncates as early as roughly 870
    -- rows, so every caller of this procedure
    -- (fractal_search_telemetry/_search_trajectory/_cross_modal_search)
    -- would silently return a malformed or empty corpus on any
    -- real-sized table, with no error surfaced anywhere. Raise the
    -- limit for the duration of this one query and restore the
    -- session's prior value immediately after (this is a shared
    -- connection-scoped setting, not something this procedure should
    -- leave altered for the rest of the caller's session). 1 GiB is
    -- comfortably above any corpus this repo's SFS core is a sane
    -- choice for in the first place (see the iterations/population_size
    -- caps elsewhere in this file for the same "generous but bounded"
    -- posture) and is still far under max_allowed_packet's own typical
    -- ceiling, which remains the real backstop.
    SET v_saved_gcml = @@SESSION.group_concat_max_len;
    SET SESSION group_concat_max_len = 1073741824;
    SET @_fractalsql_sc_sql = CONCAT(
        'SELECT CONCAT(''['', GROUP_CONCAT(', v_col_expr, ' ORDER BY ', _fractalsql_quote_ident(v_pk_col), ' SEPARATOR '',''), '']''), ',
        '       JSON_ARRAYAGG(', _fractalsql_quote_ident(v_pk_col), ' ORDER BY ', _fractalsql_quote_ident(v_pk_col), ') ',
        'INTO @_fractalsql_sc_corpus, @_fractalsql_sc_ids ',
        'FROM ', _fractalsql_quote_ident(p_table_name),
        ' WHERE ', _fractalsql_quote_ident(p_vector_col), ' IS NOT NULL');
    SET @_fractalsql_sc_corpus = NULL;
    SET @_fractalsql_sc_ids    = NULL;
    PREPARE _fractalsql_sc_stmt FROM @_fractalsql_sc_sql;
    EXECUTE _fractalsql_sc_stmt;
    DEALLOCATE PREPARE _fractalsql_sc_stmt;
    SET SESSION group_concat_max_len = v_saved_gcml;

    SET p_corpus_json = @_fractalsql_sc_corpus;
    SET p_ids_json    = @_fractalsql_sc_ids;

    IF p_corpus_json IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '_fractalsql_scan_corpus: no non-NULL vector rows found';
    END IF;
END$$

-- Fetches the FULL, non-vector content of a caller-supplied set of rows
-- (by real PK value, e.g. the doc_id list a _fractalsql_telemetry_topk
-- result already carries) as a JSON array of row objects -- one object
-- per row, one key per column except vector_col itself. The intent:
-- reason over the retrieved rows' CONTENT, not the raw Scout vectors.
-- An LLM should never see a ~130KB embedding array, and the embedding
-- is useless to it anyway. Internal, used by
-- fractal_search_agent/fractal_rag_agent.
--
-- MariaDB has no built-in "every column except this one" projection;
-- the equivalent here is building a
-- dynamic JSON_OBJECT(col1, col1, col2, col2, ...) column list from
-- information_schema once, then one dynamic SQL SELECT that aggregates
-- it into a JSON_ARRAYAGG, scoped to the given PK list. p_doc_ids_json
-- values come from this repo's own prior corpus scan (real PK values,
-- never caller-supplied free text), so they're inlined via QUOTE() the
-- same way fractal_agent_trajectory_predict's baseline/current/predicted
-- lookups already do -- not a raw string-interpolation injection risk.
CREATE PROCEDURE _fractalsql_fetch_row_context(
    IN  p_table_name    VARCHAR(128),
    IN  p_vector_col    VARCHAR(64),
    IN  p_doc_ids_json  JSON,
    OUT p_context_json  JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_pk_col    VARCHAR(64);
    DECLARE v_pk_count  INT DEFAULT 0;
    DECLARE v_cols      TEXT;
    DECLARE v_id_list   TEXT DEFAULT '';
    DECLARE v_n         INT DEFAULT 0;
    DECLARE v_i         INT DEFAULT 0;

    IF p_table_name LIKE '%.%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            '_fractalsql_fetch_row_context: schema-qualified table_name is not supported, pass a bare table name in the current database';
    END IF;

    SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND constraint_name = 'PRIMARY';
    IF v_pk_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            '_fractalsql_fetch_row_context: table_name must have exactly one single-column PRIMARY KEY';
    END IF;
    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND constraint_name = 'PRIMARY'
    LIMIT 1;

    -- Build "'col1', col1, 'col2', col2, ..." for every column except the
    -- vector column, so the LLM-facing context never carries embeddings.
    SELECT GROUP_CONCAT(CONCAT(QUOTE(column_name), ', ', _fractalsql_quote_ident(column_name)) SEPARATOR ', ')
      INTO v_cols
    FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND column_name <> p_vector_col;
    IF v_cols IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            '_fractalsql_fetch_row_context: no non-vector columns found on table_name';
    END IF;

    IF p_doc_ids_json IS NULL OR JSON_LENGTH(p_doc_ids_json) = 0 THEN
        SET p_context_json = JSON_ARRAY();
    ELSE
        SET v_n = JSON_LENGTH(p_doc_ids_json);
        WHILE v_i < v_n DO
            IF v_i > 0 THEN
                SET v_id_list = CONCAT(v_id_list, ', ');
            END IF;
            SET v_id_list = CONCAT(v_id_list, QUOTE(JSON_UNQUOTE(JSON_EXTRACT(p_doc_ids_json, CONCAT('$[', v_i, ']')))));
            SET v_i = v_i + 1;
        END WHILE;

        SET @_fractalsql_frc_sql = CONCAT(
            'SELECT JSON_ARRAYAGG(JSON_OBJECT(', v_cols, ')) INTO @_fractalsql_frc_ctx FROM ',
            _fractalsql_quote_ident(p_table_name), ' WHERE ', _fractalsql_quote_ident(v_pk_col),
            ' IN (', v_id_list, ')');
        SET @_fractalsql_frc_ctx = NULL;
        PREPARE _fractalsql_frc_stmt FROM @_fractalsql_frc_sql;
        EXECUTE _fractalsql_frc_stmt;
        DEALLOCATE PREPARE _fractalsql_frc_stmt;
        SET p_context_json = IFNULL(@_fractalsql_frc_ctx, JSON_ARRAY());
    END IF;
END$$

-- fractal_search_telemetry(table_name, vector_col, query, k, OUT result)
-- Real "k nearest rows from this table" primitive: result is a JSON
-- array of {"doc_id":..,"dist":..} objects, dist ascending.
CREATE PROCEDURE fractal_search_telemetry(
    IN  p_table_name VARCHAR(128),
    IN  p_vector_col VARCHAR(64),
    IN  p_query      JSON,
    IN  p_k          INT,
    OUT p_result     JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_corpus JSON;
    DECLARE v_ids    JSON;
    CALL _fractalsql_scan_corpus(p_table_name, p_vector_col, v_corpus, v_ids);
    CALL _fractalsql_telemetry_topk(v_corpus, v_ids, p_query, p_k, p_result);
END$$

-- fractal_hybrid_clinical_search(table_name, vector_col, query, doc_ids,
--   k, OUT result)
-- Same as fractal_search_telemetry but scoped to a caller-supplied
-- cohort (doc_ids, a JSON array of real row ids) instead of the whole
-- table. The caller computes their cohort filter with ordinary SQL
-- and passes the id list in; no dynamic SQL predicate/filter string is
-- ever accepted here, to avoid an injection surface.
CREATE PROCEDURE fractal_hybrid_clinical_search(
    IN  p_table_name VARCHAR(128),
    IN  p_vector_col VARCHAR(64),
    IN  p_query      JSON,
    IN  p_doc_ids    JSON,
    IN  p_k          INT,
    OUT p_result     JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_pk_col    VARCHAR(64);
    DECLARE v_pk_count  INT DEFAULT 0;
    DECLARE v_is_vec    BOOLEAN DEFAULT FALSE;
    DECLARE v_type      VARCHAR(64);
    DECLARE v_corpus    JSON;
    DECLARE v_ids       JSON;
    DECLARE v_saved_gcml BIGINT UNSIGNED;

    IF p_doc_ids IS NULL OR JSON_LENGTH(p_doc_ids) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_hybrid_clinical_search: doc_ids must be non-empty';
    END IF;
    IF p_table_name LIKE '%.%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_hybrid_clinical_search: schema-qualified table_name is not supported, pass a bare table name in the current database';
    END IF;

    SELECT COUNT(*) INTO v_pk_count FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND constraint_name = 'PRIMARY';
    IF v_pk_count <> 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT =
            'fractal_hybrid_clinical_search: table_name must have exactly one single-column PRIMARY KEY';
    END IF;
    SELECT column_name INTO v_pk_col FROM information_schema.key_column_usage
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND constraint_name = 'PRIMARY'
    LIMIT 1;

    SELECT MIN(data_type) INTO v_type FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = p_table_name AND column_name = p_vector_col;
    IF v_type IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_hybrid_clinical_search: vector_col not found on table_name';
    END IF;
    SET v_is_vec = (LOWER(v_type) = 'vector');

    DROP TEMPORARY TABLE IF EXISTS _fractalsql_hcs_cohort_ids;
    CREATE TEMPORARY TABLE _fractalsql_hcs_cohort_ids (id VARCHAR(255));
    INSERT INTO _fractalsql_hcs_cohort_ids (id)
    SELECT jt.id FROM JSON_TABLE(p_doc_ids, '$[*]' COLUMNS (id VARCHAR(255) PATH '$')) jt;

    -- vector_col is prefixed "t." explicitly (rather than reusing a
    -- pre-built expression string) since it needs the table alias only
    -- when it's a bare quoted column, not when it's wrapped in
    -- VEC_TOTEXT(...).
    -- See _fractalsql_scan_corpus's comment on why this is a plain
    -- string CONCAT, not JSON_ARRAYAGG(CAST(... AS JSON)): MariaDB
    -- has no CAST(x AS JSON).
    -- See _fractalsql_scan_corpus's comment (this file) on why
    -- group_concat_max_len must be raised here too. This procedure
    -- has its own independent GROUP_CONCAT block (cohort-filtered, so
    -- it can't just call that shared helper) and hits the exact same
    -- silent-truncation risk.
    SET v_saved_gcml = @@SESSION.group_concat_max_len;
    SET SESSION group_concat_max_len = 1073741824;
    SET @_fractalsql_hcs_sql = CONCAT(
        'SELECT CONCAT(''['', GROUP_CONCAT(',
        IF(v_is_vec, CONCAT('VEC_TOTEXT(t.', _fractalsql_quote_ident(p_vector_col), ')'),
                     CONCAT('t.', _fractalsql_quote_ident(p_vector_col))),
        ' ORDER BY t.', _fractalsql_quote_ident(v_pk_col), ' SEPARATOR '',''), '']''), ',
        '       JSON_ARRAYAGG(t.', _fractalsql_quote_ident(v_pk_col), ' ORDER BY t.', _fractalsql_quote_ident(v_pk_col), ') ',
        'INTO @_fractalsql_hcs_corpus, @_fractalsql_hcs_ids ',
        'FROM ', _fractalsql_quote_ident(p_table_name), ' t ',
        'JOIN _fractalsql_hcs_cohort_ids c ON c.id = t.', _fractalsql_quote_ident(v_pk_col), ' ',
        'WHERE t.', _fractalsql_quote_ident(p_vector_col), ' IS NOT NULL');
    SET @_fractalsql_hcs_corpus = NULL;
    SET @_fractalsql_hcs_ids    = NULL;
    PREPARE _fractalsql_hcs_stmt FROM @_fractalsql_hcs_sql;
    EXECUTE _fractalsql_hcs_stmt;
    DEALLOCATE PREPARE _fractalsql_hcs_stmt;
    SET SESSION group_concat_max_len = v_saved_gcml;
    DROP TEMPORARY TABLE IF EXISTS _fractalsql_hcs_cohort_ids;

    SET v_corpus = @_fractalsql_hcs_corpus;
    SET v_ids    = @_fractalsql_hcs_ids;

    IF v_corpus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_hybrid_clinical_search: doc_ids cohort matched no rows';
    END IF;

    CALL _fractalsql_telemetry_topk(v_corpus, v_ids, p_query, p_k, p_result);
END$$

-- fractal_search_trajectory(table_name, vector_col, baseline_vector,
--   current_vector, k, OUT result)
-- Searches the delta (current - baseline) against the whole table:
-- "what has changed" rather than "where am I", for drift/trajectory
-- monitoring. Reuses fractal_vector_sub for the delta.
CREATE PROCEDURE fractal_search_trajectory(
    IN  p_table_name      VARCHAR(128),
    IN  p_vector_col      VARCHAR(64),
    IN  p_baseline_vector JSON,
    IN  p_current_vector  JSON,
    IN  p_k               INT,
    OUT p_result          JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_delta  TEXT;
    DECLARE v_corpus JSON;
    DECLARE v_ids    JSON;

    SET v_delta = fractal_vector_sub(p_current_vector, p_baseline_vector);
    CALL _fractalsql_scan_corpus(p_table_name, p_vector_col, v_corpus, v_ids);
    CALL _fractalsql_telemetry_topk(v_corpus, v_ids, v_delta, p_k, p_result);
END$$

-- fractal_cross_modal_search(table_name, vector_col, morphology_vector,
--   clinical_vector, alpha_weight, k, OUT result)
-- Weighted concatenation (not a blend) of two modalities: each keeps
-- its own dimensions, scaled by alpha/(1-alpha) before concatenation.
-- table_name.vector_col must already be stored in this same combined
-- shape (an upstream ETL concern, not something this validates beyond
-- fractal_search's own dimension-match requirement).
CREATE PROCEDURE fractal_cross_modal_search(
    IN  p_table_name        VARCHAR(128),
    IN  p_vector_col        VARCHAR(64),
    IN  p_morphology_vector JSON,
    IN  p_clinical_vector   JSON,
    IN  p_alpha_weight      DOUBLE,
    IN  p_k                 INT,
    OUT p_result            JSON
)
SQL SECURITY INVOKER

BEGIN
    DECLARE v_morph_scaled TEXT;
    DECLARE v_clin_scaled  TEXT;
    DECLARE v_combined     JSON;
    DECLARE v_corpus       JSON;
    DECLARE v_ids          JSON;

    IF p_alpha_weight IS NULL OR p_alpha_weight < 0.0 OR p_alpha_weight > 1.0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'fractal_cross_modal_search: alpha_weight must be in [0,1]';
    END IF;

    SET v_morph_scaled = fractal_vector_scale(p_morphology_vector, p_alpha_weight);
    SET v_clin_scaled  = fractal_vector_scale(p_clinical_vector, 1.0 - p_alpha_weight);
    -- Concatenation (not elementwise): combine the two scaled JSON
    -- arrays into one by stripping the outer brackets and joining.
    SET v_combined = CONCAT(
        LEFT(v_morph_scaled, CHAR_LENGTH(v_morph_scaled) - 1), ',',
        SUBSTRING(v_clin_scaled, 2));

    CALL _fractalsql_scan_corpus(p_table_name, p_vector_col, v_corpus, v_ids);
    CALL _fractalsql_telemetry_topk(v_corpus, v_ids, v_combined, p_k, p_result);
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- v2.0.0, Enterprise tier
--
-- Activation gating (dlopen/dlsym of the enterprise core .so) plus a
-- real, file-backed persistence layer for the QTL ledger and the general
-- decision-audit chain: an append-only hash chain (entry_hash =
-- SHA256(prev_hash || blob || mac)) with optional HMAC-SHA256 tamper
-- authentication. Plain MariaDB UDFs cannot execute SQL against their
-- own calling session, so the authoritative store is a local binary
-- file (FRACTALSQL_ENTERPRISE_LEDGER_PATH), with the same hash-chain/
-- MAC/verify guarantees a SQL-table-backed ledger would carry. That
-- file is mirrored, on every successful write, into a plain CSV file
-- the MariaDB CONNECT storage engine can read directly: install
-- sql/install_enterprise_connect.sql to get a real, read-only,
-- SQL-queryable `fractalsql_ledger` table (SELECT/WHERE/ORDER BY/JOIN
-- all work normally). See src/fractalsql_enterprise.c's file header
-- for the full design, including why a loopback SQL connection was
-- considered and rejected (new credential/socket config, new attack
-- surface) in favor of the file+CONNECT-mirror approach.
--
-- ensure_enterprise_lib() also verifies the enterprise .so's detached
-- Ed25519 signature (a sibling <path>.sig file) against a fixed
-- FractalSQLabs public key before dlopen. An INVALID signature always
-- refuses; a MISSING one refuses only when
-- FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE is set (default: loads
-- unverified, backward compatible).
--
-- Set FRACTALSQL_ENTERPRISE_LIB (mysqld process environment, the same
-- env-var-only configuration convention as FRACTALSQL_REASONING_PLUGIN)
-- to the enterprise core .so's absolute path to activate. Every function
-- below raises a clear error until that library is present and its 8
-- required symbols resolve; Community deployments work unchanged with
-- it unset. Optional: FRACTALSQL_ENTERPRISE_LEDGER_PATH (ledger file
-- path, default fractalsql_ledger.dat relative to mysqld's cwd),
-- FRACTALSQL_ENTERPRISE_LEDGER_KEY (HMAC key, unset = structural-only
-- validation), and FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE (refuse an
-- unsigned .so; default off).
-- ---------------------------------------------------------------------

-- fractal_ledger_flush/_load/_compact/_reset_soft/_reset_hard(session_id)
--   -> INT (0). Thin wrappers over the enterprise core's fsql_ledger_*
-- functions, operating on the session's own ctx, the same ctx
-- fractal_search and fractal_diversify_* use. That ctx now carries a
-- real file-backed storage VFS (see above), so flush/load genuinely
-- persist and rehydrate the Truth/Shadow ledgers across process
-- restarts, not just within one session.
CREATE FUNCTION fractal_ledger_flush      RETURNS INTEGER SONAME 'fractalsql.so';
CREATE FUNCTION fractal_ledger_load       RETURNS INTEGER SONAME 'fractalsql.so';
CREATE FUNCTION fractal_ledger_compact    RETURNS INTEGER SONAME 'fractalsql.so';
CREATE FUNCTION fractal_ledger_reset_soft RETURNS INTEGER SONAME 'fractalsql.so';
CREATE FUNCTION fractal_ledger_reset_hard RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_ledger_truth_count/_shadow_count(session_id) -> BIGINT
CREATE FUNCTION fractal_ledger_truth_count  RETURNS INTEGER SONAME 'fractalsql.so';
CREATE FUNCTION fractal_ledger_shadow_count RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_ledger_verify(session_id [, kind]) -> STRING (JSON)
-- Full O(n) walk of the ledger file for `kind` (default 1). Pure
-- storage-layer check: does not require the enterprise library to be
-- loaded. Returns {"ok":true,"rows_verified":N} or
-- {"ok":false,"first_failure_id":N,"reason":"..."}.
CREATE FUNCTION fractal_ledger_verify RETURNS STRING SONAME 'fractalsql.so';

-- fractal_audit_log(entry_type, payload_json) -> INT (0)
-- Append a provenance record to the general decision-audit chain
-- (kind=2 in the ledger, independent of kind=1's QTL Truth/Shadow
-- chain). Also called automatically, best-effort, from
-- fractal_optimize_portfolio (see src/fractalsql.c's
-- portfolio_audit_log_best_effort).
-- Query the audit trail back via the CONNECT mirror table (see
-- sql/install_enterprise_connect.sql): SELECT id, blob_b64, updated
-- FROM fractalsql_ledger WHERE kind = 2 ORDER BY id.
CREATE FUNCTION fractal_audit_log RETURNS INTEGER SONAME 'fractalsql.so';

-- fractal_audit_unpack(blob) -> JSON STRING
-- Pure decode of a QTL audit blob. Touches neither session state nor
-- storage, so this is fully, honestly complete: it only needs the
-- enterprise library loaded.
CREATE FUNCTION fractal_audit_unpack RETURNS STRING SONAME 'fractalsql.so';

-- Verify installation:
--   SELECT name, dl FROM mysql.func;
--   SELECT fractalsql_edition(), fractalsql_version();
--
-- Example call + JSON_EXTRACT slice:
--
--   SET @corpus = '[[1,0,0],[0,1,0],[0,0,1],[0.5,0.5,0]]';
--   SET @query  = '[0.6,0.6,0]';
--   SET @params = '{"iterations":30,"population_size":50,"walk":0.5}';
--
--   SELECT
--     JSON_EXTRACT(r, '$.best_point')    AS best_point,
--     JSON_EXTRACT(r, '$.top_k[0].idx')  AS top_hit,
--     JSON_EXTRACT(r, '$.top_k[0].dist') AS top_dist
--   FROM (SELECT fractal_search(@corpus, @query, 3, @params) AS r) t;
