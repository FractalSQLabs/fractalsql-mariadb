-- demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- Industry vertical: Cybersecurity & Threat Detection (network behavior
-- analytics / SOC log analysis).
--
-- A 35-host fleet across three network zones, each with a BASELINE
-- traffic-behavior vector and a CURRENT (recent window) vector. One
-- host goes quiet-then-beacons: a compromise pattern (outbound
-- connection volume, unique destination ports, and DNS query rate all
-- spike; failed-auth rate barely moves -- this isn't a brute-force
-- attempt, it's a stealthier C2 beaconing profile). Diverse
-- traffic-profile clustering for threat hunting, a zone-restricted
-- search, current-vs-baseline drift detection, and connection-rate
-- regime-change detection via DFA.
--
-- Structural details, confirmed against sql/install_udf.sql and
-- sql/install_agents.sql (see demo-agents.sql's own header for the
-- fuller account, not re-derived here):
--   - fractal_agent_recommend_diverse / fractal_agent_regime_triage /
--     fractal_agent_track_anomaly are PROCEDUREs with a trailing
--     OUT p_result JSON param here, not RETURNS TABLE functions, so
--     every "SELECT ... FROM fractal_agent_x(...)" below becomes
--     `CALL fractal_agent_x(...args, @r); SELECT JSON_VALUE(@r, ...)`.
--   - fractal_search_telemetry/_trajectory are PROCEDUREs too, and
--     already resolve + return each scanned table's own REAL
--     PRIMARY KEY value as "doc_id" (see sql/install_udf.sql's
--     _fractalsql_scan_corpus). There is no position-remapping step
--     anywhere in this file: host 7's UPDATE relocating its row does
--     not affect doc_id at all, since doc_id is always the row's own
--     primary key.
--   - fractal_explore(corpus, query, params) takes the corpus inline
--     as a JSON array rather than as a table/column reference (see
--     demo-business-intelligence.sql Section 6).
--   - There is no fixed-width vector column type here with a
--     write-time hard error on a dimension mismatch: this extension's
--     portable-path convention for these exact agents (see
--     demo-agents.sql's agents_demo_vehicles / agents_demo_tracks
--     fixtures) is a plain JSON column populated via
--     JSON_ARRAY()/JSON_EXTRACT() instead. Native VECTOR(n) is
--     11.7+-only (see sql/install_udf.sql's own header on the
--     portable vs. native path) and not used for this fixture.
--
-- Prerequisites:
--   1. fractalsql-mariadb installed and `SOURCE sql/install_udf.sql;`
--      and `SOURCE sql/install_agents.sql;` already run against the
--      target database (sections 0-4 need nothing else).
--   2. Section 6 narrates that its reasoning step is folded into the
--      Section 5 preset rationales (fractal_agent_regime_triage /
--      fractal_agent_track_anomaly), which call fractal_reason()
--      internally -- see docs/reasoning-setup.md for reasoning setup.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- Safe to re-run: vcy_* tables are dropped and recreated each time.
--
-- NOTE ON \timing / \echo: the mariadb CLI has no direct equivalent of
-- psql's \timing; use `SET profiling = 1; ... SHOW PROFILES;` if you
-- want per-statement timing. Section markers below are plain comments,
-- not executed statements (unlike psql's \echo, which prints even when
-- run non-interactively).
--
-- NOTE: MariaDB has no session-wide random seed equivalent to
-- setseed(). RAND(seed) reseeds per-call, not per-session, so results
-- here are not bit-reproducible run to run. Flagged as a known
-- limitation, not a silent omission.

-- === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 35 hosts across 3 zones (dmz, internal, guest), each with a
-- BASELINE behavior vector (normal traffic profile) and a CURRENT
-- vector (this window's telemetry). Fields, in order:
-- [outbound_conn_rate, unique_dest_ports, dns_query_rate,
-- failed_auth_rate], each normalized to roughly [-1, 1]. Host 7 gets
-- a deliberate compromise pattern -- everyone else's current stays
-- close to baseline (ordinary traffic noise).
-- ------------------------------------------------------------------
-- === 1. 35 hosts: baseline vs. current network-behavior vectors ===

DROP TABLE IF EXISTS vcy_hosts;
CREATE TABLE vcy_hosts (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    hostname    VARCHAR(32),
    zone        VARCHAR(16),
    -- JSON, not a fixed-width vector column, see this file's header.
    -- A feature-extraction bug that silently changed the vector's
    -- width is not a hard write-time error here: this extension's
    -- portable JSON-column convention has no dimension enforcement
    -- built in.
    baseline    JSON,
    current_pos JSON
);

-- MariaDB 11.4 doesn't support LATERAL derived tables (confirmed live
-- in demo-agents.sql, both comma-join and JOIN LATERAL forms error).
-- Insert baseline only first (4 independent RAND() calls -- fine,
-- each row's 4 components don't need to correlate with EACH OTHER,
-- only baseline needs to correlate with that SAME row's current_pos),
-- then a follow-up UPDATE derives current_pos off the just-inserted
-- baseline via JSON_EXTRACT -- same technique demo-agents.sql already
-- uses for its own vehicle/track fixtures.
INSERT INTO vcy_hosts (hostname, zone, baseline)
WITH RECURSIVE seq(gs) AS (
    SELECT 1 UNION ALL SELECT gs + 1 FROM seq WHERE gs < 35
)
SELECT CONCAT('HOST-', gs),
       ELT(MOD(gs - 1, 3) + 1, 'dmz', 'internal', 'guest'),
       JSON_ARRAY(RAND()*2-1, RAND()*2-1, RAND()*2-1, RAND()*2-1)
FROM seq;

UPDATE vcy_hosts
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline, '$[0]') + (RAND()-0.5)*0.06,
        JSON_EXTRACT(baseline, '$[1]') + (RAND()-0.5)*0.06,
        JSON_EXTRACT(baseline, '$[2]') + (RAND()-0.5)*0.06,
        JSON_EXTRACT(baseline, '$[3]') + (RAND()-0.5)*0.06);

