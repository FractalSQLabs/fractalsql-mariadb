/* src/fractalsql_session.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Connection-scoped fsql_ctx registry (Diversify/search) plus the
 * per-tier LLM context singletons. See fractalsql_session.h for the
 * design rationale.
 *
 * Implementation: a fixed bucket-array hash table (chaining) keyed by
 * session_id, threaded through a single global LRU doubly-linked list
 * for O(1)-ish eviction, guarded by one process-wide lock. Not designed
 * for a hot per-row path: Diversify is opt-in and administrative,
 * matching the vendored core's own framing of it (fractalsql_sql.h:
 * "Disabled by default in v2.0 (opt-in). When disabled, ctx behaves
 * bit-for-bit identical to v1.0").
 */

#include "fractalsql_session.h"
#include "fractalsql_enterprise.h"
#include "fractalsql_msvc_compat.h"  /* setenv/unsetenv on MSVC */

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#  include <Windows.h>
#else
#  include <pthread.h>
#endif

#define FSQL_SESSION_BUCKETS           1024u
#define FSQL_SESSION_MAX_ENTRIES       4096u
#define FSQL_SESSION_IDLE_TTL_SECONDS  (6 * 3600) /* 6h, see header's residual-risk note */
#define FSQL_SESSION_SWEEP_SCAN_LIMIT  8           /* bounded per-call sweep cost */

typedef struct fsql_session_entry {
    unsigned long long          session_id;
    fsql_ctx                   *ctx;
    /* Legacy per-session LLM-tier slot fields. The reason/embed/t2s/
     * review dispatchers no longer populate these: each of the four LLM
     * tiers keeps one process-wide ctx singleton instead
     * (g_tier_ctx[]/g_tier_loaded below), so one tier's
     * fsql_load_reasoning() -- which REPLACES whatever reasoning VFS is
     * already attached to a ctx -- can never stomp another tier's HTTP
     * config. The fields stay for the destroy path only (entry_destroy
     * frees any non-NULL slot); they are NULL in practice. */
    fsql_ctx                   *reason_ctx;
    bool                         reason_loaded;
    fsql_ctx                   *embed_ctx;
    bool                         embed_loaded;
    fsql_ctx                   *t2s_ctx;
    bool                         t2s_loaded;
    fsql_ctx                   *review_ctx;
    bool                         review_loaded;
    int                          refcount;
    /* Exclusive-use pin for the main `ctx` slot (see
     * fractal_session_acquire_exclusive). The core's fsql_search_ptr is
     * not safe for concurrent searches on the SAME ctx, so an entry
     * running a search under a shared/misused session_id is marked busy;
     * a second exclusive acquire of that id then fails fast instead of
     * racing the core. Checked alongside refcount by every destroy path. */
    int                          busy;
    time_t                       last_used;
    struct fsql_session_entry  *bucket_next;
    struct fsql_session_entry  *lru_prev;  /* toward most-recently-used */
    struct fsql_session_entry  *lru_next;  /* toward least-recently-used */
} fsql_session_entry;

static fsql_session_entry *g_buckets[FSQL_SESSION_BUCKETS];
static fsql_session_entry *g_lru_head = NULL; /* most recently used */
static fsql_session_entry *g_lru_tail = NULL; /* least recently used */
static unsigned int        g_entry_count = 0;

/* ------------------------------------------------------------------ */
/* Portable lock. Plain UDFs can't assume mysys/pthread wrappers       */
/* (this repo builds only against libmariadb-dev's public mysql.h),    */
/* so this shims the two platforms directly.                          */
/* ------------------------------------------------------------------ */
#if defined(_WIN32)
static INIT_ONCE       g_lock_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_lock;

static BOOL CALLBACK
init_lock_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
    InitializeCriticalSection(&g_lock);
    return TRUE;
}

static void session_lock(void)
{
    InitOnceExecuteOnce(&g_lock_once, init_lock_once, NULL, NULL);
    EnterCriticalSection(&g_lock);
}
static void session_unlock(void) { LeaveCriticalSection(&g_lock); }
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void session_lock(void)   { pthread_mutex_lock(&g_lock); }
static void session_unlock(void) { pthread_mutex_unlock(&g_lock); }
#endif

