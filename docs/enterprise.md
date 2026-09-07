<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Enterprise Tier — CISO Decision Audit & Quantized Ternary Ledger (QTL)

QTL is a hash-chained, tamper-evident audit ledger for agent and optimizer
decisions. The mechanism is described in full below.

The core FractalSQL extension (Discovery, Cognition, and Agency) ships in
the Community edition and works fine on its own; none of it needs anything
described on this page. This tier exists for regulated environments
that need to prove what an optimizer decided, not just claim it:
every optimizer call can write a tamper-evident record a
CISO or auditor can verify, rather than a log line they simply have to trust.

This is delivered as a drop-in core library: **no rebuild, no extension
reload**. The same community extension binary ships the SQL signatures;
whether they do real work depends entirely on a runtime environment
variable.

**Community edition (default):** all nine functions are present but
**dormant**. Calling one returns a clean `NULL` — MariaDB's C UDF ABI has
no row-level `SIGNAL`-equivalent, so a dormant UDF surfaces as NULL, not a
client-visible error:

```sql
SELECT fractal_ledger_flush(CONNECTION_ID());
-- NULL  (dormant: FRACTALSQL_ENTERPRISE_LIB not set, or the library failed to load)
```

**Enterprise edition:** drop the enterprise core shared library into
`include/` (or anywhere readable by the server) and point the
`FRACTALSQL_ENTERPRISE_LIB` environment variable at it:

```bash
export FRACTALSQL_ENTERPRISE_LIB=/path/to/libfractalsql-enterprise-sovereign-c.so
```

The variable is read once by `mariadbd` at startup, so activating means
setting it and restarting `mariadbd` (there is no reload-without-restart
path; every tier in this repo is a process environment variable, not a
MariaDB system-variable surface). The nine functions then activate and
operate on the same in-memory context the community search engine already
built (eight ledger-management functions plus `fractal_audit_unpack` for
CISO decode), and the ledger persists through a file-backed storage VFS
into the local ledger file. MariaDB's C UDF ABI gives a UDF no way to
execute SQL against its own calling session, so the ledger cannot live
in a SQL table: it is the file named by `FRACTALSQL_ENTERPRISE_LEDGER_PATH`
(optional, default `fractalsql_ledger.dat`, relative to `mariadbd`'s own
working directory — the server chdir()s to its datadir at startup, so a
standard install puts it in the datadir root), and concurrent writes
serialize behind a process-wide mutex, since `mariadbd` is one shared
process for every connection:

| Function | Purpose |
| --- | --- |
| `fractal_ledger_flush(session_id)` | Encode truth + shadow ledgers into a QTL blob and append it to the chain. |
| `fractal_ledger_load(session_id)` | Hydrate the in-memory ledgers from the chain's latest entry (verifies only the tip, O(1)). |
| `fractal_ledger_verify(session_id [, kind])` | Walk the ENTIRE chain (O(n), on demand) and return a JSON audit report. |
| `fractal_ledger_compact(session_id)` | Defragment / re-pack the in-memory QTL representation. |
| `fractal_ledger_reset_soft(session_id)` | Soft-reset ledger counters without dropping history. |
| `fractal_ledger_reset_hard(session_id)` | Hard-reset the ledgers to empty. |
| `fractal_ledger_truth_count(session_id)` | Truth-side entry count (`BIGINT`). |
| `fractal_ledger_shadow_count(session_id)` | Shadow-side entry count (`BIGINT`). |
| `fractal_audit_unpack(blob)` | Decode a persisted QTL blob into its audit JSON. |

`session_id` is `CONNECTION_ID()` by convention, the same convention as
`fractal_reason`/`fractal_embed`/`fractal_search` — MariaDB UDFs have no
ambient way to ask "what connection am I on," and each session needs its
own in-memory context.

**Removing the library re-dormants the surface**: point the environment
variable back at a missing path (or unset it) and restart. The functions
return to the dormant `NULL` with no recompile. The search engine and
every community primitive keep working unchanged; only the ledger/audit
surface is gated.