-- Host 7's deliberate compromise: outbound connections, destination
-- ports, and DNS query volume all spike; failed-auth barely moves.
-- Overrides the ordinary-noise current_pos just set above for id = 7.
UPDATE vcy_hosts
   SET current_pos = JSON_ARRAY(
        JSON_EXTRACT(baseline, '$[0]') + 0.8, JSON_EXTRACT(baseline, '$[1]') + 0.7,
        JSON_EXTRACT(baseline, '$[2]') + 0.6, JSON_EXTRACT(baseline, '$[3]') + 0.05)
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse traffic-profile clustering across the
-- fleet -- threat hunting ("what KINDS of behavior profiles are
-- actually running right now") instead of cosine top-K, which would
-- just return 50 near-duplicates of whichever profile is most common
-- and miss the one host that looks different.
-- ------------------------------------------------------------------
-- === 2. fractal_explore: diverse traffic-profile clustering ===
-- --- Preset: fractal_agent_recommend_diverse (raw explore form preserved below) ---

-- Blueprint (raw primitive): returns a diverse representative set of the
-- fleet's traffic-profile embeddings -- surfaces the one host that looks
-- different instead of K near-duplicates of the most common profile.
-- fractal_explore takes its corpus inline (a JSON array), not a
-- table/column pair.
-- SELECT fractal_explore(
--     (SELECT JSON_ARRAYAGG(current_pos) FROM vcy_hosts), '[0,0,0,0]',
--     '{"population_size": 6, "iterations": 8, "walk": 0}');

-- Productized preset: the shipped engine returns real host ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session so the section-3 zone search below sees the same
-- diversify-off state as before (the engine leaves diversify on -- the
-- caller owns that policy). The blueprint's zero query is query-agnostic
-- (explore samples the space); recommend_diverse is query-anchored, so
-- anchor on the first host's own current_pos vector. No id_col argument
-- and no ctid/row_number id-resolution step -- this engine returns the
-- table's own real PRIMARY KEY directly (see this file's header).
CALL fractal_agent_recommend_diverse(
    'vcy_hosts', 'current_pos',
    (SELECT current_pos FROM vcy_hosts ORDER BY id LIMIT 1),
    6, @r);
SELECT item_id, score
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           item_id VARCHAR(32) PATH '$.item_id',
           score   DOUBLE      PATH '$.score')) AS jt
ORDER BY score DESC;
SELECT fractal_diversify_disable(CONNECTION_ID());