/* ------------------------------------------------------------------ */
/* Internal helpers. Caller must hold the lock for all of these.       */
/* ------------------------------------------------------------------ */

static fsql_session_entry *
find_entry(unsigned long long id)
{
    fsql_session_entry *e = g_buckets[id % FSQL_SESSION_BUCKETS];
    while (e) {
        if (e->session_id == id) return e;
        e = e->bucket_next;
    }
    return NULL;
}

static void
bucket_unlink(fsql_session_entry *e)
{
    fsql_session_entry **slot = &g_buckets[e->session_id % FSQL_SESSION_BUCKETS];
    while (*slot) {
        if (*slot == e) { *slot = e->bucket_next; return; }
        slot = &(*slot)->bucket_next;
    }
}

static void
lru_unlink(fsql_session_entry *e)
{
    if (e->lru_prev) {
        e->lru_prev->lru_next = e->lru_next;
    } else {
        g_lru_head = e->lru_next;
    }
    if (e->lru_next) {
        e->lru_next->lru_prev = e->lru_prev;
    } else {
        g_lru_tail = e->lru_prev;
    }
    e->lru_prev = e->lru_next = NULL;
}

static void
lru_push_front(fsql_session_entry *e)
{
    e->lru_prev = NULL;
    e->lru_next = g_lru_head;
    if (g_lru_head) g_lru_head->lru_prev = e;
    g_lru_head = e;
    if (!g_lru_tail) g_lru_tail = e;
}

/* Frees an entry outright. Caller must already have unlinked it from
 * both the bucket chain and the LRU list, and confirmed refcount == 0. */
static void
entry_destroy(fsql_session_entry *e)
{
    if (e->ctx)        fsql_free(e->ctx);
    if (e->reason_ctx) fsql_free(e->reason_ctx);
    if (e->embed_ctx)  fsql_free(e->embed_ctx);
    if (e->t2s_ctx)    fsql_free(e->t2s_ctx);
    if (e->review_ctx) fsql_free(e->review_ctx);
    free(e);
    g_entry_count--;
}

/* Evict up to `limit` idle-TTL-expired, unreferenced entries from the
 * LRU tail (oldest first). Bounded so every acquire() call pays a
 * fixed, small sweep cost rather than an occasional full-table scan. */
static void
sweep_stale(int limit)
{
    time_t now = time(NULL);
    fsql_session_entry *e = g_lru_tail;
    int scanned = 0;
    while (e && scanned < limit) {
        fsql_session_entry *prev = e->lru_prev;
        if (e->refcount == 0 && e->busy == 0 &&
            (now - e->last_used) >= FSQL_SESSION_IDLE_TTL_SECONDS) {
            bucket_unlink(e);
            lru_unlink(e);
            entry_destroy(e);
        }
        e = prev;
        scanned++;
    }
}

/* Evict the single least-recently-used unreferenced entry to make room
 * for a new one. Returns true if an entry was evicted. */
static bool
evict_one_lru(void)
{
    fsql_session_entry *e = g_lru_tail;
    while (e) {
        fsql_session_entry *prev = e->lru_prev;
        if (e->refcount == 0 && e->busy == 0) {
            bucket_unlink(e);
            lru_unlink(e);
            entry_destroy(e);
            return true;
        }
        e = prev;
    }
    return false;
}

/* Find session_id's entry, bumping refcount/LRU/last_used as a live
 * acquire would, creating a fresh (all-ctx-slots-NULL) entry if none
 * exists yet. Returns NULL on OOM or an at-capacity, fully-pinned
 * table. Caller must hold the lock. Shared by fractal_session_acquire
 * and the reason/embed/t2s acquire variants below; each then lazily
 * populates its OWN ctx slot within the returned entry. */
