-- demo/enterprise-stress.sql
--
-- Enterprise Tier -- QTL Ledger under stress + tamper-evidence.
--
-- Companion to enterprise-qtl-audit.sql (which walks the functions one
-- call at a time). This demo fills the in-memory Truth/Shadow ledgers to
-- their capacity bound (64 each, FSQL_TRUTH/SHADOW_DEFAULT_CAP in
-- fractalsql-core), churns repeated flush cycles, builds a short
-- append-only chain, and verifies it with fractal_ledger_verify().
--
-- Tamper injection needs a step this file's own SQL cannot take. The
-- ledger is a local file, not a SQL table (see src/fractalsql_
-- enterprise.c's header: MariaDB's C UDF ABI has no way for a UDF to run
-- SQL against its own calling session, so there is no `UPDATE
-- fractalsql_ledger SET blob = ...` to reach for -- the optional CONNECT
-- mirror, sql/install_enterprise_connect.sql, is READONLY=1 on purpose).
-- Reaching the bytes means reaching the file, which from inside a MariaDB
-- session is only possible via LOAD_FILE()/INTO DUMPFILE (subject to
-- secure_file_priv) or, more directly, a shell open on the container/host.
-- This demo's own SQL runs Phases A-C end to end; Phase D (tamper) is a
-- documented recipe you run against the container's filesystem between
-- two `mariadb` invocations, not a single self-contained script the way
-- enterprise-qtl-audit.sql is. Both the structural-truncation and
-- entry-hash-tamper cases below have been run against a real
-- libfractalsql-enterprise-sovereign-c.so; see each Phase D recipe for
-- the resulting output.
--
-- The ledger key (FRACTALSQL_ENTERPRISE_LEDGER_KEY) adds HMAC-SHA256
-- tagging on top of the structural hash chain, so a payload byte-flip
-- that preserves length is caught even though the structural checks
-- alone can't see it (MariaDB has
-- no per-session `SET fractalsql.enterprise_ledger_key = ...` to toggle
-- this mid-script: every FractalSQL config knob here is a process
-- environment variable, read once at mariadbd startup, see enterprise.md).
-- Testing the HMAC path means starting a container with the key already
-- set; this demo's SQL phases work identically either way and don't
-- depend on which one you're running against.
--
-- Runs cleanly in BOTH states and tells you which:
--   * Enterprise ACTIVE:  Phases A-C run for real against the persisted
--     ledger file.
--   * Enterprise DORMANT: the first ledger call returns NULL and the
--     demo prints a single notice explaining the surface is
--     enterprise-only. Community search is unaffected.
--
-- Safe to re-run: the in-memory ledger context is per-session (a fresh
-- connection starts empty), but the PERSISTED ledger is process-global
-- and accumulates across runs -- each phase below calls
-- fractal_ledger_reset_hard() first so a re-run's counts stay
-- predictable even though the underlying file keeps growing.

