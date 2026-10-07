/* src/fractalsql_cognition.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fractal_reason / fractal_embed: the Cognition tier.
 *
 * CONFIGURATION
 *
 *   MariaDB has no deployment-wide, reloadable admin config channel a
 *   plugin can register into the way a GUC works. A real
 *   mysql_declare_plugin descriptor exposing fractalsql_reasoning_
 *   plugin/http_url/... as GLOBAL system variables (my.cnf plus INSTALL
 *   SONAME) was considered and rejected: MariaDB's plugin loader
 *   (sql/sql_plugin.cc) requires most plugin types
 *   (MYSQL_DAEMON_PLUGIN, MYSQL_INFORMATION_SCHEMA_PLUGIN,
 *   MYSQL_HANDLERTON_PLUGIN) to declare an interface version that must
 *   exactly match the running server's own compiled MYSQL_VERSION_ID,
 *   down to the patch level, before INSTALL SONAME will accept the
 *   library. A single prebuilt fractalsql.so could never be installed
 *   this way across this repo's 10.6 to 12.3 compatibility matrix, or
 *   even across patch releases of one major, the way every CREATE
 *   FUNCTION ... SONAME UDF in this library already is: it would need a
 *   rebuild per exact target MariaDB version, breaking the
 *   one-.so-per-(arch, libc) distribution model the rest of this
 *   extension relies on. (MYSQL_AUDIT_PLUGIN has a small,
 *   version-independent interface constant, but repurposing an audit
 *   plugin just to smuggle in system variables is a real semantic
 *   mismatch: SHOW PLUGINS would list fractalsql as an audit plugin it
 *   isn't.)
 *
 *   So there is no plugin descriptor. Every setting lives with the
 *   fractalsqld daemon: its config file (fractalsqld.conf) is the
 *   preferred source per key, and `fsqlctl reload` (FSQ_OP_RELOAD)
 *   pushes the values in live through fractalsql_cognition_apply_
 *   provider (see fractalsql_provider.h) -- a reasoning token,
 *   endpoint, model or plugin path can be changed without restarting
 *   the daemon; the tier's next call picks up the new settings, so no
 *   reload ever attempts a plugin load itself. Each key also keeps a
 *   boot-time environment fallback, read once from the daemon's own
 *   process environment (a key removed from the config file reverts to
 *   that fallback):
 *     FRACTALSQL_REASONING_PLUGIN   absolute path to a fsql_reasoning_
 *                                   init-exporting .so (required)
 *     FSQL_REASONING_HTTP_URL (legacy fallback FRACTALSQL_HTTP_URL)
 *                                   chat-completions endpoint, for
 *                                   fractal_reason()
 *     FSQL_REASONING_HTTP_TOKEN (FRACTALSQL_HTTP_TOKEN)
 *                                   bearer/api-key token
 *     FSQL_REASONING_HTTP_MODEL (FRACTALSQL_HTTP_MODEL)
 *                                   chat model name
 *     FSQL_REASONING_HTTP_EMBED_URL embeddings endpoint, for
 *                                   fractal_embed() (no fallback to
 *                                   HTTP_URL: it is a different
 *                                   endpoint shape)
 *     FSQL_REASONING_HTTP_EMBED_MODEL
 *                                   embedding model name
 *     FSQL_REASONING_HTTP_ALLOW_PLAINTEXT  "1" to allow a non-TLS URL
 *   The environment fallback is set in the daemon's environment
 *   (systemd Environment=, Docker `environment:`) before start; it
 *   exists for installs that never put the keys in the config file.
 *
 * TIER DISPATCH CONTEXT
 *
 *   fsql_ctx is single-thread-affine by convention (the vendored
 *   core's binding-author rule): a single ctx shared across the
 *   daemon's concurrently executing forwarded calls would be unsafe, the same
 *   hazard the session registry already guards against for Diversify's
 *   ctx. So fractal_reason/fractal_embed take an explicit session_id
 *   BIGINT first argument (CONNECTION_ID() by convention, matching every
 *   other session_id-scoped function in this repo) and dispatch through
 *   two per-tier ctx singletons in fractalsql_session.c (g_tier_ctx[]
 *   under FSQL_TIER_REASON and FSQL_TIER_EMBED, shared across every
 *   connection; the session_id is accepted for call stability and
 *   ignored), kept distinct from each other and from the
 *   Diversify/search ctx because fsql_load_reasoning() replaces whatever
 *   reasoning VFS is already attached, and reason/embed load with
 *   different HTTP config. A per-tier *_loaded flag skips the plugin
 *   re-load on every call, and a provider reload clears exactly the
 *   affected tiers' flags (fractal_session_forget_*_loaded) so the next
 *   call re-loads against the new settings.
 *
 * THE setenv() RACE
 *
 *   The reasoning-http plugin (fractalsql-reasoning-http.so) reads its own
 *   config purely from FSQL_REASONING_HTTP_* process environment variables
 *   at fsql_load_reasoning() time; there is no non-env config channel in
 *   its ABI. Bridging this repo's FRACTALSQL_* config into those
 *   FSQL_REASONING_HTTP_* names is therefore a setenv() call immediately
 *   followed by fsql_load_reasoning(), and setenv() mutates process-wide
 *   state. The daemon runs one shared multithreaded process for every
 *   connection's forwarded calls, so a fractal_embed call on one thread and a
 *   fractal_reason call on another could interleave their setenv() calls
 *   and load ctx A with ctx B's URL. g_load_lock below serializes the
 *   whole "setenv the bridge vars, then fsql_load_reasoning" step
 *   process-wide. It is held only for that narrow window, once per tier
 *   (the *_loaded tier flag skips it on every
 *   subsequent call), so contention is low.
 *
 * fractal_embed OUTPUT FORMAT
 *
 *   Returns the same fractal_vector JSON-array-string grammar the vector
 *   functions in fractalsql_vector.c use (narrowed to float32, "%.9g"),
 *   not a raw, un-narrowed echo of the provider's response. That means a
 *   fractal_embed() result flows straight into
 *   fractal_vector_cosine_distance() or VEC_FROMTEXT() with no conversion
 *   step. This trades a little precision fidelity (providers typically
 *   report embeddings as float64-shaped JSON decimals) for consistency
 *   with fractal_vector's one established representation.
 */