static fsql_session_entry *
find_or_create_entry_locked(unsigned long long session_id)
{
    fsql_session_entry *e = find_entry(session_id);
    if (e) {
        e->refcount++;
        e->last_used = time(NULL);
        lru_unlink(e);
        lru_push_front(e);
        return e;
    }

    if (g_entry_count >= FSQL_SESSION_MAX_ENTRIES && !evict_one_lru()) {
        /* Every existing entry is pinned (in active use) and the table
         * is at its cap, so refuse rather than exceed it. Would require
         * FSQL_SESSION_MAX_ENTRIES concurrent sessions ALL mid-call at
         * the same instant; not a realistic steady state. Callers fall
         * back to a fresh, unregistered per-call ctx rather than
         * failing the whole query over this administrative cap. */
        return NULL;
    }

    e = (fsql_session_entry *) calloc(1, sizeof(*e));
    if (e == NULL) return NULL;
    e->session_id = session_id;
    e->refcount   = 1;
    e->last_used  = time(NULL);

    unsigned long long b = session_id % FSQL_SESSION_BUCKETS;
    e->bucket_next = g_buckets[b];
    g_buckets[b] = e;
    lru_push_front(e);
    g_entry_count++;

    return e;
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

fsql_ctx *
fractal_session_acquire(unsigned long long session_id)
{
    session_lock();
    sweep_stale(FSQL_SESSION_SWEEP_SCAN_LIMIT);

    /* An exclusive holder (fractal_search's in-flight call on this same
     * session_id) owns e->ctx's diversify state for the duration; a
     * tuning/read call here would race it. Refuse up front, same as
     * fractal_session_acquire_exclusive does against a second exclusive
     * acquire, rather than mutating ctx state out from under the search. */
    fsql_session_entry *busy_check = find_entry(session_id);
    if (busy_check != NULL && busy_check->busy) {
        session_unlock();
        return NULL;
    }

    fsql_session_entry *e = find_or_create_entry_locked(session_id);
    if (e == NULL) { session_unlock(); return NULL; }

    /* Sovereign, not fsql_new_minimal: fsql_diversify_* all assert
     * ctx->is_sovereign (FSQL_REQUIRE_SOVEREIGN in the vendored
     * core) and fail FSQL_ERR_INVALID on a minimal-tier ctx. The first
     * argument wires in the QTL ledger's file-backed storage VFS (see
     * fractalsql_enterprise.c) -- always populated, but its callbacks
     * only ever run when fractal_ledger_flush/_load are invoked with the
     * enterprise library loaded, so this costs nothing on a Community
     * deployment or for search/diversify's own use of this same ctx. No
     * reasoning VFS (second argument stays NULL): this registry only
     * needs search-capable ctx state, the same posture as
     * fractal_search's own per-call ctx. */
    if (e->ctx == NULL) {
        e->ctx = fsql_new_sovereign(fractal_ledger_storage_vfs(), NULL);
        if (e->ctx == NULL) {
            /* Entry was already linked in (possibly pre-existing), so
             * back out the refcount bump find_or_create_entry_locked
             * did rather than leaving a phantom pin on OOM. */
            if (e->refcount > 0) e->refcount--;
            session_unlock();
            return NULL;
        }
    }

    fsql_ctx *ctx = e->ctx;
    session_unlock();
    return ctx;
}


/* The four LLM tiers each keep one process-wide plugin context, created
 * and loaded lazily on first use and shared across every connection.
 * Per-session contexts meant each session created its own plugin
 * instance in the shared plugin library, and a new instance disturbed
 * the state an earlier one had set up (an embedding call followed by a
 * generate call in the same process failed). The tier is chosen by the
 * caller, not by the session. */
enum fsql_tier { FSQL_TIER_REASON = 0, FSQL_TIER_EMBED, FSQL_TIER_T2S, FSQL_TIER_REVIEW, FSQL_TIER_COUNT };
static fsql_ctx *g_tier_ctx[FSQL_TIER_COUNT];
static bool      g_tier_loaded[FSQL_TIER_COUNT];

static fsql_ctx *
tier_acquire(enum fsql_tier t, bool *out_loaded)
{
    fsql_ctx *ctx;
    session_lock();
    if (g_tier_ctx[t] == NULL) {
        g_tier_ctx[t] = fsql_new_sovereign(NULL, NULL);
        if (g_tier_ctx[t] == NULL) { session_unlock(); return NULL; }
    }
    ctx = g_tier_ctx[t];
    if (out_loaded) *out_loaded = g_tier_loaded[t];
    session_unlock();
    return ctx;
}

static void
tier_mark_loaded(enum fsql_tier t)
{
    session_lock();
    g_tier_loaded[t] = true;
    session_unlock();
}

/* Provider-reload hook (fractalsql_provider.h): forget that tier t's
 * plugin is loaded, so the tier's next dispatch re-runs its
 * setenv+fsql_load_reasoning sequence against the just-applied settings.
 * The tier ctx itself is kept (fsql_new_sovereign is reusable); only the
 * loaded flag is cleared. */
static void
tier_forget_loaded(enum fsql_tier t)
{
    session_lock();
    g_tier_loaded[t] = false;
    session_unlock();
}

/* Acquire the reason tier's shared ctx singleton, creating the ctx
 * itself on first use (session_id is kept in the signature for call
 * stability and is ignored). *out_loaded is set (under the lock, so
 * it's a consistent snapshot with the returned ctx) to whether a
 * reasoning plugin has already been loaded into it. The caller
 * (fractalsql_cognition.c) uses this to skip re-running the
 * setenv+fsql_load_reasoning dance on every query; a provider reload
 * clears the tier's flag via fractal_session_forget_reason_loaded so
 * the next call re-loads against the new settings. Sovereign tier for
 * the same reason fractal_session_acquire uses it: fsql_load_reasoning
 * has no tier restriction, but using ONE ctx constructor throughout
 * this registry keeps the file's OOM/free paths uniform. */
fsql_ctx *
fractal_session_acquire_reason(unsigned long long session_id, bool *out_loaded)
{
    (void) session_id;
    return tier_acquire(FSQL_TIER_REASON, out_loaded);
}

/* Exclusive-use acquire of session_id's Diversify/search ctx, for
 * fractal_search()/fractal_search_explore() (see fractalsql.c). Same
 * acquire/create/refcount/LRU contract as fractal_session_acquire, plus:
 *   1. The entry is marked busy for the duration of the call, and
 *      release_exclusive clears it. Busy entries are never destroyed by
 *      sweep/eviction/registry_close, exactly like refcounted ones.
 *   2. If the entry ALREADY has an outstanding exclusive acquire (another
 *      connection running a search on the same, shared session_id), this
 *      refuses up front: *out_busy is set to true and NULL returned,
 *      rather than two threads running concurrent fsql_search_ptr calls
 *      on the same non-thread-safe core ctx. Callers turn that into a
 *      clean per-row error; it is not silently downgraded to the
 *      stateless fallback, since that would silently drop the session's
 *      Diversify state and return different semantics than documented.
 * Release with fractal_session_release_exclusive exactly once, which
 * clears the busy flag and drops the refcount in one step. */
fsql_ctx *
fractal_session_acquire_exclusive(unsigned long long session_id, bool *out_busy)
{
    if (out_busy) *out_busy = false;

    session_lock();
    sweep_stale(FSQL_SESSION_SWEEP_SCAN_LIMIT);

    fsql_session_entry *e = find_entry(session_id);
    if (e != NULL && e->busy) {
        if (out_busy) *out_busy = true;
        session_unlock();
        return NULL;
    }

    e = find_or_create_entry_locked(session_id);
    if (e == NULL) { session_unlock(); return NULL; }
    e->busy = 1;

    /* Sovereign tier and ledger VFS for the same reason as
     * fractal_session_acquire above. */
    if (e->ctx == NULL) {
        e->ctx = fsql_new_sovereign(fractal_ledger_storage_vfs(), NULL);
        if (e->ctx == NULL) {
            if (e->refcount > 0) e->refcount--;
            e->busy = 0;
            session_unlock();
            return NULL;
        }
    }

    fsql_ctx *ctx = e->ctx;
    session_unlock();
    return ctx;
}

/* Release an exclusive acquire: clears the busy pin and drops the
 * refcount under one lock hold. Safe to call on an id with no live
 * entry (no-op, defensive only). */
void
fractal_session_release_exclusive(unsigned long long session_id)
{
    session_lock();
    fsql_session_entry *e = find_entry(session_id);
    if (e) {
        e->busy = 0;
        if (e->refcount > 0) e->refcount--;
    }
    session_unlock();
}

/* Same as fractal_session_acquire_reason but for fractal_embed()'s
 * ctx: the embed tier's own singleton. See fractalsql_session.h's
 * declaration comment for why the tiers don't share one ctx. */
fsql_ctx *
fractal_session_acquire_embed(unsigned long long session_id, bool *out_loaded)
{
    (void) session_id;
    return tier_acquire(FSQL_TIER_EMBED, out_loaded);
}

/* Same as fractal_session_acquire_reason but for
 * fractal_t2s_generate()'s ctx (the t2s tier's own singleton). */
fsql_ctx *
fractal_session_acquire_t2s(unsigned long long session_id, bool *out_loaded)
{
    (void) session_id;
    return tier_acquire(FSQL_TIER_T2S, out_loaded);
}

/* Same as fractal_session_acquire_reason but for fractal_t2s_review()'s
 * ctx (the review tier's own singleton). See fractalsql_session.h's
 * declaration comment for why the tiers don't share one ctx. */
fsql_ctx *
fractal_session_acquire_review(unsigned long long session_id, bool *out_loaded)
{
    (void) session_id;
    return tier_acquire(FSQL_TIER_REVIEW, out_loaded);
}

/* Mark a tier's shared ctx as having a reasoning plugin successfully
 * attached. Called by the dispatchers right after a successful
 * fsql_load_reasoning, under ITS OWN load-serialization mutex (see
 * fractalsql_cognition.c / fractalsql_textsql.c), but each of these
 * still takes the registry lock itself since the flag lives in
 * g_tier_loaded[]. session_id is ignored (tier-wide, not per-session):
 * the flags are also cleared tier-wide by fractal_session_forget_*_
 * loaded() on a provider reload. This is best-effort bookkeeping only:
 * worst case, the next caller redundantly reloads the plugin, which is
 * not a correctness issue. */
void
fractal_session_mark_reason_loaded(unsigned long long session_id)
{
    (void) session_id;
    tier_mark_loaded(FSQL_TIER_REASON);
}

void
fractal_session_mark_embed_loaded(unsigned long long session_id)
{
    (void) session_id;
    tier_mark_loaded(FSQL_TIER_EMBED);
}

void
fractal_session_mark_t2s_loaded(unsigned long long session_id)
{
    (void) session_id;
    tier_mark_loaded(FSQL_TIER_T2S);
}

void
fractal_session_mark_review_loaded(unsigned long long session_id)
{
    (void) session_id;
    tier_mark_loaded(FSQL_TIER_REVIEW);
}

/* Provider-reload hooks (fractalsql_provider.h): the daemon's
 * apply_provider entry points clear the affected tiers' loaded flags so
 * the next dispatch in each tier re-loads its plugin from the new
 * settings. The tier ctx is intentionally kept -- fsql_new_sovereign
 * contexts are reusable, and the flags are the only load-once state. */

void
fractal_session_forget_reason_loaded(void)
{
    tier_forget_loaded(FSQL_TIER_REASON);
}

void
fractal_session_forget_embed_loaded(void)
{
    tier_forget_loaded(FSQL_TIER_EMBED);
}

void
fractal_session_forget_t2s_loaded(void)
{
    tier_forget_loaded(FSQL_TIER_T2S);
}

void
fractal_session_forget_review_loaded(void)
{
    tier_forget_loaded(FSQL_TIER_REVIEW);
}

void
fractal_session_release(unsigned long long session_id)
{
    session_lock();
    fsql_session_entry *e = find_entry(session_id);
    if (e && e->refcount > 0) e->refcount--;
    session_unlock();
}

void
fractal_session_registry_close(unsigned long long session_id)
{
    session_lock();
    fsql_session_entry *e = find_entry(session_id);
    if (e && e->refcount == 0 && e->busy == 0) {
        bucket_unlink(e);
        lru_unlink(e);
        entry_destroy(e);
    }
    session_unlock();
}
