<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Enterprise Tier: QTL Ledger & CISO Audit

The Enterprise tier adds a tamper-evident decision ledger on top of the core extension: activation gating (dlopen an enterprise core library on demand, thin SQL wrappers around it) plus a real ledger storage layer (an append-only hash chain with optional HMAC-SHA256 tamper tagging and chain verification). The ledger is file-backed rather than table-backed, because MariaDB's C UDF ABI has no way for a UDF to execute SQL against its own calling session. The portfolio-diversity optimization surface (`fractal_optimize_portfolio_multimodal`/`_pareto` and the paired `fractal_agent_diverse_portfolios` agent) is not available in this edition; see **What's not here, and why** below.

The core FractalSQL extension (Analytics, Discovery, Vector, Cognition, Agency) ships in the Community edition and works fine on its own; none of it needs anything described on this page.

---

## What's real here

Ten thin SQL wrapper UDFs, dlopen/dlsym-gated against a separately-built enterprise core library (`src/fractalsql_enterprise.c`, portable `dlopen`/`dlsym` on Linux/macOS, `LoadLibrary`/`GetProcAddress` on Windows):

| Function | Purpose (once loaded) |
| --- | --- |
| `fractal_ledger_flush(session_id)` | Encode the session's truth + shadow ledgers and append to the chain (genuinely persists to the file-backed ledger). |
| `fractal_ledger_load(session_id)` | Hydrate the in-memory ledgers from the chain's latest entry. |
| `fractal_ledger_compact(session_id)` | Defragment / re-pack the in-memory representation. |
| `fractal_ledger_reset_soft(session_id)` | Soft-reset ledger counters without dropping history. |
| `fractal_ledger_reset_hard(session_id)` | Hard-reset the ledgers to empty. |
| `fractal_ledger_truth_count(session_id)` | Truth-side entry count (`BIGINT`). |
| `fractal_ledger_shadow_count(session_id)` | Shadow-side entry count (`BIGINT`). |
| `fractal_ledger_verify(session_id [, kind])` | Full O(n) walk of the persisted chain for `kind` (default 1). Returns `{"ok":true,"rows_verified":N}` or `{"ok":false,"first_failure_id":N,"reason":"..."}`. A pure storage-layer check: does not require the enterprise library loaded. |
| `fractal_audit_log(entry_type, payload_json)` | Append a provenance record to the general decision-audit chain (`kind=2`, independent of the QTL Truth/Shadow chain's `kind=1`). Also called automatically, best-effort, from `fractal_optimize_portfolio` (see `src/fractalsql.c`'s `portfolio_audit_log_best_effort`), a Community-tier function: it silently no-ops when the enterprise library isn't loaded, so portfolio optimization keeps working on Community unchanged. |
| `fractal_audit_unpack(blob)` | Decode a persisted QTL or audit blob into its JSON event log. |

All ten operate on the same connection-scoped context every community search feature uses (`fractal_session_acquire`). `session_id` is `CONNECTION_ID()`, the same convention as `fractal_reason`/`fractal_embed`/`fractal_search`.

### Ledger storage: a real, file-backed persistence layer

The ledger is an append-only chain of records per `kind`, each linking to its predecessor via `entry_hash = SHA256(prev_hash || blob || mac)`, stored in a local file rather than a SQL table. A rewritten or deleted record breaks the very next record's `prev_hash` link, so tampering is visible without separate id-sequence bookkeeping.

- **Path**: `FRACTALSQL_ENTERPRISE_LEDGER_PATH` (optional), default `fractalsql_ledger.dat`, relative to `mysqld`'s own working directory. In the official Docker image, that directory is the datadir root (`/var/lib/mysql/fractalsql_ledger.dat`), not any per-database subdirectory.
- **Tamper authentication**: `FRACTALSQL_ENTERPRISE_LEDGER_KEY` (optional). Unset means structural-only validation (the hash chain alone); set, every entry also carries an HMAC-SHA256 tag.
- **Concurrency**: MariaDB has no transaction-scoped locking primitive reachable from a UDF, so writes hold a process-wide mutex for the duration of one read-modify-append call. Narrower than a full transaction, but MariaDB is one shared process for every connection, so this still fully serializes concurrent writers against each other.

