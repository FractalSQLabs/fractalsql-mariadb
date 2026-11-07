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
whether they do real work depends entirely on `fractalsqld`'s own
configuration: the `enterprise_lib` key in `fractalsqld.conf` (preferred,
live-reloadable), or a `FRACTALSQL_ENTERPRISE_*` environment variable as
the fallback (see [Configuration and live reload](#configuration-and-live-reload) below).

**Community edition (default):** all nine functions are present but
**dormant**. Calling one returns a clean `NULL` — MariaDB's C UDF ABI has
no row-level `SIGNAL`-equivalent, so a dormant UDF surfaces as NULL, not a
client-visible error:

```sql
SELECT fractal_ledger_flush(CONNECTION_ID());
-- NULL  (dormant: the enterprise tier isn't configured, or the library failed to load)
```

**Enterprise edition:** drop the enterprise core shared library into
`include/` (or anywhere readable by `fractalsqld` -- the enterprise loader
runs in the daemon, not in `mariadbd`) and point the daemon at it. The
preferred way is the `enterprise_lib` key in `fractalsqld.conf` (the
daemon's config file, the file `fractalsqld -c` names):

```ini
# fractalsqld.conf
enterprise_lib = /path/to/libfractalsql-enterprise-sovereign-c.so
```

The `FRACTALSQL_ENTERPRISE_LIB` environment variable is the
fallback for keys the conf file doesn't set:

```bash
export FRACTALSQL_ENTERPRISE_LIB=/path/to/libfractalsql-enterprise-sovereign-c.so
```

Conf-file settings are pushed by both daemon startup and every `fsqlctl
reload`, so activating the tier on a daemon with no enterprise library
loaded needs no restart at all: set `enterprise_lib`, run `fsqlctl
reload`, and the tier loads it on the next enterprise call. The
process-environment fallback is a different story: it is captured once by
`fractalsqld` at startup (`mariadbd` and the shim it loads are untouched
either way; none of this is a MariaDB system-variable surface), so an
environment change means restarting `fractalsqld`.
The nine functions then activate and
operate on the same in-memory context the community search engine already
built (eight ledger-management functions plus `fractal_audit_unpack` for
CISO decode), and the ledger persists through a file-backed storage VFS
into the local ledger file. MariaDB's C UDF ABI gives a UDF no way to
execute SQL against its own calling session, so the ledger cannot live
in a SQL table: it is the file named by `enterprise_ledger_path` in
`fractalsqld.conf` (or by the `FRACTALSQL_ENTERPRISE_LEDGER_PATH`
environment variable, for a key absent from the conf file; optional,
default
`fractalsql_ledger.dat`, relative to `fractalsqld`'s own
working directory). Unlike `mariadbd` -- which always chdir()s to its
datadir, giving the old default a stable, predictable location --
`fractalsqld`'s working directory depends on how it's launched: the
packaged systemd unit sets it to `/var/lib/fractalsql`, but a manual
launch, a launchd job, or a Windows service may default elsewhere (even
`/`). **Set `enterprise_ledger_path` to an explicit absolute
path** rather than relying on the relative default. Concurrent writes
serialize behind a process-wide mutex, since `fractalsqld` is one shared
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

**Locking the destructive functions.** `fractal_lock_destructive(session_id)` is a
**one-way latch** (returns `1`): afterwards `fractal_ledger_flush`,
`fractal_ledger_compact`, `fractal_ledger_reset_soft`,
`fractal_ledger_reset_hard` and `fractal_ledger_load` refuse for that session
id (they return `NULL`, the UDF error convention), whether or not an enterprise
core is loaded. `fractal_ledger_load` is latched too because it overwrites the
live in-memory ledger state, so a latched session must not be able to roll the
ledger back. The read-only functions are unaffected. There is no
unlock function: the latch lasts until the `fractalsqld` daemon restarts. The MCP
server calls it with its own connection id when `FSQL_MCP_READ_ONLY=true`, on top
of its own refusal of the `destructiveHint` tools, so a mis-annotated tool cannot
wipe the ledger either.

Know the limit: the latch is keyed by **the session id the caller passes**, and a
MariaDB UDF cannot tell which connection is calling it. It therefore protects the
calls that use the locked id (everything the MCP server itself sends), and it does
**not** stop a caller who passes a different `session_id`. MariaDB has no
per-function privileges for UDFs, so there is no equivalent of PostgreSQL's
`REVOKE EXECUTE` or SQLite's `SQLITE_DIRECTONLY` here; to keep other people away
from the ledger, restrict who can connect, or do not install the destructive
ledger functions for that deployment. If the engine is older than the plugin and
lacks the function, the MCP server logs a warning and keeps its own refusal in
force.

**Removing the library re-dormants the surface**: point `enterprise_lib`
back at a missing path (or remove it) and restart `fractalsqld` -- while a
library is loaded, reload refuses an `enterprise_lib` change, so
deactivating a tier that's already loaded is a restart, not a reload. The
functions
return to the dormant `NULL` with no recompile. The search engine and
every community primitive keep working unchanged; only the ledger/audit
surface is gated.

### Configuration and live reload

The four enterprise keys are part of `fractalsqld.conf` (the daemon's
config file, started with `-c`), which is the **preferred** source for all
of the provider settings -- enterprise keys included. The `FRACTALSQL_*`
environment variables remain a fallback for any key the conf file doesn't
set, captured once at daemon startup. Both daemon startup and `fsqlctl
reload` push these settings:

| `fractalsqld.conf` key | env fallback | meaning |
| --- | --- | --- |
| `enterprise_lib` | `FRACTALSQL_ENTERPRISE_LIB` | path to the enterprise core shared library |
| `enterprise_ledger_path` | `FRACTALSQL_ENTERPRISE_LEDGER_PATH` | ledger file (default `fractalsql_ledger.dat`) |
| `enterprise_ledger_key` | `FRACTALSQL_ENTERPRISE_LEDGER_KEY` | HMAC-SHA256 key (a secret; plaintext in the conf) |
| `enterprise_require_signature` | `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE` | `0`/`1` gate requiring a valid detached signature on load (default `1`) |

Reload semantics, verified in `src/fractalsql_enterprise.c`:

- **`enterprise_lib` cannot be *changed* while a library is already
  loaded.** Such a reload refuses loudly, with the key named:
  `reload refused: enterprise_lib cannot be changed live while an
  enterprise library is loaded (currently "...")`. Restart the daemon to
  change it. Changes made while *unloaded* are fine -- nothing holds a
  handle, no library has been loaded yet, or a previous load attempt never
  got that far -- and re-arm the load attempt: set `enterprise_lib`, run
  `fsqlctl reload`, and the next enterprise call loads it.
- **`enterprise_ledger_path` may be swapped live, and the swap is safe.**
  Every ledger operation opens the ledger file, does its work, and closes
  it per call, so the next operation simply opens the new file. Continuity
  of ledger content across a path change, however, is the **operator's**
  responsibility: the old file keeps the old history and nothing is copied
  or merged automatically -- if the chain must survive the move, copy or
  merge the old file's content into the new path yourself before relying
  on the new file being the whole history.
- `enterprise_ledger_key` and `enterprise_require_signature` change live
  like the rest, and are `1`/`0` flags or strings. The ledger key is a
  **secret**, and because it may sit in the conf in plaintext (like its
  reasoning sibling `reasoning_token`), the conf file itself is
  permission-gated like the HMAC key file it lives next to: a
  world-readable `fractalsqld.conf` refuses daemon startup *and* reload
  (`chmod 600` on POSIX; on Windows an ACL that grants Everyone,
  Authenticated Users or Users refuses it too — a private, single-account
  ACL is what it wants).
- Reload validation is loud and named: unknown keys log a warning, an
  empty value is refused, and any key that comes with a range constraint
  rejects a bad value with the constraint itself (the conf file is the
  daemon's, so `fsqlctl reload` also refuses `socket_path`/`hmac_key_file`
  changes -- those are startup-only).

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

The `kind=2` chain is shared with the engine's own **shadow** payloads
(the engine's storage tags are 1=truth, 2=shadow, 3=shadow_vectors), so
a `WHERE kind = 2` query can return both a decision-audit record and an
engine shadow blob. That is harmless: the ledger keeps one hash chain
*per kind*, so the two never interleave or break each other's links,
and the verifier walks one kind's chain at a time. Only the tags the
ledger knows are accepted — a kind outside 1..16 is refused outright
rather than appended under a tag nothing would ever walk.

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
`enterprise_ledger_key` conf key (or the `FRACTALSQL_ENTERPRISE_LEDGER_KEY`
environment variable, the fallback for absence from the conf file) to
additionally
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

**A corrupt length is refused, not believed.** The on-disk record header
carries the blob's length as a 32-bit field, and the reader bounds it: a
record claiming a length far beyond anything this extension writes is
treated as a corrupt record and reported as one, rather than being
allocated and hashed on the strength of a number that came out of the
file. A tail that was truncated by a crash is still repaired
automatically on the next write.

**`first_failure_id` counts records in the file, not records of one
kind.** One ledger file carries the QTL chain, the decision-audit chain
and the write-ahead records side by side, and the verifier walks one
kind's chain at a time. The id it reports on a failure is the record's
position in the FILE (1-based), so it is the number an operator can
actually go and look the record up by; the count of records verified
(`rows_verified`) remains the count for the kind that was asked for.

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

#### Two things the CSV mirror does not do

The **binary chain file is the sole authoritative store**; the CSV is a
best-effort, read-only convenience view of it, and two gaps follow from
that. Both are properties of the mirror, not of the chain — the chain
itself is unaffected by either.

1. **Torn-tail repair does not repair the mirror.** If a crash truncates
   the binary file mid-record, the repair step truncates the *binary* file
   at that record, but the CSV keeps the row for the record that was
   discarded. After such a crash the mirror can therefore carry **one row
   the chain no longer has** — and the mirror is never rewritten from the
   binary file. `fractal_ledger_verify` reads the binary file, so it is
   the authority on what the chain holds; treat a mirror row with no
   corresponding chain record as an artifact of the crash, not as a
   tampered record.
2. **The mirror's path is not derived from the ledger's path.** The CSV
   lives beside the binary chain file (`<ledger path>.csv`), but
   `sql/install_enterprise_connect.sql` **hard-defaults** its `FILE_NAME`
   to `/run/fractalsql/fractalsql_ledger.dat.csv`. If the daemon runs
   with a non-default `enterprise_ledger_path`, set the path in the
   install script's `@fsql_ledger_csv` variable (or edit the COALESCE)
   to match. Getting this wrong is **silent**: the CONNECT table is
   created fine and simply reads zero rows, which looks exactly like an
   empty ledger.

The mirror's `id` column is the record's position in the chain — a single
sequence shared by kind=1 and kind=2 rows, so `ORDER BY id DESC` names
the same row the chain's own tip does. It is taken from the chain's
record count rather than re-derived from the mirror file's own line
count, so a CSV row that failed to write (the CSV write is best-effort)
leaves a gap in the mirror's ids instead of handing the same id out
twice.

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

Where that record *publishes* to is the part that satisfies the guarantee:
plain stdout redirection alone records the hash, but only a store the
DB admin can't rewrite meets that bar. Pick your target with it in mind.
The script ships commented-out sink examples (syslog via
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

**Detached signature verification.** The 8-symbol `dlsym` check in
`ensure_enterprise_lib()` only proves a file has the right function *names*.
A tampered file with the same names sails through it untouched. So the
daemon also requires a valid detached Ed25519 signature (a sibling
`<path>.sig` file, 64 raw bytes) against a fixed FractalSQLabs public key,
verified via OpenSSL's EVP API before the library is loaded. This is on by
default: a library with no `.sig` is refused, and the log says so:
`no signature found for enterprise library "<path>" (expected "<path>.sig");
place the .sig beside the library, or set FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0
to load an unsigned library`. Set `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0`
in the daemon's environment (or `enterprise_require_signature = 0` in
`fractalsqld.conf`) to load an unsigned library anyway. An **invalid** signature (present but wrong) is always refused,
whatever the settings: unambiguous tamper evidence, unlike a merely absent
file. A library that cannot be **read** for verification at all (an
unreadable `.so`, an unreadable `.sig`, a permissions problem, a race with
the operator re-signing) is refused on the same terms as a missing signature
while the signature is required: the operator asked for a signed library,
and a file nobody could read is not one. With the requirement off, that
library is still loaded — the load may well succeed where the read failed —
and the log says it was loaded unsigned. New enterprise releases only need a fresh
signature from the same long-lived key; this extension never needs
rebuilding, preserving the drop-in-`.so` design a hash pin would have broken.

### Data at rest

What this tier writes to disk, and how each file is protected.

| What | Where | Protection |
| --- | --- | --- |
| The hash-chained ledger | the file `enterprise_ledger_path` names — default `fractalsql_ledger.dat`, relative to the daemon's working directory | mode `0600`, tightened again on every open |
| The CSV mirror | `<ledger>.csv`, beside the chain file | mode `0600`; the CONNECT table over it is `READONLY=1`, so a stray SQL client cannot rewrite a row through it |
| The chain head | `<ledger>.head`, beside the chain file | mode `0600`; each record carries an HMAC-SHA256 MAC |
| The ledger key | `enterprise_ledger_key` in `fractalsqld.conf` (or `FRACTALSQL_ENTERPRISE_LEDGER_KEY`) | a secret; the conf file's own permissions are checked at startup and at every reload |

A file left behind by an older build keeps no wider permissions than a
freshly created one: every open tightens the mode again rather than
trusting what is on disk. Treat the ledger the way you treat the data it
holds, and use encryption at rest on the volume when the data warrants it.

**The head file is what makes a truncation visible.** A hash chain cannot
show that its newest records were cut off the end — nothing follows the
last record to disagree with it — so the number of records each chain was
ever appended is recorded *outside* the chain, in `<ledger>.head`. A
truncation cannot pull that counter down and hide itself.

Each head record is written as `kind=<n> rows=<n>` with an HMAC-SHA256
MAC over exactly that content, keyed with the enterprise ledger key, so a
counter that has been edited by hand is detected rather than trusted. The
head file is replaced atomically (a temporary file, then a rename), so a
reader never sees a half-written record.

`fractal_ledger_verify` names the failure rather than collapsing it into
one "bad chain" answer:

| What it found | What it says |
| --- | --- |
| The head record has no MAC | it was written before the ledger key was set |
| The head record's MAC does not match its contents | the head was edited by hand |
| The head file will not parse | it is corrupt, or was edited by hand |
| The chain holds fewer rows than the head recorded | rows were removed, or the ledger was replaced |

**The head can be published to a store the database administrator cannot
rewrite.** With `FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog` where the
platform has one) the daemon emits one JSON line on every successful
append:

```json
{"event":"ledger_head","kind":2,"rows":17,"hash":"<hex of the newest entry hash>"}
```

`kind` is the chain, `rows` is how many records that chain has ever held,
and `hash` is the newest entry hash. A chain whose tail was deleted no
longer matches the last line published, so a truncation is visible from
the log even though it is invisible from the file alone. Nothing is
published while the anchor log is off. This is the built-in counterpart
to `scripts/enterprise/anchor-ledger.sh` described above: the script
takes the tip on demand, and this setting publishes it on every append.

**The free text of an audit entry can be redacted.** The question an agent
was asked, the SQL it generated, the analysis it wrote and the rows it
read can all carry customer data. `FSQL_AUDIT_REDACT` decides what the
chain keeps:

| `FSQL_AUDIT_REDACT` | What is stored |
| --- | --- |
| `none` (default) | The text, as it is. |
| `hash` | `sha256:<hex> len=<bytes>` — the fingerprint of the text and its length, so equal texts stay comparable and the length is known, but the text is not. |
| `truncate` | The first 64 characters of the text. |

Redaction reaches the fields nested inside the entry as well as the entry
itself, and leaves everything else alone: identifiers, counts, statuses
and the attribution block are stored as they are. The values returned to
the caller are never redacted — the agent still answers with the real
question, the real SQL and the real analysis; only what is persisted
changes.

**The chain is capped, not rotated.** The ledger is append-only, so it is
bounded by size rather than turned over: `FRACTALSQL_LEDGER_MAX_BYTES`
(default 1 GiB; `0` for unbounded) is the size past which appends are
refused. The operator archives the file and starts a new chain.

**A native plugin has to be verified before it is loaded.** The reasoning
plugin is loaded only if its detached `.sig` (`<plugin>.sig`, beside the
plugin) is a valid Ed25519 signature by the FractalSQLabs reasoning-plugin
signing key built into the daemon. A plugin without one is refused, and so is
a plugin whose signature does not verify. The plugin and its `.sig` ship
together in the release packages. The check is on by default;
`FSQL_REASONING_REQUIRE_SIGNATURE=0` turns it off so that a plugin with no
`.sig` loads (a `.sig` that is present but wrong is still refused). Turn it
off only when you have another way to establish what you are loading, such as
a plugin you built yourself.

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.