/* src/fractalsql_cognition.c
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
 *   So there is no plugin descriptor. Config is read from mysqld's process
 *   environment once, lazily, on first use:
 *     FRACTALSQL_REASONING_PLUGIN   absolute path to a fsql_reasoning_
 *                                   init-exporting .so (required)
 *     FRACTALSQL_HTTP_URL           chat-completions endpoint, for
 *                                   fractal_reason()
 *     FRACTALSQL_HTTP_TOKEN         bearer/api-key token
 *     FRACTALSQL_HTTP_MODEL         chat model name
 *     FRACTALSQL_HTTP_EMBED_URL     embeddings endpoint, for
 *                                   fractal_embed() (no fallback to
 *                                   HTTP_URL: it is a different
 *                                   endpoint shape)
 *     FRACTALSQL_HTTP_EMBED_MODEL   embedding model name
 *     FRACTALSQL_HTTP_ALLOW_PLAINTEXT  "1" to allow a non-TLS URL
 *   Set these in mysqld's environment (systemd Environment=, Docker
 *   `environment:`) before start. Changing them requires a restart:
 *   there is no config file or reload-without-restart option.
 *
 * PER-SESSION DISPATCH CONTEXT
 *
 *   fsql_ctx is single-thread-affine by convention (fractalsql-core's
 *   docs/BINDING_THREAD_AFFINITY.md): a single ctx shared across MariaDB's
 *   concurrently executing connection threads would be unsafe, the same
 *   hazard the session registry already guards against for Diversify's
 *   ctx. So fractal_reason/fractal_embed take an explicit session_id
 *   BIGINT first argument (CONNECTION_ID() by convention, matching every
 *   other session_id-scoped function in this repo) and dispatch through
 *   two per-session ctx slots in fractalsql_session.c's registry
 *   (reason_ctx, embed_ctx), kept distinct from each other and from the
 *   Diversify ctx because fsql_load_reasoning() replaces whatever
 *   reasoning VFS is already attached, and reason/embed load with
 *   different HTTP config.
 *
 * THE setenv() RACE
 *
 *   The reasoning-http plugin (fractalsql-reasoning-http.so) reads its own
 *   config purely from FSQL_REASONING_HTTP_* process environment variables
 *   at fsql_load_reasoning() time; there is no non-env config channel in
 *   its ABI. Bridging this repo's FRACTALSQL_* config into those
 *   FSQL_REASONING_HTTP_* names is therefore a setenv() call immediately
 *   followed by fsql_load_reasoning(), and setenv() mutates process-wide
 *   state. MariaDB runs one shared multithreaded process for every
 *   connection, so a fractal_embed call on one connection thread and a
 *   fractal_reason call on another could interleave their setenv() calls
 *   and load ctx A with ctx B's URL. g_load_lock below serializes the
 *   whole "setenv the bridge vars, then fsql_load_reasoning" step
 *   process-wide. It is held only for that narrow window, once per
 *   (session, purpose) pair (the *_loaded flag skips it on every
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
#  include <windows.h>
#else
#  include <pthread.h>
#endif

#include "fractalsql.h"          /* FSQL_OK, fsql_last_error */
#include "fractalsql_sql.h"      /* fsql_ctx, fsql_dispatch_ai, fsql_load_reasoning */
#include "fractalsql_session.h"  /* fractal_session_acquire_reason/_embed, ... */
#include "fractalsql_parse.h"    /* parse_vector_csv (shared with fractalsql.c) */

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
 * nothing in mariadbd's log). Mirror every message to stderr as a
 * second channel -- mariadbd's stderr is the console for a foreground
 * start and the server's own .err file under a service manager. All
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
static INIT_ONCE        g_cfg_once  = INIT_ONCE_STATIC_INIT;
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
static pthread_once_t  g_cfg_once  = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_load_lock = PTHREAD_MUTEX_INITIALIZER;
static void load_lock(void)   { pthread_mutex_lock(&g_load_lock); }
static void load_unlock(void) { pthread_mutex_unlock(&g_load_lock); }
#endif

/* ------------------------------------------------------------------ */
/* Environment-variable config, read once and cached for the process  */
/* lifetime.                                                          */
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
} cognition_config;