### Optional: reading the ledger back with plain SQL

`sql/install_enterprise_connect.sql` maps the ledger's CSV mirror into a real, read-only table via MariaDB's CONNECT storage engine (a separate plugin, `INSTALL SONAME 'ha_connect';`, not guaranteed present on every deployment). A CISO audit trail decodes straight back through `fractal_audit_unpack`:

```sql
SELECT fractal_audit_unpack(FROM_BASE64(blob_b64))
  FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
-- [{"epoch":1,"doc_id":1,"signal":"truth"}, ...]
```

### Detached signature verification

`ensure_enterprise_lib()` (`src/fractalsql_enterprise.c`) verifies the enterprise `.so`'s detached Ed25519 signature via OpenSSL's EVP API (`-lcrypto`, linked in the `Makefile`) before `dlopen`ing it. An **invalid** signature (a sibling `<path>.sig` present but wrong) always refuses to load, regardless of configuration: unambiguous tamper evidence. A **missing** `.sig` only refuses when `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE` is set to a non-empty, non-`0` value; otherwise it loads unverified and logs a warning to `mariadbd`'s error log (there is no SQL-visible `WARNING` channel reachable from this lazy, first-call load path). Off by default, so this is backward compatible with an unsigned enterprise `.so`.

```bash
export FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1
```

### Activation

```bash
export FRACTALSQL_ENTERPRISE_LIB=/path/to/libfractalsql-enterprise-sovereign-c.so
# optional:
export FRACTALSQL_ENTERPRISE_LEDGER_PATH=/var/lib/mysql/fractalsql_ledger.dat
export FRACTALSQL_ENTERPRISE_LEDGER_KEY=<hmac-key>
export FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1
```

Every variable is a process environment variable, read once by `mariadbd`. `FRACTALSQL_ENTERPRISE_LIB` is read lazily, on the first enterprise-tier call from any session (not at startup; it only tries to `dlopen` when something actually asks). **There is no sysvar, GUC, or `SET GLOBAL`**: every tier is configured through process environment variables, not a MariaDB system-variable surface. To activate or deactivate, set or unset the variable and restart `mariadbd`.

### Community edition (default) behavior

Calling a dormant enterprise function returns a clean **`NULL`**, with no exception and no error text visible to the client, rather than raising a catchable error. This is a consequence of the MariaDB UDF error-signaling convention: setting `*error = 1` inside a UDF's main function marks that row's result NULL and stops the server from calling the function again for the rest of that statement, but it does not surface as a `SQLSTATE`/message the way `SIGNAL` does. MariaDB's C UDF ABI has no equivalent of `SIGNAL` for a row-level failure inside the main function; only inside the UDF's `_init`, which the client does see as a real error at `CALL` time. Calling `fractal_ledger_flush` with no `FRACTALSQL_ENTERPRISE_LIB` set returns `NULL`, cleanly, every time. If your application needs to distinguish "not licensed" from "genuinely no data," check for `NULL` explicitly rather than expecting an error to catch.

```sql
SELECT fractal_ledger_flush(CONNECTION_ID());
-- NULL  (dormant: FRACTALSQL_ENTERPRISE_LIB not set, or the library failed to load)
```

**Removing the library re-dormants the surface**: unset the variable (or point it at a missing path) and restart. All ten functions go back to returning `NULL`, with no recompile. Every community primitive keeps working unchanged.

---

## What's not here, and why

`fractal_optimize_portfolio_multimodal`/`_pareto` (the Analytics-tier functions the Enterprise portfolio-diversity story depends on) and their paired `fractal_agent_diverse_portfolios` agent are not available in this edition. These are enterprise-tier portfolio-optimization primitives that need a real enterprise library implementing the multimodal/Pareto search itself, which is out of scope here.

Everything else described above, the ledger, its verification, and CISO audit logging, is a genuine, persistent ledger once `FRACTALSQL_ENTERPRISE_LIB` points at a real enterprise core library: a clean, honest `NULL` on Community, and real storage on Enterprise.

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.