DROP PROCEDURE IF EXISTS demo_enterprise_stress;
DELIMITER $$
CREATE PROCEDURE demo_enterprise_stress()
BEGIN
    DECLARE sid          BIGINT UNSIGNED DEFAULT CONNECTION_ID();
    DECLARE i            INT;
    DECLARE c            INT;
    DECLARE tc           BIGINT;
    DECLARE sc           BIGINT;
    DECLARE loaded_probe BIGINT;
    DECLARE flush_rc     INT;
    DECLARE v_verify     JSON;

    SELECT fractal_ledger_truth_count(sid) INTO loaded_probe;
    IF loaded_probe IS NULL THEN
        SELECT 'Enterprise tier not loaded. fractal_ledger_* is an enterprise-tier feature and is dormant on this community image. To activate: stage libfractalsql-enterprise-sovereign-c.so into the container and set FRACTALSQL_ENTERPRISE_LIB in mariadbd''s environment, then restart and re-run this demo. The community search engine is unaffected.' AS notice;
    ELSE
        SELECT fractal_diversify_enable(sid);

        -- ================================================================
        -- Phase A: fill to capacity bound (64 Truth + 64 Shadow) + flush.
        -- Disjoint doc_ids (1..64 Truth, 65..128 Shadow) so nothing
        -- dedups; beyond 64 of either kind the ledger evicts the
        -- lowest-weight entry, so 64/64 is the real cap, not a chosen
        -- round number.
        -- ================================================================
        SELECT fractal_ledger_reset_hard(sid);
        SET i = 1;
        WHILE i <= 64 DO
            SELECT fractal_feedback_report(sid, i, 'positive');
            SET i = i + 1;
        END WHILE;
        SET i = 65;
        WHILE i <= 128 DO
            SELECT fractal_feedback_report(sid, i, 'negative');
            SET i = i + 1;
        END WHILE;
        SELECT fractal_ledger_truth_count(sid) INTO tc;
        SELECT fractal_ledger_shadow_count(sid) INTO sc;
        SELECT 'Phase A - fill (expect 64/64)' AS phase, tc AS truth_count, sc AS shadow_count;

        SELECT fractal_ledger_flush(sid) INTO flush_rc;
        IF flush_rc IS NULL THEN
            SELECT 'Enterprise tier IS loaded, but fractal_ledger_flush returned NULL -- check FRACTALSQL_ENTERPRISE_LEDGER_PATH is writable by the mysqld process. Skipping the remaining flush-dependent phases.' AS notice;
        ELSE
            SELECT fractal_ledger_verify(sid) INTO v_verify;
            SELECT 'Phase A - verify' AS phase, v_verify AS chain_report;

            -- ============================================================
            -- Phase B: churn -- 5 reset/fill/flush cycles at capacity.
            -- Confirms the append-only chain stays internally consistent
            -- under repeated writes, not just a single flush.
            -- ============================================================
            SET c = 1;
            WHILE c <= 5 DO
                SELECT fractal_ledger_reset_hard(sid);
                SET i = 1;
                WHILE i <= 64 DO
                    SELECT fractal_feedback_report(sid, i + 1000 * c, 'positive');
                    SET i = i + 1;
                END WHILE;
                SET i = 65;
                WHILE i <= 128 DO
                    SELECT fractal_feedback_report(sid, i + 1000 * c, 'negative');
                    SET i = i + 1;
                END WHILE;
                SELECT fractal_ledger_flush(sid);
                SET c = c + 1;
            END WHILE;
            SELECT fractal_ledger_truth_count(sid) INTO tc;
            SELECT fractal_ledger_shadow_count(sid) INTO sc;
            SELECT fractal_ledger_verify(sid) INTO v_verify;
            SELECT 'Phase B - churn (5 flush cycles at capacity)' AS phase,
                   tc AS truth_count, sc AS shadow_count, v_verify AS chain_report;

            -- ============================================================
            -- Phase C: a short append-only chain, verified. Three flushes,
            -- each preceded by reset_hard so each is its own chain link
            -- with distinct content, giving fractal_ledger_verify() three
            -- real rows to walk rather than one big blob.
            -- ============================================================
            SELECT fractal_ledger_reset_hard(sid);
            SELECT fractal_feedback_report(sid, 1, 'positive');
            SELECT fractal_ledger_flush(sid);
            SELECT fractal_ledger_reset_hard(sid);
            SELECT fractal_feedback_report(sid, 2, 'positive');
            SELECT fractal_ledger_flush(sid);
            SELECT fractal_ledger_reset_hard(sid);
            SELECT fractal_feedback_report(sid, 3, 'positive');
            SELECT fractal_ledger_flush(sid);

            SELECT fractal_ledger_verify(sid) INTO v_verify;
            SELECT 'Phase C - chain (3 fresh links)' AS phase, v_verify AS chain_report;

            SELECT 'Enterprise stress demo: ACTIVE -- Phases A-C ran clean. See this file''s header comment for Phase D (tamper-evidence), which needs out-of-band filesystem access.' AS notice;
        END IF;
    END IF;
END$$
DELIMITER ;
CALL demo_enterprise_stress();
DROP PROCEDURE demo_enterprise_stress;

