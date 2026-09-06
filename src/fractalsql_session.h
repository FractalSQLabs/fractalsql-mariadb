/* src/fractalsql_session.h
 * Connection-scoped fsql_ctx registry for fractalsql-mariadb.
 *
 * WHY THIS EXISTS: MariaDB is one shared multithreaded mysqld process
 * serving every connection, so a plain file-static in fractalsql.so
 * would silently leak state (Diversify tuning, rolling D_q/overhead
 * stats, ...) across unrelated sessions, with one connection's
 * settings applying to another's query results. This registry gives
 * that kind of state a safe, connection-scoped home.
 *
 * KEYING: MariaDB UDFs have no ambient access to a connection/THD
 * handle through the public UDF ABI (UDF_INIT/UDF_ARGS). There is no
 * portable way for a bare UDF to ask "what connection am I on" without
 * linking against server-internal headers, which this repo deliberately
 * does not do (see build.sh / Makefile, built purely against
 * libmariadb-dev's public mysql.h). So callers pass their own session
 * key explicitly as a BIGINT UDF argument; the documented convention
 * (sql/install_udf.sql) is to pass CONNECTION_ID().
 *
 * LIFETIME / KNOWN LIMITATION: MariaDB UDFs also have no on-disconnect
 * hook, so entries can't be reaped exactly when a session ends. This
 * registry bounds the damage with a hard capacity cap plus
 * least-recently-used eviction of unreferenced entries, and an
 * idle-TTL sweep (see fractalsql_session.c). Residual risk: MariaDB can
 * reuse CONNECTION_ID() values over the server's lifetime under
 * sustained connection churn; a brand-new connection that happens to be
 * assigned a not-yet-evicted stale CONNECTION_ID() would inherit that
 * old session's Diversify state until it next calls
 * fractal_diversify_enable/set_params itself. The idle TTL bounds the
 * exposure window, but does not eliminate it. This is a documented
 * tradeoff, not an oversight.
 *
 * THREAD SAFETY: every function here is safe to call concurrently from
 * different threads on different session_ids. A single session_id is
 * only ever touched by one thread at a time in practice (MariaDB
 * serializes statement execution per connection), but the registry does
 * not assume that: entries are refcounted, so a concurrent eviction
 * sweep can never free a ctx a caller is actively holding, even under a
 * misused/shared session_id.
 */
#ifndef FRACTALSQL_SESSION_H
#define FRACTALSQL_SESSION_H

#include <stdbool.h>

#include "fractalsql_sql.h"   /* fsql_ctx */

#ifdef __cplusplus
extern "C" {
#endif

/* Look up session_id's persistent ctx, creating one (via
 * fsql_new_sovereign(NULL, NULL), not fsql_new_minimal, since Diversify
 * calls like fsql_diversify_enable assert ctx->is_sovereign and fail
 * on a minimal-tier ctx) if it doesn't exist yet.
 * Increments the entry's refcount and marks it most-recently-used;
 * caller MUST call fractal_session_release(session_id) exactly once
 * when done, including on every error path, even though the fsql_ctx
 * itself is NOT freed by release (only eviction/close frees it).
 * Returns NULL on OOM, or if the registry is at capacity with every
 * existing entry currently pinned (refcount > 0). That cap is an
 * administrative limit, not expected to be hit in normal operation. */
fsql_ctx *fractal_session_acquire(unsigned long long session_id);

/* Same acquire/create/refcount/LRU contract as fractal_session_acquire,
 * but for a SEPARATE ctx slot on the same session_id's entry, reserved
 * for fractal_reason() / fractal_embed() respectively (not shared with
 * the Diversify/search ctx fractal_session_acquire returns, and not
 * shared with EACH OTHER; see fractalsql_session.c's entry struct
 * comment for why). *out_loaded (may be NULL) is set to whether a
 * reasoning plugin has already been attached to this ctx, so the
 * caller can skip re-loading it on every call; use
 * fractal_session_mark_reason_loaded / _embed_loaded to flip it true
 * after a successful load. Caller MUST call fractal_session_release
 * exactly once when done, same as fractal_session_acquire: it is the
 * SAME release function, since the refcount is per-entry, not per-slot. */
fsql_ctx *fractal_session_acquire_reason(unsigned long long session_id, bool *out_loaded);
fsql_ctx *fractal_session_acquire_embed(unsigned long long session_id, bool *out_loaded);

/* Same contract again, for fractal_t2s_generate()'s GENERATE-step ctx.
 * A fourth, separate slot, not shared with reason_ctx or embed_ctx,
 * because it loads with RESPONSE_MODE=code and a text-to-sql-specific
 * SYSTEM_TAG (see src/fractalsql_textsql.c), which would otherwise
 * stomp reason_ctx's plain-chat config or vice versa, the same
 * reasoning as reason_ctx vs embed_ctx above. */
fsql_ctx *fractal_session_acquire_t2s(unsigned long long session_id, bool *out_loaded);

/* Mark session_id's reason/embed/t2s ctx as having a reasoning plugin
 * successfully attached (see fractal_session_acquire_reason/_embed/
 * _t2s's *out_loaded). No-op if session_id has no live entry. */
void fractal_session_mark_reason_loaded(unsigned long long session_id);
void fractal_session_mark_embed_loaded(unsigned long long session_id);
void fractal_session_mark_t2s_loaded(unsigned long long session_id);

/* Release a reference obtained from fractal_session_acquire. Safe to
 * call on an id with no live entry (no-op, defensive only, should not
 * happen given correct acquire/release pairing). */
void fractal_session_release(unsigned long long session_id);

/* Explicitly drop session_id's entry, freeing its ctx immediately if
 * nothing currently holds a reference to it (refcount == 0). If the
 * entry is currently pinned, this is a deliberate no-op: the still-
 * holding caller's release() plus the next idle-TTL sweep reclaim it
 * instead; this function never frees memory a live pointer references.
 * Safe to call on an id with no entry (no-op).
 *
 * Named _registry_close (not _close) to avoid colliding with the SQL
 * UDF entry point fractal_session_close() in src/fractalsql.c, which
 * MariaDB's dynamic loader requires to be named EXACTLY the SQL
 * function name; that UDF is a thin wrapper calling this. */
void fractal_session_registry_close(unsigned long long session_id);

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_SESSION_H */