static cognition_config g_cfg;

static char *
dup_env(const char *name)
{
    const char *v = getenv(name);
    return (v && *v) ? strdup(v) : NULL;
}

#if defined(_WIN32)
static BOOL CALLBACK
load_cfg_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
#else
static void
load_cfg_once(void)
{
#endif
    const char *plain;
    g_cfg.reasoning_plugin   = dup_env("FRACTALSQL_REASONING_PLUGIN");
    g_cfg.http_url           = dup_env("FRACTALSQL_HTTP_URL");
    g_cfg.http_token         = dup_env("FRACTALSQL_HTTP_TOKEN");
    g_cfg.http_model         = dup_env("FRACTALSQL_HTTP_MODEL");
    g_cfg.http_embed_url     = dup_env("FRACTALSQL_HTTP_EMBED_URL");
    g_cfg.http_embed_model   = dup_env("FRACTALSQL_HTTP_EMBED_MODEL");
    plain = getenv("FRACTALSQL_HTTP_ALLOW_PLAINTEXT");
    g_cfg.http_allow_plaintext = (plain && *plain && strcmp(plain, "0") != 0);
    g_cfg.http_think          = dup_env("FRACTALSQL_HTTP_THINK");
    g_cfg.http_think_provider = dup_env("FRACTALSQL_HTTP_THINK_PROVIDER");
    g_cfg.http_native_url     = dup_env("FRACTALSQL_HTTP_NATIVE_URL");
    g_cfg.http_num_ctx        = dup_env("FRACTALSQL_HTTP_NUM_CTX");
#if defined(_WIN32)
    return TRUE;
#endif
}

static void
ensure_env_config(void)
{
#if defined(_WIN32)
    InitOnceExecuteOnce(&g_cfg_once, load_cfg_once, NULL, NULL);
#else
    pthread_once(&g_cfg_once, load_cfg_once);
#endif
}

/* Bridge FRACTALSQL_* config into the FSQL_REASONING_HTTP_* names the
 * reasoning-http plugin itself reads. Caller MUST hold g_load_lock.
 * "reason" mode: chat completions, no RESPONSE_MODE override. Explicitly
 * unsets vars a different purpose may have set earlier in this process. */
static void
apply_reason_env_locked(void)
{
    if (g_cfg.http_url)   setenv("FSQL_REASONING_HTTP_URL",   g_cfg.http_url,   1);
    if (g_cfg.http_token) setenv("FSQL_REASONING_HTTP_TOKEN", g_cfg.http_token, 1);
    if (g_cfg.http_model) setenv("FSQL_REASONING_HTTP_MODEL", g_cfg.http_model, 1);
    if (g_cfg.http_allow_plaintext) setenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT", "1", 1);
    if (g_cfg.http_think)          setenv("FSQL_REASONING_HTTP_THINK",          g_cfg.http_think,          1);
    if (g_cfg.http_think_provider) setenv("FSQL_REASONING_HTTP_THINK_PROVIDER", g_cfg.http_think_provider, 1);
    if (g_cfg.http_native_url)     setenv("FSQL_REASONING_HTTP_NATIVE_URL",     g_cfg.http_native_url,     1);
    if (g_cfg.http_num_ctx)        setenv("FSQL_REASONING_HTTP_NUM_CTX",        g_cfg.http_num_ctx,        1);
    unsetenv("FSQL_REASONING_HTTP_MODE");
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
            "fractal_reason: no reasoning plugin configured. Set "
            "FRACTALSQL_REASONING_PLUGIN in mysqld's environment and restart");
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
            "fractal_embed: no reasoning plugin configured. Set "
            "FRACTALSQL_REASONING_PLUGIN in mysqld's environment and restart");
        return false;
    }
    if (!g_cfg.http_embed_url) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: FRACTALSQL_HTTP_EMBED_URL is not configured. "
            "Set it to the provider's embeddings endpoint and restart");
        return false;
    }
    load_lock();
    apply_embed_env_locked();
    rc = fsql_load_reasoning(ctx, g_cfg.reasoning_plugin);
    load_unlock();
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
    rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1],
                          ctx_json, ctx_json_len, &resp);
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
    rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1], "{}", 2, &resp);
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