-- =====================================================================
-- Phase D: tamper-evidence recipes (out-of-band, not run by this script)
-- =====================================================================
--
-- Both recipes below target FRACTALSQL_ENTERPRISE_LEDGER_PATH (default
-- fractalsql_ledger.dat, relative to mysqld's cwd -- the datadir root in
-- the official Docker image, /var/lib/mysql/fractalsql_ledger.dat). Run
-- the recipe, then re-run `SELECT fractal_ledger_verify(CONNECTION_ID());`
-- in a NEW `mariadb` invocation (fractal_ledger_verify reads the file
-- fresh every call, no caching, so no restart is needed for this part).
--
-- --- D1: structural truncation -------------------------------------
-- Cuts the file below the file header (9 bytes: 8-byte magic + 1-byte
-- version), so the very next read fails immediately.
--
--   docker compose exec mariadb bash -c \
--     'truncate -s 5 /var/lib/mysql/fractalsql_ledger.dat'
--
-- fractal_ledger_verify() then returns
--   {"ok":false,"first_failure_id":0,"reason":"bad ledger file header"}
--
-- Not self-healing: fractal_ledger_write_entry opens an existing file
-- with fopen(path, "r+b") and refuses to write if the header it finds
-- doesn't match, rather than falling back to starting a fresh file. A
-- truncated-to-a-bad-header ledger stays stuck (fractal_ledger_flush()
-- itself also returns NULL after this, not just fractal_ledger_verify())
-- until the file is deleted --
--   docker compose exec mariadb rm -f /var/lib/mysql/fractalsql_ledger.dat
-- starts a genuinely fresh chain on the next flush.
--
-- --- D2: entry-hash tamper (flips a byte in an EARLIER record, not the
-- tip) --------------------------------------------------------------
-- Demonstrates the same O(1)-tip-only vs O(n)-full-walk boundary
-- fractal_ledger_load()/fractal_ledger_verify() document elsewhere:
-- fractal_ledger_load() only re-derives the chain tip on its own O(1)
-- check, so a tampered EARLIER record doesn't block it; only
-- fractal_ledger_verify()'s full walk catches it. Run this right after
-- Phase C above so there are at least 3 kind=1 records to pick from.
--
--   docker compose exec mariadb python3 -c "
--   import struct
--   path = '/var/lib/mysql/fractalsql_ledger.dat'
--   with open(path, 'rb') as f: data = bytearray(f.read())
--   pos = 9  # past the 8-byte magic + 1-byte version file header
--   first_blob_off = None
--   while pos < len(data):
--       kind, blen = struct.unpack_from('<II', data, pos)
--       if kind == 1 and first_blob_off is None:
--           first_blob_off = pos + 116  # past this record's fixed header
--       pos += 116 + blen
--   data[first_blob_off] ^= 0xFF
--   with open(path, 'wb') as f: f.write(data)
--   "
--
-- Result:
--   fractal_ledger_load(CONNECTION_ID())     -> still succeeds (tip-only)
--   fractal_ledger_verify(CONNECTION_ID())   ->
--     {"ok":false,"first_failure_id":1,"reason":"entry_hash mismatch (structural tamper)"}
--
-- --- D3: HMAC-authenticated tamper (needs FRACTALSQL_ENTERPRISE_LEDGER_KEY
-- set when the container/mariadbd STARTED -- MariaDB has no per-session
-- server system variable to set this mid-script) -------------------------
-- With a ledger key configured, every entry also carries an HMAC-SHA256
-- tag (see enterprise.md). D2's byte-flip recipe above, run against a
-- keyed ledger, is caught by the MAC even in cases a pure structural
-- check might miss (e.g. a flip that happens to preserve blen and the
-- recomputed structural hash coincidentally -- astronomically unlikely
-- for SHA-256, but the MAC is the actual cryptographic guarantee, the
-- hash chain alone is only tamper-EVIDENT, not tamper-PROOF, against a
-- motivated attacker who can also rewrite entry_hash itself). With
-- FRACTALSQL_ENTERPRISE_LEDGER_KEY set at container start,
-- fractal_ledger_verify() reports
--   {"ok":false,"first_failure_id":1,"reason":"HMAC mismatch"}
-- for the same D2 recipe once every entry carries a MAC.