#include <mysql.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <Windows.h>
#else
#  include <pthread.h>
#endif

#include "fractalsql.h"              /* FSQL_OK, fsql_last_error */
#include "fractalsql_sql.h"          /* fsql_ctx, fsql_dispatch_ai, fsql_load_reasoning */
#include "fractalsql_session.h"      /* fractal_session_acquire_reason/_embed, ... */
#include "fractalsql_parse.h"        /* parse_vector_csv (shared with fractalsql.c) */
#include "fractalsql_provider.h"     /* fractalsql_cognition_{check,apply}_provider */

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

#include "fractalsql_msvc_compat.h"  /* setenv/unsetenv on MSVC */

/* SFS_INIT_ERROR(msg, ...) formats `msg` for the UDF ABI's
 * init-function `message` param -- the only channel the server reads.
 * On a UDF *runtime* path there is no such channel: the main function
 * can only set *error and return NULL, so a buffer formatted here on a
 * runtime failure is a stack local the server never sees, and the
 * failure used to surface as a bare NULL with its cause dropped
 * entirely (exactly how a macOS-only dlopen failure of the reasoning
 * plugin once went undiagnosable in CI: nothing in the client output,
 * nothing in any log). Mirror every message to stderr as a second
 * channel -- the daemon's stderr is the console for a foreground start
 * and its own log file under a service manager. All
 * call sites are one-shot validation/load failures, not per-row hot
 * paths, so this stays log-quiet. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* Same DoS-guard reasoning as fractalsql.c's MAX_QUERY_BYTES: a
 * caller-controlled string driving allocation and an outbound HTTP
 * request body, uncapped would let a multi-GiB argument OOM-kill the
 * server or build an abusive request. */
#define FRACTAL_COGNITION_MAX_INPUT_BYTES ((unsigned long) 4u * 1024u * 1024u) /* 4 MiB */

/* Reject an implausibly large plugin response. */
#define FRACTAL_MAX_AI_RESPONSE_BYTES ((size_t) 16u * 1024u * 1024u) /* 16 MiB */

/* Cap on parsed embedding dimension for fractal_embed() (real embedding
 * models top out around 3072 dims; generous headroom while still
 * bounding the allocation below against a buggy/adversarial plugin
 * response). */
#define FRACTAL_MAX_EMBED_DIM 16384

/* ------------------------------------------------------------------ */
/* Growable output buffer (duplicated pattern; see fractalsql_        */
/* vector.c's own json_out_ctx comment for why this isn't shared).    */
/* ------------------------------------------------------------------ */
typedef struct str_out_ctx {
    char  *buf;
    size_t cap;
} str_out_ctx;

static bool
str_out_ensure(str_out_ctx *so, size_t need)
{
    size_t ncap;
    char  *nb;
    if (need <= so->cap) return true;
    ncap = so->cap ? so->cap : 256;
    while (ncap < need) ncap *= 2;
    nb = realloc(so->buf, ncap);
    if (nb == NULL) return false;
    so->buf = nb; so->cap = ncap;
    return true;
}

static bool
str_out_generic_init(UDF_INIT *initid, char *message)
{
    str_out_ctx *so = calloc(1, sizeof(*so));
    if (so == NULL) {
        SFS_INIT_ERROR(message, "fractal_cognition: out of memory");
        return true;
    }
    initid->ptr        = (char *) so;
    initid->maybe_null = 1;
    initid->max_length = FRACTAL_MAX_AI_RESPONSE_BYTES;
    return false;
}