**`fractal_audit_log(entry_type, payload_json)`**: the general decision-audit
chain. A second, independent append-only chain in the ledger
(`kind=2`, same hash-chain guarantees as the QTL chain, verify with
`fractal_ledger_verify(2)`) for provenance records rather than QTL blobs.
`fractal_text_to_sql`, `fractal_optimize_portfolio`,
`fractal_optimize_portfolio_multimodal` (and its `_ex` and `_pareto`
siblings), and every decision-making agent below log to it automatically
when enterprise is active. Silently skipped on community, so none of
them ever depend on a license to keep working. Query it directly (CONNECT
mirror installed): `SELECT id, FROM_BASE64(blob_b64) FROM fractalsql_ledger
WHERE kind = 2 ORDER BY id`.

Every decision-making agent in `sql/install_agents.sql` logs its own
decision to the same chain with the same best-effort, community-safe
pattern (MariaDB needs no exception wrapper around the call: a dormant
`fractal_audit_log` returns `NULL` and writes nothing, so a missing
enterprise tier never breaks the agent): `fractal_agent_anomaly_triage`,
`fractal_agent_allocate`, `fractal_agent_route_task`,
`fractal_agent_outlier_intercept`, `fractal_agent_data_analyst`,
`fractal_agent_patient_deterioration_triage`,
`fractal_agent_schedule_workload`, `fractal_agent_rebalance_sibling`,
`fractal_agent_detour_classify`, `fractal_agent_track_anomaly`,
`fractal_agent_network_coverage_alert`, `fractal_agent_regime_triage`,
and `fractal_agent_diverse_portfolios`. The pure-retrieval/pure-analytics
engines (`fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`,
`fractal_agent_feedback_audit`) don't make a decision worth auditing, so
they're intentionally not wired up.