-- ------------------------------------------------------------------
-- 3. Zone-restricted search: "DMZ hosts only" -- fractal_search_
-- telemetry's table_name argument is a plain text table name, so a
-- zone filter composes by searching a filtered table instead (the
-- same cohort-then-search shape fractal_hybrid_clinical_search uses
-- internally for its doc_ids allowlist, without needing that
-- clinically-named function here -- same composition
-- demo-vertical-fleet-logistics.sql uses for its route-3 cohort).
--
-- vcy_dmz_cohort is created as an explicit column list with its own
-- PRIMARY KEY (id), not `CREATE TEMPORARY TABLE ... AS SELECT *`:
-- fractal_search_telemetry (sql/install_udf.sql's
-- _fractalsql_scan_corpus) requires the table it scans to carry
-- exactly one single-column PRIMARY KEY, and a plain AS SELECT copy
-- drops that constraint even though it copies the data.
--
-- It's a PERMANENT table, not TEMPORARY, even though it's scratch
-- data dropped/recreated on every run (confirmed against a live
-- server): MariaDB's information_schema -- which _fractalsql_scan_
-- corpus uses for BOTH the PRIMARY KEY check above and its vector_col
-- type lookup -- has no visibility into TEMPORARY tables at all
-- (SHOW CREATE TABLE reports the PK correctly; information_schema.
-- key_column_usage/columns return zero rows regardless). A
-- TEMPORARY table here fails scan_corpus's PK check even with an
-- explicit single-column PRIMARY KEY declared.
--
-- No doc_id-vs-id remapping needed here, even though host 7's earlier
-- UPDATE relocated its row: this extension's
-- fractal_search_telemetry always resolves and returns the scanned
-- table's own real PRIMARY KEY value as doc_id, so a plain join on
-- id = doc_id is correct regardless of physical/insertion order.
-- ------------------------------------------------------------------
-- === 3. Zone-restricted search: DMZ hosts only ===

DROP TABLE IF EXISTS vcy_dmz_cohort;
CREATE TABLE vcy_dmz_cohort (
    id          INT PRIMARY KEY,
    hostname    VARCHAR(32),
    zone        VARCHAR(16),
    baseline    JSON,
    current_pos JSON
);
INSERT INTO vcy_dmz_cohort
SELECT * FROM vcy_hosts WHERE zone = 'dmz';

CALL fractal_search_telemetry('vcy_dmz_cohort', 'current_pos',
                               '[0.3, 0.3, 0.3, 0.0]', 5, @r);