static void
str_out_generic_deinit(UDF_INIT *initid)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    if (so == NULL) return;
    free(so->buf);
    free(so);
    initid->ptr = NULL;
}

/* Formats a float array as bracket-JSON "[v0,v1,...]", identical
 * grammar and precision to fractalsql_vector.c's format_vector_json
 * (duplicated rather than shared, following that file's own
 * precedent). */
static char *
format_vector_json(str_out_ctx *so, const float *v, size_t dim, unsigned long *out_len)
{
    size_t need = dim * 32 + 8;
    size_t pos;

    if (!str_out_ensure(so, need)) return NULL;

    pos = 0;
    so->buf[pos++] = '[';
    for (size_t i = 0; i < dim; i++) {
        int n;
        if (i > 0) so->buf[pos++] = ',';
        n = snprintf(so->buf + pos, so->cap - pos, "%.9g", (double) v[i]);
        if (n < 0 || (size_t) n >= so->cap - pos) return NULL;
        pos += (size_t) n;
    }
    so->buf[pos++] = ']';
    so->buf[pos]   = '\0';

    *out_len = (unsigned long) pos;
    return so->buf;
}

/* ------------------------------------------------------------------ */
/* Portable lock and once-init helpers. See fractalsql_session.c's    */
/* identical shim comment; duplicated per translation unit by this    */
/* repo's established precedent rather than shared.                   */
/* ------------------------------------------------------------------ */
#if defined(_WIN32)
static CRITICAL_SECTION g_load_lock;
static INIT_ONCE        g_lock_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK
init_load_lock_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
    InitializeCriticalSection(&g_load_lock);
    return TRUE;
}
static void load_lock(void)
{
    InitOnceExecuteOnce(&g_lock_once, init_load_lock_once, NULL, NULL);
    EnterCriticalSection(&g_load_lock);
}
static void load_unlock(void) { LeaveCriticalSection(&g_load_lock); }
#else
static pthread_mutex_t g_load_lock = PTHREAD_MUTEX_INITIALIZER;
static void load_lock(void)   { pthread_mutex_lock(&g_load_lock); }
static void load_unlock(void) { pthread_mutex_unlock(&g_load_lock); }
#endif

/* ------------------------------------------------------------------ */
/* Provider config. Per key, in priority order (fractalsql_provider.h */
/* for the rule): (1) fractalsqld.conf -- the daemon pushes values in */
/* via fractalsql_cognition_apply_provider(), under our load lock;    */
/* (2) the process environment -- the boot fallback, captured once;   */
/* (3) unset/default.                                                 */
/*                                                                    */
/* g_env_fb is the boot-env fallback snapshot: owned strings, captured */
/* once, never freed. g_cfg holds the EFFECTIVE values -- always its  */
/* own owned copies, never aliases of g_env_fb's, so apply's           */
/* free-and-replace can never dangle. Until the first provider apply, */
/* g_cfg is initialized once from the snapshot, byte-identical to the */
/* old env-only behavior.                                             */
/* ------------------------------------------------------------------ */
typedef struct {
    char *reasoning_plugin;
    char *http_url;
    char *http_token;
    char *http_model;
    char *http_embed_url;
    char *http_embed_model;
    bool  http_allow_plaintext;
    char *http_think;
    char *http_think_provider;
    char *http_native_url;
    char *http_num_ctx;
    char *http_response_mode;
} cognition_config;

static cognition_config g_cfg;     /* effective values */
static cognition_config g_env_fb;  /* boot-env fallback snapshot */
static bool g_env_captured;        /* g_env_fb filled (under load lock) */
static bool g_cfg_initialized;     /* g_cfg filled from the snapshot (until apply) */
static bool g_provider_applied;    /* g_cfg last written by apply_provider */

static char *
dup_env(const char *name)
{
    const char *v = getenv(name);
    return (v && *v) ? strdup(v) : NULL;
}

/* Preferred name first, then the legacy FRACTALSQL_HTTP_* name. The
 * preferred names match the reasoning plugin's own FSQL_REASONING_HTTP_*
 * variable spellings, so the same configured names reach the plugin as
 * is. Legacy names keep existing installs working. */
static char *
dup_env_pref(const char *preferred, const char *legacy)
{
    const char *v = getenv(preferred);
    if (v && *v) return strdup(v);
    return dup_env(legacy);
}

/* strdup `s` (NULL stays NULL) into *out; 0, or -1 on allocation
 * failure. Every owned-copy build below goes through one of these two
 * so allocation failure is checkable, not a NULL that means both. */
static int
dup_or(const char *s, char **out)
{
    if (!s) { *out = NULL; return 0; }
    *out = strdup(s);
    return *out ? 0 : -1;
}