**`fractal_optimize_portfolio_multimodal(mu_csv, cov_csv, k, n_restarts,
overlap_threshold, quality_frac, seed)`** (enterprise tier): like
`fractal_optimize_portfolio` but runs several independent restarts and
returns up to `n_restarts` structurally distinct portfolios instead of
one: candidates within `quality_frac` of the best Sharpe found, no two
sharing more than `overlap_threshold` of their assets. Same entropy
engine as the single-best version; the gate gives access to the
multi-restart + diverse-selection capability, not a different algorithm.
Paired agent: `fractal_agent_diverse_portfolios` (see
[`api-agency.md`](api-agency.md#diverse-portfolios-fractal_agent_diverse_portfolios-enterprise-tier)).
It logs to the decision-audit chain above the same way.

**`fractal_optimize_portfolio_multimodal_ex(...)` and
`fractal_optimize_portfolio_multimodal_pareto(...)`** (enterprise tier):
the `_ex` variant is the OBL/Lévy-flight-capable sibling of the function
above — same `n_restarts` search and diverse selection, with `use_obl`
(Opposition-Based Learning: evaluate each SFS trial candidate's
bound-reflected opposite, keep whichever fits better) and `diffusion_mode`
(`'gaussian'` default or `'levy'`, a heavy-tailed Mantegna-algorithm step
that can help escape local optima on highly multimodal problems) applied
uniformly to every restart's search. The `_pareto` variant is its
Pareto-front sibling: same `n_restarts` independent searches, but scores
each by decomposed **return/risk** instead of scalar Sharpe and reduces
them to a genuine non-dominated Pareto front (NSGA-II crowding-distance
truncation past `max_front`) rather than sharpe-threshold + asset-overlap
selection. Purely additive; doesn't change the sibling functions'
semantics. MariaDB UDFs have no default-argument syntax, so both take
their knobs positionally (`use_obl` as 0/1 — the UDF ABI has no BOOLEAN —
and `diffusion_mode` as `'gaussian'|'levy'`); the community
`fractal_optimize_portfolio` already accepts the same two knobs via its
trailing `params` JSON blob. The same `fractal_agent_diverse_portfolios`
agent exposes both via its `p_objective_mode` parameter
(`'sharpe'` default | `'pareto'`).

**Append-only chain, not a snapshot.** The ledger is a genuine history: every
record links to its predecessor via `entry_hash = SHA256(prev_hash || blob ||
mac)`, and writes are plain appends, never in-place edits. A rewritten
record breaks the chain; a deleted record leaves the same visible break.
This holds **even without a MAC key**: `entry_hash` covers the
blob unconditionally, so a byte-flip anywhere in history is structurally
detectable, not just cryptographically. Set the
`FRACTALSQL_ENTERPRISE_LEDGER_KEY` environment variable to additionally
**HMAC-SHA256-tag** each blob, authenticating it against forgery by anyone
who doesn't hold the key. `fractal_ledger_load()` checks only the chain's
tip on every call (cheap, O(1));
`fractal_ledger_verify()` walks the full chain for a periodic or on-demand
CISO audit (O(n), not run automatically). One honest limit: the chain can
prove nothing in the *middle* was altered or removed, but it can't prove
nothing was truncated off the very *end*: there's nothing after the last
record to notice its absence. That needs an external anchor (e.g. publishing
the head hash somewhere independent). See **External anchoring** below
for a recipe. (See `demo/enterprise-stress.sql` Phase D's tamper-evidence
recipes.)

A CISO audit trail can still be read back with plain SQL:
`sql/install_enterprise_connect.sql` maps the ledger's CSV mirror into a
real, read-only table via MariaDB's CONNECT storage engine (a separate
plugin, `INSTALL SONAME 'ha_connect';`, not guaranteed present on every
deployment), and `fractal_audit_unpack` decodes straight back through it:

```sql
SELECT fractal_audit_unpack(FROM_BASE64(blob_b64))
  FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;
-- [{"epoch":1,"doc_id":1,"signal":"truth"}, ...]
```

### External anchoring (closing the truncation gap)

The chain's tip (`kind`, `id`, `entry_hash_hex`) is readable once the
CONNECT mirror is installed (or straight from the ledger file's CSV
records, same columns, without it).
`scripts/enterprise/anchor-ledger.sh` automates it: pass the `kind` to
anchor (`1` = QTL, `2` = decision-audit), it reads the tip — O(1), no
full chain walk; `fractal_ledger_verify()` is the tool for that — and
emits one anchor record:

```
anchor kind=2 id=41 entry_hash=9f2c… row_updated=1735689600 anchored_at=2025-01-01T00:00:00Z
```

Run it on a schedule (cron, systemd timer), one line per `kind` you audit:

```bash
*/15 * * * * MARIADB_HOST=... MARIADB_DATABASE=... /path/to/anchor-ledger.sh 1 >> /var/log/fractalsql/anchor.log
*/15 * * * * MARIADB_HOST=... MARIADB_DATABASE=... /path/to/anchor-ledger.sh 2 >> /var/log/fractalsql/anchor.log
```

Where that record *publishes* to is the part that satisfies the guarantee
— plain stdout redirection alone records the hash, but only a store the
DB admin can't rewrite satisfies the guarantee; pick your target with that
bar in mind. The script ships commented-out sink examples (syslog via
`logger` for SIEM ingestion, an S3 Object Lock bucket, a compliance
mailbox) and leaves the choice open.

To verify an anchor later, confirm the live mirror still has a row at the
anchored `id`, for that `kind`, with that exact `entry_hash_hex`:

```sql
SELECT entry_hash_hex = '<anchored hex>'
  FROM fractalsql_ledger WHERE kind = <kind> AND id = <anchored id>;
```

`0` or no matching row means the record was altered, or the chain was
rewound past it, after the anchor was taken.

**Detached signature verification (optional hardening).** The 8-symbol
`dlsym` check in `ensure_enterprise_lib()` only proves a file has the right
function *names*. A tampered file with the same names sails through it
untouched. Set `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1` to additionally
require a valid detached Ed25519 signature (a sibling `<path>.sig` file,
64 raw bytes) against a fixed FractalSQLabs public key — verified via
OpenSSL's EVP API before the library is loaded. Off by default: a missing
`.sig` only logs a warning to `mariadbd`'s error log (there is no
SQL-visible `WARNING` channel reachable from this lazy, first-call load
path) and the library still loads, so this is backward compatible with
unsigned releases. An **invalid** signature (present but wrong) is
always refused regardless of the setting: unambiguous tamper evidence,
unlike a merely absent file. New enterprise releases only need a fresh
signature from the same long-lived key; this extension never needs
rebuilding, preserving the drop-in-`.so` design a hash pin would have broken.
(See `build_test` gate 26.)

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.