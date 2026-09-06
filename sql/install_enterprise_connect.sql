-- sql/install_enterprise_connect.sql
--
-- Makes the QTL/audit ledger genuinely SQL-queryable via the MariaDB
-- CONNECT storage engine, reading the CSV mirror src/fractalsql_
-- enterprise.c's ledger_write_entry maintains alongside the authoritative
-- binary chain file (see that file's header for the full design).
--
-- OPTIONAL. Only meaningful once the Enterprise tier is actually active
-- (FRACTALSQL_ENTERPRISE_LIB set) -- on a Community deployment the mirror
-- file never gets written, so this table simply reads back empty. Not
-- run by install_udf.sql itself: CONNECT is a separate MariaDB plugin
-- (package mariadb-plugin-connect on Debian/Ubuntu), not guaranteed
-- present on every deployment, so this is a standalone, opt-in step.
--
-- Usage:
--   1. (once per server) INSTALL SONAME 'ha_connect';
--      -- or: apt-get install mariadb-plugin-connect, if ha_connect.so
--      -- isn't already present under mysqld's plugin_dir.
--   2. mariadb < sql/install_enterprise_connect.sql
--
-- The FILE_NAME must be an ABSOLUTE path, not a bare relative one.
-- Confirmed empirically: mysqld writes the ledger relative to its own
-- cwd (the datadir root, e.g. /var/lib/mysql/fractalsql_ledger.dat.csv),
-- but MariaDB's CONNECT engine resolves a relative FILE_NAME against
-- the TABLE's OWN per-database directory instead (e.g.
-- /var/lib/mysql/fractalsql_demo/), which never has the file -- a plain
-- relative FILE_NAME here silently reads back zero rows, always,
-- regardless of how much has actually been flushed. Built below from
-- @@GLOBAL.datadir so this works on any datadir, not just the default.
--
-- If FRACTALSQL_ENTERPRISE_LEDGER_PATH is set to something other than
-- "fractalsql_ledger.dat" (or to an absolute path of its own), edit
-- @ledger_file below to match -- the CSV mirror always lives alongside
-- the binary file with a .csv suffix appended, see ledger_csv_path()
-- in src/fractalsql_enterprise.c.
--
-- READONLY=1 is load-bearing, not a style choice: the CSV mirror carries
-- no hash-chain enforcement of its own (that lives only in the binary
-- file), so a writable CONNECT table would let a plain SQL client insert
-- or edit rows that fractal_ledger_verify would then have no way to
-- prove were never actually flushed. All real writes go through
-- fractal_ledger_flush / fractal_audit_log; this table is a read
-- surface only.
DROP TABLE IF EXISTS fractalsql_ledger;
SET @ledger_file = CONCAT(@@GLOBAL.datadir, 'fractalsql_ledger.dat.csv');
SET @ddl = CONCAT('CREATE TABLE fractalsql_ledger (
    id              BIGINT,
    kind            INT,
    blob_b64        VARCHAR(60000) CHARACTER SET latin1,   -- FROM_BASE64(blob_b64) recovers the raw QTL/audit blob; latin1 (1 byte/char) to clear the utf8mb4 65535/4 VARCHAR ceiling; 60000 (not 65000) to leave headroom under the table''s overall 65535-byte row-size ceiling once the other columns are added
    mac_hex         CHAR(64),          -- NULL/empty when FRACTALSQL_ENTERPRISE_LEDGER_KEY is unset
    prev_hash_hex   CHAR(64),
    entry_hash_hex  CHAR(64),
    sealed          TINYINT,
    updated         BIGINT             -- unix epoch seconds; wrap in FROM_UNIXTIME() to format
) ENGINE=CONNECT TABLE_TYPE=CSV
  FILE_NAME=''', @ledger_file, '''
  SEP_CHAR='','' QUOTED=0 READONLY=1');
PREPARE _fractalsql_ent_connect_ddl FROM @ddl;
EXECUTE _fractalsql_ent_connect_ddl;
DEALLOCATE PREPARE _fractalsql_ent_connect_ddl;

-- Examples:
--   -- The QTL Truth/Shadow chain, newest first:
--   SELECT id, updated, FROM_BASE64(blob_b64) AS blob
--     FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC;
--
--   -- CISO audit: decode the latest QTL blob (closes the "Phase B"
--   -- gap noted in demo/enterprise-qtl-audit.sql -- no separate
--   -- export UDF needed, FROM_BASE64 does it):
--   SELECT fractal_audit_unpack(FROM_BASE64(blob_b64))
--     FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
--
--   -- The general decision-audit trail written by fractal_audit_log /
--   -- fractal_optimize_portfolio's best-effort provenance logging:
--   SELECT id, FROM_UNIXTIME(updated) AS logged_at, FROM_BASE64(blob_b64) AS entry
--     FROM fractalsql_ledger WHERE kind = 2 ORDER BY id;
--
--   -- Full chain-of-custody check straight from SQL, independent of
--   -- fractal_ledger_verify's own O(n) walk:
--   SELECT COUNT(*) AS rows_in_mirror FROM fractalsql_ledger WHERE kind = 1;