static void
free_cfg(cognition_config *c)
{
    free(c->reasoning_plugin);
    free(c->http_url);
    free(c->http_token);
    free(c->http_model);
    free(c->http_embed_url);
    free(c->http_embed_model);
    free(c->http_think);
    free(c->http_think_provider);
    free(c->http_native_url);
    free(c->http_num_ctx);
    free(c->http_response_mode);
    memset(c, 0, sizeof *c);
}

/* Owned duplicate of every `from` string into `to` (booleans copied
 * as-is). 0, or -1 with `to` fully freed and zeroed on failure. */
static int
dup_cfg(const cognition_config *from, cognition_config *to)
{
    int rc = 0;
    rc |= dup_or(from->reasoning_plugin,   &to->reasoning_plugin);
    rc |= dup_or(from->http_url,           &to->http_url);
    rc |= dup_or(from->http_token,         &to->http_token);
    rc |= dup_or(from->http_model,         &to->http_model);
    rc |= dup_or(from->http_embed_url,     &to->http_embed_url);
    rc |= dup_or(from->http_embed_model,   &to->http_embed_model);
    rc |= dup_or(from->http_think,         &to->http_think);
    rc |= dup_or(from->http_think_provider,&to->http_think_provider);
    rc |= dup_or(from->http_native_url,    &to->http_native_url);
    rc |= dup_or(from->http_num_ctx,       &to->http_num_ctx);
    rc |= dup_or(from->http_response_mode, &to->http_response_mode);
    to->http_allow_plaintext = from->http_allow_plaintext;
    if (rc != 0) {
        free_cfg(to);
        return -1;
    }
    return 0;
}

/* Called with the load lock held. Fills the boot-env fallback snapshot
 * from the process environment exactly once. */
static void
capture_env_fb(void)
{
    const char *plain;
    if (g_env_captured) return;
    g_env_fb.reasoning_plugin   = dup_env("FRACTALSQL_REASONING_PLUGIN");
    g_env_fb.http_url           = dup_env_pref("FSQL_REASONING_HTTP_URL", "FRACTALSQL_HTTP_URL");
    g_env_fb.http_token         = dup_env_pref("FSQL_REASONING_HTTP_TOKEN", "FRACTALSQL_HTTP_TOKEN");
    g_env_fb.http_model         = dup_env_pref("FSQL_REASONING_HTTP_MODEL", "FRACTALSQL_HTTP_MODEL");
    /* Embedding names stay FRACTALSQL_HTTP_EMBED_*. Under the plugin's own
     * FSQL_REASONING_HTTP_* namespace, a preset EMBED_URL leaked into the
     * chat path and the chat call came back HTTP 400. */
    g_env_fb.http_embed_url     = dup_env("FRACTALSQL_HTTP_EMBED_URL");
    g_env_fb.http_embed_model   = dup_env("FRACTALSQL_HTTP_EMBED_MODEL");
    plain = getenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT");
    if (!plain || !*plain) plain = getenv("FRACTALSQL_HTTP_ALLOW_PLAINTEXT");
    g_env_fb.http_allow_plaintext = (plain && *plain && strcmp(plain, "0") != 0);
    g_env_fb.http_think          = dup_env_pref("FSQL_REASONING_HTTP_THINK", "FRACTALSQL_HTTP_THINK");
    g_env_fb.http_think_provider = dup_env_pref("FSQL_REASONING_HTTP_THINK_PROVIDER", "FRACTALSQL_HTTP_THINK_PROVIDER");
    g_env_fb.http_native_url     = dup_env_pref("FSQL_REASONING_HTTP_NATIVE_URL", "FRACTALSQL_HTTP_NATIVE_URL");
    g_env_fb.http_num_ctx        = dup_env_pref("FSQL_REASONING_HTTP_NUM_CTX", "FRACTALSQL_HTTP_NUM_CTX");
    /* No FRACTALSQL_* bridge for this one, by design -- the plugin's
     * raw FSQL_REASONING_HTTP_RESPONSE_MODE is read directly, rather
     * than through a session/config-level FRACTALSQL_* variable.
     * Captured once here so
     * apply_reason_env_locked() can assert this value on every reason-ctx
     * (re)load instead of trusting whatever fractal_t2s_generate's own
     * RESPONSE_MODE=code left in the process environment -- see that
     * function's own comment. RESPONSE_MODE also has no fractalsqld.conf
     * key: apply_provider always copies this boot-captured value. */
    g_env_fb.http_response_mode = dup_env("FSQL_REASONING_HTTP_RESPONSE_MODE");
    g_env_captured = true;
}