SELECT h.hostname, jt.dist AS distance
  FROM JSON_TABLE(@r, '$[*]' COLUMNS (
           doc_id INT    PATH '$.doc_id',
           dist   DOUBLE PATH '$.dist')) AS jt
  JOIN vcy_dmz_cohort h ON h.id = jt.doc_id
ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for host 7
-- -- "what changed" rather than "what's closest", the direct fit for
-- compromise/beaconing detection.
--
-- No ctid/row_number remapping needed here either (see Section 3's
-- comment above and this file's header) -- fractal_search_trajectory
-- already returns real host ids as doc_id.
-- ------------------------------------------------------------------
-- === 4. fractal_search_trajectory: host 7's drift vs. the fleet ===

-- Blueprint (raw primitive): the current-vs-baseline DELTA search for
-- host 7's compromise drift. Generalized by the shipped
-- fractal_agent_track_anomaly preset in Section 5, which folds this
-- trajectory search together with the connection-rate heading DFA and a
-- reasoning step.
-- CALL fractal_search_trajectory(
--     'vcy_hosts', 'current_pos',
--     (SELECT baseline FROM vcy_hosts WHERE id = 7),
--     (SELECT current_pos FROM vcy_hosts WHERE id = 7),
--     5, @r);
-- SELECT h.hostname, h.zone, jt.dist AS distance
--   FROM JSON_TABLE(@r, '$[*]' COLUMNS (
--            doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) AS jt
--   JOIN vcy_hosts h ON h.id = jt.doc_id
-- ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 5. fractal_dimension_dfa / fractal_dimension_drift: host 7's
-- connections-per-minute series over the last 300 minutes, with a
-- deliberate regime change at t=220 -- low-amplitude noisy baseline
-- traffic, then a shift to a regular, higher-frequency beaconing
-- interval. DFA's scaling exponent picks up the change in long-range
-- structure; fractal_dimension_drift makes the same point directly by
-- comparing the tail window against everything before it.
-- ------------------------------------------------------------------
-- === 5. fractal_dimension_dfa / drift: host 7 connection-rate regime change ===

DROP TEMPORARY TABLE IF EXISTS vcy_conn_series;
CREATE TEMPORARY TABLE vcy_conn_series AS
SELECT t,
       CASE WHEN t < 220
            THEN 4.0 + 1.5 * SIN(t * 0.31) + (RAND()-0.5) * 0.8
            ELSE 4.0 + 3.0 * SIN(t * 1.4)  + (RAND()-0.5) * 0.4
       END AS conn_rate
FROM (
    WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM seq WHERE t < 300)
    SELECT t FROM seq
) s;

-- Blueprint (raw primitives): the connection-rate series' DFA exponent
-- and its drift report. Generalized below by TWO shipped presets:
-- fractal_agent_regime_triage (the dfa+drift over this series) and
-- fractal_agent_track_anomaly (this series' DFA folded with the Section 4
-- trajectory search over host 7's baseline->current_pos).
-- SELECT fractal_dimension_dfa(
--     (SELECT CONCAT('[', GROUP_CONCAT(conn_rate ORDER BY t), ']') FROM vcy_conn_series)
-- ) AS full_series_dfa_exponent;
--
-- SELECT fractal_dimension_drift(
--     (SELECT CONCAT('[', GROUP_CONCAT(conn_rate ORDER BY t), ']') FROM vcy_conn_series),
--     60
-- ) AS recent_60min_vs_history;

-- Productized preset (1): the regime-change engine over the connection-
-- rate series -- real DFA exponent, real drift_detected, real alphas,
-- real rationale. Trailing p_context is optional extra guidance for the
-- reasoning step (NULL is fine here).
-- --- Preset: fractal_agent_regime_triage (raw dfa+drift form preserved above) ---
CALL fractal_agent_regime_triage(
    (SELECT CONCAT('[', GROUP_CONCAT(conn_rate ORDER BY t), ']') FROM vcy_conn_series),
    64, 0.5, NULL, @r);
SELECT JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.drift_detected') AS drift_detected,
       JSON_VALUE(@r, '$.recent_alpha') AS recent_alpha,
       JSON_VALUE(@r, '$.baseline_alpha') AS baseline_alpha,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- Productized preset (2): the track-anomaly engine -- real nearest fleet
-- host (fractal_search_trajectory over host 7's baseline->current_pos,
-- resolved via the table's real PRIMARY KEY, no ctid/row_number needed),
-- real trajectory_distance, real connection-rate DFA exponent, real
-- rationale. No trailing k/id_col arguments (see this file's header) --
-- the call ends right after heading_series.
-- --- Preset: fractal_agent_track_anomaly (raw trajectory+dfa form preserved in Section 4 + above) ---
CALL fractal_agent_track_anomaly(
    'vcy_hosts', 'current_pos',
    (SELECT baseline FROM vcy_hosts WHERE id = 7),
    (SELECT current_pos FROM vcy_hosts WHERE id = 7),
    (SELECT CONCAT('[', GROUP_CONCAT(conn_rate ORDER BY t), ']') FROM vcy_conn_series),
    @r);
SELECT JSON_VALUE(@r, '$.nearest_fleet_id') AS nearest_fleet_id,
       JSON_VALUE(@r, '$.trajectory_distance') AS trajectory_distance,
       JSON_VALUE(@r, '$.dfa_exponent') AS dfa_exponent,
       JSON_VALUE(@r, '$.rationale') AS rationale;

-- ------------------------------------------------------------------
-- 6. Reasoning: the SOC triage narrative for host 7 is now split across
-- the two Section 5 preset rationales -- fractal_agent_track_anomaly
-- (the baseline->current_pos drift + connection-rate DFA) and
-- fractal_agent_regime_triage (the regime change itself).
-- ------------------------------------------------------------------
-- === 6. Reasoning: absorbed into the Section 5 track_anomaly + regime_triage rationales ===

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE vcy_hosts, vcy_dmz_cohort;