static void
ensure_env_config(void)
{
    /* Under the load lock: an embed bracket in another thread would
     * otherwise be visible to this first read of the bridge vars, and
     * the snapshot capture would race a concurrent apply_provider. */
    load_lock();
    capture_env_fb();
    if (!g_provider_applied && !g_cfg_initialized) {
        /* Byte-identical to the old env-only first read. On OOM g_cfg
         * stays zeroed and the dispatch path reports missing config;
         * the next call retries this copy. */
        if (dup_cfg(&g_env_fb, &g_cfg) == 0)
            g_cfg_initialized = true;
    }
    load_unlock();
}

/* ------------------------------------------------------------------ */
/* fractalsqld.conf push path (fractalsql_provider.h contract).       */
/* ------------------------------------------------------------------ */

int
fractalsql_cognition_check_provider(const struct fsq_provider_cfg *c)
{
    /* Loud daemon-side validation lives in fractalsqld's
     * validate_provider_cfg; the cognition tier has no cross-state that
     * constrains a swap: a reasoning-plugin change takes effect on the
     * tier's next dispatch, when the cleared loaded-flags force a fresh
     * fsql_load_reasoning. */
    (void) c;
    return 0;
}

/* Per key: present in the conf -> the daemon's value; absent -> the
 * boot-env fallback (which may itself be NULL/absent). */
int
fractalsql_cognition_apply_provider(const struct fsq_provider_cfg *c)
{
    cognition_config n;
    int rc;

    /* We take the lock ourselves: the daemon calls this on startup and
     * on FSQ_OP_RELOAD, and the swap must be ordered against every
     * dispatch's read of g_cfg (apply_reason_env_locked et al). The tier
     * locks already serialize a dispatch against this apply; taking the
     * load lock here must not be read as a cross-tier dispatch lock. */
    load_lock();
    capture_env_fb();

    memset(&n, 0, sizeof n);
    n.http_allow_plaintext =
        (c->present & FSQL_PROV_REASONING_PLAINTEXT)
            ? c->reasoning_allow_plaintext
            : g_env_fb.http_allow_plaintext;

    rc = 0;
#define SWAP_STR(field, bit, fromfile, fromenv)                               \
    do {                                                                      \
        const char *src = (c->present & (bit)) ? (fromfile) : (fromenv);      \
        if (dup_or(src, &n.field) != 0)                                       \
            rc = -1;                                                          \
    } while (0)
    SWAP_STR(reasoning_plugin,    FSQL_PROV_REASONING_PLUGIN,
             c->reasoning_plugin,  g_env_fb.reasoning_plugin);
    SWAP_STR(http_url,            FSQL_PROV_REASONING_URL,
             c->reasoning_url,     g_env_fb.http_url);
    SWAP_STR(http_token,          FSQL_PROV_REASONING_TOKEN,
             c->reasoning_token,   g_env_fb.http_token);
    SWAP_STR(http_model,          FSQL_PROV_REASONING_MODEL,
             c->reasoning_model,   g_env_fb.http_model);
    SWAP_STR(http_embed_url,      FSQL_PROV_EMBED_URL,
             c->embed_url,         g_env_fb.http_embed_url);
    SWAP_STR(http_embed_model,    FSQL_PROV_EMBED_MODEL,
             c->embed_model,       g_env_fb.http_embed_model);
    SWAP_STR(http_think,          FSQL_PROV_THINK,
             c->think,             g_env_fb.http_think);
    SWAP_STR(http_think_provider, FSQL_PROV_THINK_PROVIDER,
             c->think_provider,    g_env_fb.http_think_provider);
    SWAP_STR(http_native_url,     FSQL_PROV_NATIVE_URL,
             c->think_native_url,  g_env_fb.http_native_url);
    SWAP_STR(http_num_ctx,        FSQL_PROV_NUM_CTX,
             c->think_num_ctx_str, g_env_fb.http_num_ctx);
#undef SWAP_STR
    /* RESPONSE_MODE: no config-file key (boot-env only, above). */
    if (dup_or(g_env_fb.http_response_mode, &n.http_response_mode) != 0)
        rc = -1;

    if (rc != 0) {
        /* Full rollback: every allocation above is freed, g_cfg and
         * g_provider_applied untouched -- the reload refuses as a whole. */
        free_cfg(&n);
        load_unlock();
        return -1;
    }

    free_cfg(&g_cfg);
    g_cfg             = n;
    g_provider_applied = true;
    g_cfg_initialized  = true;

    /* Plugin loads are never attempted here (fractalsql_provider.h): a
     * changed or failing path surfaces on the tier's next dispatch, when
     * these cleared flags force a fresh fsql_load_reasoning. */
    fractal_session_forget_reason_loaded();
    fractal_session_forget_embed_loaded();
    load_unlock();
    return 0;
}

/* Bridge FRACTALSQL_* config into the FSQL_REASONING_HTTP_* names the
 * reasoning-http plugin itself reads. Caller MUST hold g_load_lock.
 * "reason" mode: chat completions. RESPONSE_MODE is ASSERTED from the
 * boot-captured g_cfg.http_response_mode on every load (set if the
 * operator configured one, unset otherwise) rather than trusted from
 * whatever the process environment currently holds -- fractal_t2s_generate
 * (apply_generate_env_locked, fractalsql_textsql.c) sets a temporary
 * RESPONSE_MODE=code for its own dispatch; without this assert, a reason
 * ctx (re)load happening after a generate call in the same backend could
 * silently inherit that leftover value instead of the operator's own
 * setting (or none at all). */
/* Each operator key: present in g_cfg -> applied; absent -> cleared back
 * to the boot-environment fallback (or removed, if the boot env had
 * none). Without the else branch, the LAST applied conf value would
 * stick in the process env after a key is removed from the conf, and
 * that removal would never revert. */
static void
apply_reason_env_locked(void)
{
    if (g_cfg.http_url)
        setenv("FSQL_REASONING_HTTP_URL", g_cfg.http_url, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_URL");
    if (g_cfg.http_token)
        setenv("FSQL_REASONING_HTTP_TOKEN", g_cfg.http_token, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_TOKEN");
    if (g_cfg.http_model)
        setenv("FSQL_REASONING_HTTP_MODEL", g_cfg.http_model, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_MODEL");
    if (g_cfg.http_allow_plaintext)
        setenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT", "1", 1);
    else
        unsetenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT");
    if (g_cfg.http_think)
        setenv("FSQL_REASONING_HTTP_THINK", g_cfg.http_think, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_THINK");
    if (g_cfg.http_think_provider)
        setenv("FSQL_REASONING_HTTP_THINK_PROVIDER", g_cfg.http_think_provider, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_THINK_PROVIDER");
    if (g_cfg.http_native_url)
        setenv("FSQL_REASONING_HTTP_NATIVE_URL", g_cfg.http_native_url, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_NATIVE_URL");
    if (g_cfg.http_num_ctx)
        setenv("FSQL_REASONING_HTTP_NUM_CTX", g_cfg.http_num_ctx, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_NUM_CTX");
    unsetenv("FSQL_REASONING_HTTP_MODE");
    if (g_cfg.http_response_mode)
        setenv("FSQL_REASONING_HTTP_RESPONSE_MODE", g_cfg.http_response_mode, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
    unsetenv("FSQL_REASONING_HTTP_SYSTEM_TAG");
}

/* "embed" mode: embeddings endpoint, no fallback to http_url. Caller
 * MUST hold g_load_lock and must already have checked http_embed_url
 * is non-empty. THINK is chat-only (reasoning-http v1.4.0 doesn't apply
 * it to embedding requests) -- explicit unsetenv so a THINK value the
 * reason tier set earlier in this same process can't leak in here. */
static void
apply_embed_env_locked(void)
{
    setenv("FSQL_REASONING_HTTP_URL", g_cfg.http_embed_url, 1);
    if (g_cfg.http_token) setenv("FSQL_REASONING_HTTP_TOKEN", g_cfg.http_token, 1);
    if (g_cfg.http_embed_model) setenv("FSQL_REASONING_HTTP_MODEL", g_cfg.http_embed_model, 1);
    else unsetenv("FSQL_REASONING_HTTP_MODEL");
    if (g_cfg.http_allow_plaintext) setenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT", "1", 1);
    setenv("FSQL_REASONING_HTTP_MODE", "embedding", 1);
    unsetenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
    unsetenv("FSQL_REASONING_HTTP_SYSTEM_TAG");
    unsetenv("FSQL_REASONING_HTTP_THINK");
    unsetenv("FSQL_REASONING_HTTP_THINK_PROVIDER");
    unsetenv("FSQL_REASONING_HTTP_NATIVE_URL");
    unsetenv("FSQL_REASONING_HTTP_NUM_CTX");
}

/* The embed tier's apply_embed_env_locked() overwrites the bridge vars the
 * reasoning-http plugin (and ensure_env_config) read as the chat/generate
 * endpoint. Save the operator's values before an embed bracket and restore
 * them after, so the process env never carries an embedding URL or model
 * into any other tier's config read or dispatch. Caller MUST hold g_load_lock. */
static const char *const g_bridge_vars[] = {
    "FSQL_REASONING_HTTP_URL", "FSQL_REASONING_HTTP_TOKEN",
    "FSQL_REASONING_HTTP_MODEL", "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT",
    "FSQL_REASONING_HTTP_MODE", "FSQL_REASONING_HTTP_RESPONSE_MODE",
    "FSQL_REASONING_HTTP_SYSTEM_TAG", "FSQL_REASONING_HTTP_THINK",
    "FSQL_REASONING_HTTP_THINK_PROVIDER", "FSQL_REASONING_HTTP_NATIVE_URL",
    "FSQL_REASONING_HTTP_NUM_CTX",
};
#define N_BRIDGE_VARS (sizeof g_bridge_vars / sizeof g_bridge_vars[0])

static void
embed_env_save(char **saved)
{
    for (size_t i = 0; i < N_BRIDGE_VARS; i++) {
        const char *v = getenv(g_bridge_vars[i]);
        saved[i] = v ? strdup(v) : NULL;
    }
}

static void
embed_env_restore(char **saved)
{
    for (size_t i = 0; i < N_BRIDGE_VARS; i++) {
        if (saved[i]) setenv(g_bridge_vars[i], saved[i], 1);
        else          unsetenv(g_bridge_vars[i]);
        free(saved[i]);
        saved[i] = NULL;
    }
}

/* Load the reasoning plugin into `ctx` if not already loaded (per
 * `already_loaded`, from fractal_session_acquire_reason/_embed's
 * *out_loaded), then mark it loaded in the registry on success. */
static bool
ensure_reason_loaded(unsigned long long session_id, fsql_ctx *ctx,
                     bool already_loaded, char *errbuf)
{
    int rc;
    if (already_loaded) return true;
    ensure_env_config();
    if (!g_cfg.reasoning_plugin) {
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: no reasoning plugin configured. Set reasoning_plugin "
            "in fractalsqld.conf and run `fsqlctl reload`, or set "
            "FRACTALSQL_REASONING_PLUGIN in fractalsqld's environment at startup");
        return false;
    }
    load_lock();
    apply_reason_env_locked();
    rc = fsql_load_reasoning(ctx, g_cfg.reasoning_plugin);
    load_unlock();
    if (rc != FSQL_OK) {
        const char *err = fsql_last_error(ctx);
        SFS_INIT_ERROR(errbuf, "fractal_reason: failed to load reasoning plugin (rc=%d): %s",
                       rc, err && *err ? err : "(no detail)");
        return false;
    }
    fractal_session_mark_reason_loaded(session_id);
    return true;
}

static bool
ensure_embed_loaded(unsigned long long session_id, fsql_ctx *ctx,
                    bool already_loaded, char *errbuf)
{
    int rc;
    if (already_loaded) return true;
    ensure_env_config();
    if (!g_cfg.reasoning_plugin) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: no reasoning plugin configured. Set reasoning_plugin "
            "in fractalsqld.conf and run `fsqlctl reload`, or set "
            "FRACTALSQL_REASONING_PLUGIN in fractalsqld's environment at startup");
        return false;
    }
    if (!g_cfg.http_embed_url) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: no embeddings endpoint configured. Set embed_url "
            "in fractalsqld.conf and run `fsqlctl reload`, or set "
            "FRACTALSQL_HTTP_EMBED_URL in fractalsqld's environment at startup");
        return false;
    }
    {
        char *saved[N_BRIDGE_VARS];
        load_lock();
        embed_env_save(saved);
        apply_embed_env_locked();
        rc = fsql_load_reasoning(ctx, g_cfg.reasoning_plugin);
        embed_env_restore(saved);
        load_unlock();
    }
    if (rc != FSQL_OK) {
        const char *err = fsql_last_error(ctx);
        SFS_INIT_ERROR(errbuf, "fractal_embed: failed to load reasoning plugin (rc=%d): %s",
                       rc, err && *err ? err : "(no detail)");
        return false;
    }
    fractal_session_mark_embed_loaded(session_id);
    return true;
}

/* ==================================================================== */
/* UDF triad: fractal_reason(session_id, query [, context]) -> TEXT      */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_reason_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2 && args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_reason(session_id, query [, context]): expected 2 or 3 "
            "arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = STRING_RESULT;
    if (args->arg_count == 3) args->arg_type[2] = STRING_RESULT;
    return str_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_reason_deinit(UDF_INIT *initid) { str_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_reason(UDF_INIT *initid, UDF_ARGS *args, char *result,
               unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    unsigned long long sid;
    const char *ctx_json;
    unsigned long ctx_json_len;
    bool    loaded = false;
    fsql_ctx *ctx;
    fsql_ai_response_t resp;
    int     rc;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[1] > FRACTAL_COGNITION_MAX_INPUT_BYTES) { *error = 1; return NULL; }
    if (args->arg_count == 3 && args->args[2] != NULL) {
        if (args->lengths[2] > FRACTAL_COGNITION_MAX_INPUT_BYTES) { *error = 1; return NULL; }
        ctx_json     = args->args[2];
        ctx_json_len = args->lengths[2];
    } else {
        ctx_json     = "{}";
        ctx_json_len = 2;
    }
    sid = (unsigned long long) *(long long *) args->args[0];

    ctx = fractal_session_acquire_reason(sid, &loaded);
    if (ctx == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: session acquire failed for id %llu", sid);
        *error = 1; return NULL;
    }

    if (!ensure_reason_loaded(sid, ctx, loaded, errbuf)) {
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    memset(&resp, 0, sizeof(resp));
    /* The plugin reads its mode from the process environment, which is
     * shared by every slot, so each dispatch re-applies its own settings
     * under the load lock. Otherwise the previous call's mode (embedding,
     * for example) is what the next call sees. */
    load_lock();
    apply_reason_env_locked();
    rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1],
                          ctx_json, ctx_json_len, &resp);
    load_unlock();
    if (rc != FSQL_OK || resp.rc != 0) {
        const char *err = fsql_last_error(ctx);
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: dispatch failed (rc=%d, resp.rc=%d): %s",
            rc, resp.rc, err && *err ? err : "(no detail)");
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    if (resp.summary_len > FRACTAL_MAX_AI_RESPONSE_BYTES) {
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: response of %zu bytes exceeds the %zu-byte cap",
            resp.summary_len, (size_t) FRACTAL_MAX_AI_RESPONSE_BYTES);
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    /* The rc==0 dispatch contract says summary is non-NULL, but the
     * copy below would crash on a contract-violating plugin -- a
     * plugin bug gets a clean error, not a segfault. */
    if (resp.summary == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: reasoning plugin returned a NULL summary on a "
            "success status -- likely a plugin bug");
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    if (!str_out_ensure(so, resp.summary_len + 1)) {
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    memcpy(so->buf, resp.summary, resp.summary_len);
    so->buf[resp.summary_len] = '\0';
    *length = (unsigned long) resp.summary_len;

    fsql_ai_response_free(&resp);
    fractal_session_release(sid);
    *is_null = 0;
    return so->buf;
}

/* ==================================================================== */
/* UDF triad: fractal_embed(session_id, input) -> TEXT (fractal_vector)  */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_embed_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_embed(session_id, input): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = STRING_RESULT;
    return str_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_embed_deinit(UDF_INIT *initid) { str_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_embed(UDF_INIT *initid, UDF_ARGS *args, char *result,
              unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    unsigned long long sid;
    bool    loaded = false;
    fsql_ctx *ctx;
    fsql_ai_response_t resp;
    int     rc;
    double *dv = NULL;
    size_t  n  = 0;
    float  *fv;
    char   *s;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[1] > FRACTAL_COGNITION_MAX_INPUT_BYTES) { *error = 1; return NULL; }
    sid = (unsigned long long) *(long long *) args->args[0];

    ctx = fractal_session_acquire_embed(sid, &loaded);
    if (ctx == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: session acquire failed for id %llu", sid);
        *error = 1; return NULL;
    }

    if (!ensure_embed_loaded(sid, ctx, loaded, errbuf)) {
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    memset(&resp, 0, sizeof(resp));
    /* context_json is accepted by fsql_dispatch_ai's signature but
     * ignored entirely by the plugin in embedding mode: "{}", the same
     * as fractal_reason's own default. */
    {
        char *saved[N_BRIDGE_VARS];
        load_lock();
        embed_env_save(saved);
        apply_embed_env_locked();
        rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1], "{}", 2, &resp);
        embed_env_restore(saved);
        load_unlock();
    }
    if (rc != FSQL_OK || resp.rc != 0) {
        const char *err = fsql_last_error(ctx);
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: dispatch failed (rc=%d, resp.rc=%d): %s",
            rc, resp.rc, err && *err ? err : "(no detail)");
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    if (resp.summary_len > FRACTAL_MAX_AI_RESPONSE_BYTES) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: response of %zu bytes exceeds the %zu-byte cap",
            resp.summary_len, (size_t) FRACTAL_MAX_AI_RESPONSE_BYTES);
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    /* The rc==0 dispatch contract says summary is non-NULL; the parse
     * below would memcpy from NULL on a contract-violating plugin --
     * a plugin bug gets a clean error, not undefined behavior. */
    if (resp.summary == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: reasoning plugin returned a NULL summary on a "
            "success status -- likely a plugin bug");
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    /* parse_vector_csv takes an explicit length, not requiring NUL
     * termination, so resp.summary can be handed to it directly, no
     * copy needed (mirrors fractal_vector_dims's own direct-parse of
     * args->args[0]/args->lengths[0]). */
    if (!parse_vector_csv(resp.summary, resp.summary_len, &dv, &n, errbuf)) {
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    fsql_ai_response_free(&resp);

    if (n == 0 || n > FRACTAL_MAX_EMBED_DIM) {
        free(dv);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    fv = malloc(n * sizeof(float));
    if (fv == NULL) {
        free(dv);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    for (size_t i = 0; i < n; i++) fv[i] = (float) dv[i];
    free(dv);

    s = format_vector_json(so, fv, n, length);
    free(fv);
    fractal_session_release(sid);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}
