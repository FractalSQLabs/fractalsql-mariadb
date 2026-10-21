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
#include "fractalsql_enterprise.h"   /* fractal_plugin_verify */
#define FSQL_EPLUGIN_REFUSED (-9001)
#include "fractalsql_session.h"      /* fractal_session_acquire_reason/_embed, ... */
#include "fractalsql_parse.h"        /* parse_vector_csv (shared with fractalsql.c) */
#include "fractalsql_provider.h"     /* fractalsql_cognition_{check,apply}_provider */
#include "fractalsql_config.h"       /* the per-session configuration overlay */

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
 * failure would surface as a bare NULL with its cause dropped. Every
 * message is therefore also written to stderr as a second channel: the
 * daemon's stderr is the console for a foreground start and its log
 * file under a service manager. All call sites are one-shot
 * validation/load failures, not per-row hot paths, so this stays
 * log-quiet. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* The reasoning plugin's own diagnostic string is UNBOUNDED: a failed
 * HTTP round trip can echo a whole response body back into it. The
 * UDF ABI's error buffer is MYSQL_ERRMSG_SIZE (512) bytes, so a plain
 * snprintf cuts the message at an arbitrary byte with nothing to say
 * so -- and at the two reason-tier sites below this message IS the
 * text the client receives (it is embedded verbatim in the
 * "reasoning_step_failed" document), so a half message would read as
 * a whole one, and the cut can land mid-UTF-8 or mid-URL. The
 * unbounded operand is therefore shortened HERE, with an explicit
 * marker, before the fixed text is formatted around it. The bounded
 * copy plus the longest fixed lead around it stays well inside
 * MYSQL_ERRMSG_SIZE. */
#define SFS_DETAIL_MAX 256
#define SFS_DETAIL_MARK "...[truncated]"

/* Copies `detail` into `out` (capacity `cap`), cut at a UTF-8 scalar
 * boundary and marked when it does not fit. */
static void
sfs_detail_bounded(const char *detail, char *out, size_t cap)
{
    size_t len = strlen(detail);
    if (len + 1 <= cap) { memcpy(out, detail, len + 1); return; }
    {
        size_t mark = sizeof SFS_DETAIL_MARK - 1;
        size_t keep = cap - 1 - mark;      /* room for the marker + NUL */
        if (keep > len) keep = len;
        /* Never cut inside a UTF-8 sequence. */
        while (keep > 0 && ((unsigned char) detail[keep] & 0xC0) == 0x80)
            keep--;
        memcpy(out, detail, keep);
        memcpy(out + keep, SFS_DETAIL_MARK, mark + 1);
    }
}

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

/* ------------------------------------------------------------------ */
/* Partial-result sentinel. When a session opted in    */
/* (fractal_agent_partial_fail, session registry), the agent-tier's     */
/* endpoint failure paths below return this JSON document instead of   */
/* a silent NULL: the calling procedure keeps its computed data half    */
/* and surfaces "reasoning_step_failed" to the client verbatim. Only    */
/* the reasoning plugin's own detail lands in the string, so it is      */
/* capped and JSON-escaped (plugin errors can carry quotes,             */
/* backslashes and raw newlines). Truncation is a clean cut at a        */
/* scalar boundary, never a partial escape sequence, and it is         */
/* MARKED: a client that cannot tell a cut message from a whole one    */
/* would read half a plugin diagnostic as the whole story.             */
/* ------------------------------------------------------------------ */
#define FRACTAL_PARTIAL_DETAIL_MAX 512

static size_t
json_escape_into(char *dst, size_t dst_cap, const char *src, size_t src_len)
{
    size_t w = 0, r = 0;
    while (r < src_len && w + 6 < dst_cap) { /* room for \uXXXX worst case */
        unsigned char c = (unsigned char) src[r];
        if (c == '"' || c == '\\') {
            dst[w++] = '\\'; dst[w++] = (char) c;
        } else if (c < 0x20) {
            snprintf(dst + w, 7, "\\u%04x", (unsigned) c);
            w += 6;
        } else {
            dst[w++] = (char) c;
        }
        r++;
    }
    dst[w] = '\0';
    return w;
}

static char *
agent_partial_sentinel(str_out_ctx *so, const char *errbuf,
                       unsigned long *out_len)
{
    const char *detail = (errbuf && *errbuf) ? errbuf : "(no detail)";
    size_t detail_len = strlen(detail);
    bool truncated = false;
    if (detail_len > FRACTAL_PARTIAL_DETAIL_MAX) {
        detail_len = FRACTAL_PARTIAL_DETAIL_MAX;
        while (detail_len > 0 && ((unsigned char) detail[detail_len] & 0xC0) == 0x80)
            detail_len--; /* do not cut inside a UTF-8 sequence */
        truncated = true;
    }
    /* escape needs room for the fully-escaped 6x expansion of detail
     * (and of the truncation marker), plus the document's fixed
     * envelope */
    size_t need = (detail_len + 16) * 6 + 48;
    if (!str_out_ensure(so, need)) return NULL;

    size_t pos = 0;
    memcpy(so->buf, "{\"reasoning_step_failed\":\"", 26);
    pos = 26;
    pos += json_escape_into(so->buf + pos, so->cap - pos - 2,
                            detail, detail_len);
    if (truncated) {
        static const char mark[] = "...[truncated]";
        pos += json_escape_into(so->buf + pos, so->cap - pos - 2,
                                mark, sizeof mark - 1);
    }
    so->buf[pos++] = '"';
    so->buf[pos++] = '}';
    so->buf[pos]    = '\0';
    *out_len = (unsigned long) pos;
    return so->buf;
}

/* Shared tail for fractal_reason's endpoint-class failure paths. The
 * partial path returns the sentinel (NOT *error = 1): MariaDB UDFs
 * have no error-message channel on *error, so errbuf's detail is only
 * recoverable by going this route. Call after the session reference
 * has already been released. */
static char *
agent_partial_or_error(unsigned long long sid, str_out_ctx *so,
                       const char *errbuf, unsigned long *length,
                       char *is_null, char *error)
{
    if (fractal_session_get_agent_partial(sid)) {
        char *p = agent_partial_sentinel(so, errbuf, length);
        if (p != NULL) { *is_null = 0; return p; }
    }
    *error = 1; return NULL;
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

/* The reasoning plugin is native code -- verify it (signature or pinned digest)
 * before every load. A refusal leaves its message here for the caller's error text. */
static char g_plugin_verr[512];
static int
checked_load_reasoning(fsql_ctx *ctx)
{
    g_plugin_verr[0] = '\0';
    if (!fractal_plugin_verify(g_cfg.reasoning_plugin, g_plugin_verr, sizeof g_plugin_verr))
        return FSQL_EPLUGIN_REFUSED;
    return fsql_load_reasoning(ctx, g_cfg.reasoning_plugin);
}

/* The fingerprint of the bridge environment each tier's plugin instance
 * was last loaded with (see reason_env_and_reload). A changed provider
 * invalidates it: the fingerprint describes the ENVIRONMENT, and a
 * provider reload can change the plugin PATH -- the thing the instance
 * was loaded from -- without changing the environment at all. */
static uint64_t g_reason_fp = 0;
static bool     g_reason_fp_valid = false;
static uint64_t g_embed_fp = 0;
static bool     g_embed_fp_valid = false;

/* Owned copy of an environment variable: 0 with *out set to the
 * value (NULL when the variable is unset or empty), or -1 when the
 * copy failed. The distinction is the point. A NULL that means "the
 * operator set nothing" and a NULL that means "the copy ran out of
 * memory" are different facts, and conflating them turns an
 * allocation failure into "not configured" -- which, in the boot
 * snapshot below, would be latched for the life of the process. */
static int
dup_env_into(const char *name, char **out)
{
    const char *v = getenv(name);
    *out = NULL;
    if (v == NULL || *v == '\0') return 0;
    *out = strdup(v);
    return *out ? 0 : -1;
}

/* Preferred name first, then the legacy FRACTALSQL_HTTP_* name. The
 * preferred names match the reasoning plugin's own FSQL_REASONING_HTTP_*
 * variable spellings, so the same configured names reach the plugin as
 * is. Legacy names keep existing installs working. */
static int
dup_env_pref_into(const char *preferred, const char *legacy, char **out)
{
    const char *v = getenv(preferred);
    *out = NULL;
    if (v && *v) {
        *out = strdup(v);
        return *out ? 0 : -1;
    }
    return dup_env_into(legacy, out);
}

/* strdup `s` (NULL stays NULL) into *out; 0, or -1 on allocation
 * failure. Every owned-copy build below goes through one of these two
 * so allocation failure is checkable, not a NULL that means both.
 * A NULL `out` is rejected rather than dereferenced: the caller owns
 * the contract that `out` is a valid pointer. */
static int
dup_or(const char *s, char **out)
{
    if (!out) return -1;
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
static bool
capture_env_fb(void)
{
    const char *plain;
    int rc = 0;
    if (g_env_captured) return true;
    rc |= dup_env_into("FRACTALSQL_REASONING_PLUGIN", &g_env_fb.reasoning_plugin);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_URL", "FRACTALSQL_HTTP_URL", &g_env_fb.http_url);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_TOKEN", "FRACTALSQL_HTTP_TOKEN", &g_env_fb.http_token);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_MODEL", "FRACTALSQL_HTTP_MODEL", &g_env_fb.http_model);
    /* Embedding names stay FRACTALSQL_HTTP_EMBED_*. Under the plugin's own
     * FSQL_REASONING_HTTP_* namespace, a preset EMBED_URL leaked into the
     * chat path and the chat call came back HTTP 400. */
    rc |= dup_env_into("FRACTALSQL_HTTP_EMBED_URL", &g_env_fb.http_embed_url);
    rc |= dup_env_into("FRACTALSQL_HTTP_EMBED_MODEL", &g_env_fb.http_embed_model);
    plain = getenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT");
    if (!plain || !*plain) plain = getenv("FRACTALSQL_HTTP_ALLOW_PLAINTEXT");
    g_env_fb.http_allow_plaintext = (plain && *plain && strcmp(plain, "0") != 0);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_THINK", "FRACTALSQL_HTTP_THINK", &g_env_fb.http_think);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_THINK_PROVIDER", "FRACTALSQL_HTTP_THINK_PROVIDER", &g_env_fb.http_think_provider);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_NATIVE_URL", "FRACTALSQL_HTTP_NATIVE_URL", &g_env_fb.http_native_url);
    rc |= dup_env_pref_into("FSQL_REASONING_HTTP_NUM_CTX", "FRACTALSQL_HTTP_NUM_CTX", &g_env_fb.http_num_ctx);
    /* No FRACTALSQL_* bridge for this one, by design -- the plugin's
     * raw FSQL_REASONING_HTTP_RESPONSE_MODE is read directly, rather
     * than through a session/config-level FRACTALSQL_* variable.
     * Captured once here so
     * apply_reason_env_locked() can assert this value on every reason-ctx
     * (re)load instead of trusting whatever fractal_t2s_generate's own
     * RESPONSE_MODE=code left in the process environment -- see that
     * function's own comment. RESPONSE_MODE also has no fractalsqld.conf
     * key: apply_provider always copies this boot-captured value. */
    rc |= dup_env_into("FSQL_REASONING_HTTP_RESPONSE_MODE", &g_env_fb.http_response_mode);
    if (rc != 0) {
        /* Drop the partial snapshot: the next capture starts from
         * scratch, and nothing half-filled is ever published. g_env-
         * captured stays false, so the failure is not latched. */
        free_cfg(&g_env_fb);
        return false;
    }
    g_env_captured = true;
    return true;
}

static bool
ensure_env_config(char *errbuf)
{
    bool ok;
    /* Under the load lock: an embed bracket in another thread would
     * otherwise be visible to this first read of the bridge vars, and
     * the snapshot capture would race a concurrent apply_provider. */
    load_lock();
    ok = capture_env_fb();
    if (ok && !g_provider_applied && !g_cfg_initialized) {
        /* Byte-identical to the old env-only first read. On OOM g_cfg
         * stays zeroed and the dispatch path reports missing config;
         * the next call retries this copy. */
        if (dup_cfg(&g_env_fb, &g_cfg) == 0)
            g_cfg_initialized = true;
    }
    load_unlock();
    if (!ok) {
        SFS_INIT_ERROR(errbuf,
            "fractal_cognition: out of memory reading the process environment");
        return false;
    }
    return true;
}

/* ------------------------------------------------------------------ */
/* Read side for the configuration surface (fractalsql_config.h).      */
/* ------------------------------------------------------------------ */

/* The effective value of one configuration key this tier owns, as the
 * config surface's read path needs it. Returns 0 and fills `out` when
 * the key is one this tier owns and currently holds a value for, -1
 * otherwise. A long value is truncated to the caller's buffer rather
 * than refused: the caller asked for the value, and a truncated value
 * is still a value. The secret keys (reasoning_token) are readable
 * HERE -- this is the tier's own configuration, inside the daemon --
 * but the config surface redacts them before a session ever sees
 * one. */
int
fractalsql_cognition_config_value(const char *name, char *out, size_t outcap)
{
    int rc = -1;

    if (name == NULL || out == NULL || outcap == 0) return -1;
    out[0] = '\0';

    /* The copy happens INSIDE the lock. The value is a pointer into
     * the tier's own config, and the provider-reload path frees
     * exactly these strings (free_cfg) under the same lock: a copy
     * taken after the unlock was a use-after-free read, racing a
     * `fsqlctl reload` on another connection thread. */
    load_lock();
    {
        const char *v = NULL;
        if (strcmp(name, "reasoning_plugin") == 0)            v = g_cfg.reasoning_plugin;
        else if (strcmp(name, "reasoning_url") == 0)          v = g_cfg.http_url;
        else if (strcmp(name, "reasoning_token") == 0)        v = g_cfg.http_token;
        else if (strcmp(name, "reasoning_model") == 0)        v = g_cfg.http_model;
        else if (strcmp(name, "embed_url") == 0)              v = g_cfg.http_embed_url;
        else if (strcmp(name, "embed_model") == 0)            v = g_cfg.http_embed_model;
        else if (strcmp(name, "think") == 0)                  v = g_cfg.http_think;
        else if (strcmp(name, "think_provider") == 0)         v = g_cfg.http_think_provider;
        else if (strcmp(name, "think_native_url") == 0)       v = g_cfg.http_native_url;
        else if (strcmp(name, "think_num_ctx") == 0)          v = g_cfg.http_num_ctx;
        else if (strcmp(name, "reasoning_allow_plaintext") == 0) {
            v = g_cfg.http_allow_plaintext ? "1" : "0";
        }
        if (v != NULL) {
            size_t n = strlen(v);
            if (n > outcap - 1) n = outcap - 1;
            memcpy(out, v, n);
            out[n] = '\0';
            rc = 0;
        }
    }
    load_unlock();
    return rc;
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
    if (!capture_env_fb()) {
        /* The boot-environment fallback could not be captured, so the
         * provider's own values would be applied over a snapshot that
         * silently dropped whatever the operator set. The apply
         * refuses as a whole instead. */
        load_unlock();
        return -1;
    }

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
     * these cleared flags force a fresh fsql_load_reasoning. The
     * fingerprints are cleared with them: a provider reload can change
     * the plugin PATH, and the fingerprint only describes the
     * environment -- a path change leaves it untouched. */
    fractal_session_forget_reason_loaded();
    fractal_session_forget_embed_loaded();
    g_reason_fp_valid = false;
    g_embed_fp_valid  = false;
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
    /* Same key-removal contract as apply_reason_env_locked: an absent
     * g_cfg field is cleared rather than left at whatever the last
     * tier published. Without it the embed tier's fingerprint would
     * depend on which tier happened to run before it. */
    if (g_cfg.http_token) setenv("FSQL_REASONING_HTTP_TOKEN", g_cfg.http_token, 1);
    else unsetenv("FSQL_REASONING_HTTP_TOKEN");
    if (g_cfg.http_embed_model) setenv("FSQL_REASONING_HTTP_MODEL", g_cfg.http_embed_model, 1);
    else unsetenv("FSQL_REASONING_HTTP_MODEL");
    if (g_cfg.http_allow_plaintext) setenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT", "1", 1);
    else unsetenv("FSQL_REASONING_HTTP_ALLOW_PLAINTEXT");
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
 * into any other tier's config read or dispatch. The list itself is the
 * shared one (fractalsql_config.h) so the save/restore bracket and the
 * environment fingerprint always cover the same set of names. Caller MUST
 * hold g_load_lock. */
#define g_bridge_vars fsq_cfg_bridge_vars
#define N_BRIDGE_VARS FSQ_CFG_BRIDGE_VAR_COUNT

/* A saved slot has THREE states, not two: the operator's value was
 * copied (the slot holds the copy), the variable was not in the
 * environment at all (the slot is NULL), or the copy FAILED (the slot
 * holds EMBED_ENV_OOM). The third state has to be distinguishable
 * from the second: a NULL that means "the copy failed" reads as "the
 * variable was not set", and the restore would then DELETE the
 * operator's value from the process environment -- a permanent, silent
 * loss of configuration caused by an allocation failure. The marker's
 * address is unique and is never dereferenced. */
static char embed_env_oom_marker;
#define EMBED_ENV_OOM (&embed_env_oom_marker)

/* Saves every bridge variable. Returns false if a copy failed, in
 * which case the slots that WERE saved still hold their copies and the
 * failed slot holds EMBED_ENV_OOM -- the caller must not publish the
 * embed tier's values over an environment it could not capture. */
static bool
embed_env_save(char **saved)
{
    bool ok = true;
    for (size_t i = 0; i < N_BRIDGE_VARS; i++) {
        const char *v = getenv(g_bridge_vars[i]);
        if (v == NULL) { saved[i] = NULL; continue; }
        {
            char *copy = strdup(v);
            if (copy == NULL) { saved[i] = EMBED_ENV_OOM; ok = false; continue; }
            saved[i] = copy;
        }
    }
    return ok;
}

static void
embed_env_restore(char **saved)
{
    for (size_t i = 0; i < N_BRIDGE_VARS; i++) {
        if (saved[i] == EMBED_ENV_OOM) {
            /* The copy failed, so the original value was never
             * captured: leave the variable exactly as it stands
             * rather than unsetting the operator's value. */
            saved[i] = NULL;
            continue;
        }
        if (saved[i]) setenv(g_bridge_vars[i], saved[i], 1);
        else          unsetenv(g_bridge_vars[i]);
        free(saved[i]);
        saved[i] = NULL;
    }
}

/* ------------------------------------------------------------------- */
/* Publish the bridge environment, and reload the tier's instance when */
/* the published configuration is not the one the instance was loaded  */
/* with.                                                             */
/* ------------------------------------------------------------------- */

/* The fingerprint of the bridge environment each tier's instance was
 * last loaded with is declared with the rest of the tier's state, up
 * by g_cfg: a provider reload invalidates it. */

/* Publishes the reason tier's settings plus this session's own
 * overrides, and (re)loads the tier's plugin instance when the
 * effective configuration no longer matches the loaded one.
 *
 * WHY THE RELOAD: the reasoning plugin reads its configuration ONCE,
 * when it is loaded, and bakes it into the loaded instance -- the
 * plugin's ABI has no per-dispatch configuration read, and the
 * vendored core never reads the environment at all. A session's
 * model/THINK override is published into the environment, so it only
 * reaches the plugin if the instance is loaded again with that
 * environment in place. That is what the fingerprint decides.
 *
 * THE COST: the tier holds ONE instance, shared by every session, so
 * two sessions asking for different models make the tier reload
 * between their calls. A session that overrides nothing never
 * triggers a reload: the fingerprint then matches the instance the
 * tier already holds.
 *
 * Caller MUST hold the tier's dispatch lock (g_load_lock): the ctx is
 * single-thread affine, and the load replaces the plugin attached to
 * it. Returns false with a one-line reason on a load failure. */
static bool
reason_env_and_reload(fsql_ctx *ctx, unsigned long long session_id,
                       char *errbuf)
{
    uint64_t fp;
    int rc;

    /* The environment lock is taken around the whole publish+load
     * window, and released again before the dispatch: the plugin does
     * not read the environment during a dispatch, so holding it across
     * the network round trip would only serialise the tiers against
     * each other for no gain. */
    fractal_config_env_lock();
    apply_reason_env_locked();
    fractal_config_apply_env_overrides(session_id, FSQL_CFG_TIER_REASON);
    fp = fractal_config_env_fingerprint();
    if (!g_reason_fp_valid || fp != g_reason_fp) {
        rc = checked_load_reasoning(ctx);
        if (rc != FSQL_OK) {
            fractal_config_env_unlock();
            {
                const char *err = g_plugin_verr[0] ? g_plugin_verr : fsql_last_error(ctx);
                char detail[SFS_DETAIL_MAX + sizeof SFS_DETAIL_MARK];
                sfs_detail_bounded(err && *err ? err : "(no detail)",
                                   detail, sizeof detail);
                SFS_INIT_ERROR(errbuf,
                    "fractal_reason: failed to load reasoning plugin (rc=%d): %s",
                    rc, detail);
            }
            return false;
        }
        /* Fingerprinted AFTER the load, so it describes the
         * environment the loaded instance actually saw. */
        g_reason_fp = fractal_config_env_fingerprint();
        g_reason_fp_valid = true;
    }
    fractal_config_env_unlock();
    return true;
}

/* The embed tier's twin of reason_env_and_reload. The embed tier
 * BRACKETS its own settings: the operator's values are saved before
 * the bracket and restored after it, so the process environment never
 * carries an embedding URL or model into another tier.
 *
 * The bracket SPANS THE DISPATCH, and that is the point of it. The
 * embed tier is the one tier whose settings are the OPPOSITE of the
 * chat tier's: THINK is a chat-only knob, and the embed tier clears
 * it explicitly so a THINK value the chat tier set earlier in this
 * same process cannot leak into an embedding request. A plugin that
 * reads its configuration when it is DISPATCHED -- not only when it
 * is loaded -- would see the chat tier's THINK values again if the
 * bracket were closed before the dispatch, which is exactly what
 * happens when the restore runs too early.
 *
 * So the bracket is OPENED here and CLOSED by the caller (embed_env_close)
 * after the dispatch. The tier's dispatch lock (g_load_lock) is held
 * across the whole window, and every other tier's publish needs that
 * same lock, so no other tier can republish the chat environment
 * underneath an embedding request that is in flight.
 *
 * CONTRACT: embed_env_open always fills `saved` (the save happens before
 * anything that can fail), and the caller must call embed_env_close
 * exactly once afterwards -- on the failure path too, so the operator's
 * values are put back and the saved copies are freed. */
static bool
embed_env_open(fsql_ctx *ctx, unsigned long long session_id,
               char **saved, char *errbuf)
{
    uint64_t fp;
    int rc = FSQL_OK;

    fractal_config_env_lock();
    if (!embed_env_save(saved)) {
        /* The operator's environment could not be captured, so the
         * bracket cannot be opened: publishing the embed tier's values
         * now would overwrite values that were not saved and could not
         * be put back. Nothing has been published yet (the save runs
         * first), so the caller's embed_env_close frees the copies it
         * did take and leaves the environment exactly as it stands. */
        fractal_config_env_unlock();
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: out of memory saving the operator's environment");
        return false;
    }
    apply_embed_env_locked();
    fractal_config_apply_env_overrides(session_id, FSQL_CFG_TIER_EMBED);
    fp = fractal_config_env_fingerprint();
    if (!g_embed_fp_valid || fp != g_embed_fp) {
        rc = checked_load_reasoning(ctx);
        if (rc == FSQL_OK) {
            g_embed_fp = fractal_config_env_fingerprint();
            g_embed_fp_valid = true;
        }
    }
    fractal_config_env_unlock();
    if (rc != FSQL_OK) {
        const char *err = g_plugin_verr[0] ? g_plugin_verr : fsql_last_error(ctx);
        char detail[SFS_DETAIL_MAX + sizeof SFS_DETAIL_MARK];
        sfs_detail_bounded(err && *err ? err : "(no detail)",
                           detail, sizeof detail);
        SFS_INIT_ERROR(errbuf, "fractal_embed: failed to load reasoning plugin (rc=%d): %s",
                       rc, detail);
        return false;
    }
    return true;
}

/* Closes the bracket embed_env_open opened: the operator's bridge
 * values go back into the environment, and the saved copies are freed. */
static void
embed_env_close(char **saved)
{
    embed_env_restore(saved);
}

/* Load the reasoning plugin into `ctx` if not already loaded (per
 * `already_loaded`, from fractal_session_acquire_reason/_embed's
 * *out_loaded), then mark it loaded in the registry on success.
 * *out_endpoint_failure (may be NULL) distinguishes the two failure
 * classes for partial-result mode: false = no reasoning plugin is configured (a
 * setup mistake, always a plain failure), true = the plugin's load
 * round trip failed (transient/endpoint-class, eligible for the
 * session's partial-result honesty mode). This function is
 * fractal_reason's only loader; fractal_embed and the text-to-sql
 * tiers have their own ensure_* twins with different config keys.
 *
 * An already-loaded tier is NOT reloaded here: the dispatch path
 * re-checks the configuration fingerprint for every call, so a tier
 * that was loaded for a different session's configuration is brought
 * up to date there. */
static bool
ensure_reason_loaded(unsigned long long session_id, fsql_ctx *ctx,
                     bool already_loaded, char *errbuf,
                     bool *out_endpoint_failure)
{
    if (out_endpoint_failure) *out_endpoint_failure = false;
    if (already_loaded) return true;
    if (!ensure_env_config(errbuf)) return false;
    /* The plugin path is read UNDER the load lock: apply_provider frees
     * the old copy before installing the new one, so an unlocked read of
     * the pointer races that free (a stale non-NULL value would send the
     * dispatch down the "plugin configured" path when the config says
     * otherwise). The value is only tested here -- the dispatch that
     * actually uses it re-reads the config under the lock. */
    {
        bool no_plugin;
        load_lock();
        no_plugin = (g_cfg.reasoning_plugin == NULL);
        load_unlock();
        if (no_plugin) {
            SFS_INIT_ERROR(errbuf,
                "fractal_reason: no reasoning plugin configured. Set reasoning_plugin "
                "in fractalsqld.conf and run `fsqlctl reload`, or set "
                "FRACTALSQL_REASONING_PLUGIN in fractalsqld's environment at startup");
            return false;
        }
    }
    load_lock();
    if (!reason_env_and_reload(ctx, session_id, errbuf)) {
        load_unlock();
        if (out_endpoint_failure) *out_endpoint_failure = true;
        return false;
    }
    load_unlock();
    fractal_session_mark_reason_loaded(session_id);
    return true;
}

static bool
ensure_embed_loaded(unsigned long long session_id, fsql_ctx *ctx,
                    bool already_loaded, char *errbuf)
{
    if (already_loaded) return true;
    if (!ensure_env_config(errbuf)) return false;
    /* Both strings are read UNDER the load lock -- see
     * ensure_reason_loaded's note on why an unlocked read of the config
     * pointers races apply_provider's free. */
    {
        bool no_plugin, no_embed_url;
        load_lock();
        no_plugin    = (g_cfg.reasoning_plugin == NULL);
        no_embed_url = (g_cfg.http_embed_url == NULL);
        load_unlock();
        if (no_plugin) {
            SFS_INIT_ERROR(errbuf,
                "fractal_embed: no reasoning plugin configured. Set reasoning_plugin "
                "in fractalsqld.conf and run `fsqlctl reload`, or set "
                "FRACTALSQL_REASONING_PLUGIN in fractalsqld's environment at startup");
            return false;
        }
        if (no_embed_url) {
            SFS_INIT_ERROR(errbuf,
                "fractal_embed: no embeddings endpoint configured. Set embed_url "
                "in fractalsqld.conf and run `fsqlctl reload`, or set "
                "FRACTALSQL_HTTP_EMBED_URL in fractalsqld's environment at startup");
            return false;
        }
    }
    load_lock();
    {
        /* The load-only bracket: the instance is brought up with the
         * embed tier's environment in place, and the operator's values
         * go straight back afterwards. There is no dispatch inside this
         * window, so the bracket closes here. */
        char *saved[N_BRIDGE_VARS];
        bool ok = embed_env_open(ctx, session_id, saved, errbuf);
        embed_env_close(saved);
        if (!ok) {
            load_unlock();
            return false;
        }
    }
    load_unlock();
    fractal_session_mark_embed_loaded(session_id);
    return true;
}

/* ==================================================================== */
/* UDF triad: fractal_reason(session_id, query [, context]) -> TEXT      */
/*                                                                      */
/* On an ENDPOINT-class failure (the reasoning plugin's own load or     */
/* dispatch round trip, or a contract-violating response) with the       */
/* session's partial-result mode on (fractal_agent_partial_fail),     */
/* this returns {"reasoning_step_failed":"<detail>"} instead of a       */
/* silent NULL: that document is the agent procedures' only channel     */
/* for the plugin's detail (MySQL's UDF ABI has no error-message text   */
/* for *error = 1), so they NULL the sentinel out of the composed       */
/* field and surface it as the sibling "reasoning_step_failed" key.     */
/* Standalone callers should treat the sentinel as the failure it is.   */
/* Not-configured and the arg/session-acquire/OOM paths below are       */
/* setup mistakes and stay hard failures in both modes.                 */
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

    /* Partial-result mode: only the endpoint classes (load round trip, dispatch,
     * contract-violating response) consult the session's partial flag;
     * not-configured and the setup paths below stay hard errors. */
    {
        bool endpoint_failure = false;
        if (!ensure_reason_loaded(sid, ctx, loaded, errbuf, &endpoint_failure)) {
            fractal_session_release_tier();
            if (endpoint_failure)
                return agent_partial_or_error(sid, so, errbuf, length,
                                              is_null, error);
            *error = 1; return NULL;
        }
    }

    memset(&resp, 0, sizeof(resp));
    /* The plugin's configuration is baked in when the instance is
     * loaded, so every dispatch republishes the tier's settings (plus
     * this session's own overrides) and reloads the instance if that
     * configuration is not the one the instance was loaded with. */
    load_lock();
    if (!reason_env_and_reload(ctx, sid, errbuf)) {
        load_unlock();
        fractal_session_release_tier();
        return agent_partial_or_error(sid, so, errbuf, length,
                                      is_null, error);
    }
    rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1],
                          ctx_json, ctx_json_len, &resp);
    load_unlock();
    if (rc != FSQL_OK || resp.rc != 0) {
        const char *err = fsql_last_error(ctx);
        char detail[SFS_DETAIL_MAX + sizeof SFS_DETAIL_MARK];
        sfs_detail_bounded(err && *err ? err : "(no detail)",
                           detail, sizeof detail);
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: dispatch failed (rc=%d, resp.rc=%d): %s",
            rc, resp.rc, detail);
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
        return agent_partial_or_error(sid, so, errbuf, length,
                                      is_null, error);
    }
    if (resp.summary_len > FRACTAL_MAX_AI_RESPONSE_BYTES) {
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: response of %zu bytes exceeds the %zu-byte cap",
            resp.summary_len, (size_t) FRACTAL_MAX_AI_RESPONSE_BYTES);
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
        return agent_partial_or_error(sid, so, errbuf, length,
                                      is_null, error);
    }
    /* The rc==0 dispatch contract says summary is non-NULL, but the
     * copy below would crash on a contract-violating plugin -- a
     * plugin bug gets a clean error, not a segfault. */
    if (resp.summary == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_reason: reasoning plugin returned a NULL summary on a "
            "success status -- likely a plugin bug");
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
        return agent_partial_or_error(sid, so, errbuf, length,
                                      is_null, error);
    }

    if (!str_out_ensure(so, resp.summary_len + 1)) {
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
        *error = 1; return NULL;
    }
    memcpy(so->buf, resp.summary, resp.summary_len);
    so->buf[resp.summary_len] = '\0';
    *length = (unsigned long) resp.summary_len;

    fsql_ai_response_free(&resp);
    fractal_session_release_tier();
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
        fractal_session_release_tier();
        *error = 1; return NULL;
    }

    memset(&resp, 0, sizeof(resp));
    /* context_json is accepted by fsql_dispatch_ai's signature but
     * ignored entirely by the plugin in embedding mode: "{}", the same
     * as fractal_reason's own default. */
    {
        char *saved[N_BRIDGE_VARS];
        load_lock();
        /* Same shape as the reason tier: republish the tier's settings
         * plus this session's own overrides, and reload the instance
         * if that is not the configuration it was loaded with. Only
         * the EMBED tier's keys apply here: the embed tier publishes
         * its model on the same bridge variable the reason tier does,
         * so the tier mask keeps a session's reasoning_model out of
         * the embedding request (and the other way round).
         *
         * The bracket stays OPEN across the dispatch: the embed tier's
         * environment (no THINK, embedding mode) has to be the one in
         * place while the request is in flight, or a plugin that reads
         * its configuration at dispatch time would see the chat tier's
         * settings instead. */
        if (!embed_env_open(ctx, sid, saved, errbuf)) {
            embed_env_close(saved);
            load_unlock();
            fractal_session_release_tier();
            *error = 1; return NULL;
        }
        rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1], "{}", 2, &resp);
        embed_env_close(saved);
        load_unlock();
    }
    if (rc != FSQL_OK || resp.rc != 0) {
        const char *err = fsql_last_error(ctx);
        char detail[SFS_DETAIL_MAX + sizeof SFS_DETAIL_MARK];
        sfs_detail_bounded(err && *err ? err : "(no detail)",
                           detail, sizeof detail);
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: dispatch failed (rc=%d, resp.rc=%d): %s",
            rc, resp.rc, detail);
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
        *error = 1; return NULL;
    }
    if (resp.summary_len > FRACTAL_MAX_AI_RESPONSE_BYTES) {
        SFS_INIT_ERROR(errbuf,
            "fractal_embed: response of %zu bytes exceeds the %zu-byte cap",
            resp.summary_len, (size_t) FRACTAL_MAX_AI_RESPONSE_BYTES);
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
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
        fractal_session_release_tier();
        *error = 1; return NULL;
    }

    /* parse_vector_csv takes an explicit length, not requiring NUL
     * termination, so resp.summary can be handed to it directly, no
     * copy needed (mirrors fractal_vector_dims's own direct-parse of
     * args->args[0]/args->lengths[0]). */
    if (!parse_vector_csv(resp.summary, resp.summary_len, &dv, &n, errbuf)) {
        fsql_ai_response_free(&resp);
        fractal_session_release_tier();
        *error = 1; return NULL;
    }
    fsql_ai_response_free(&resp);

    if (n == 0 || n > FRACTAL_MAX_EMBED_DIM) {
        free(dv);
        fractal_session_release_tier();
        *error = 1; return NULL;
    }
    fv = malloc(n * sizeof(float));
    if (fv == NULL) {
        free(dv);
        fractal_session_release_tier();
        *error = 1; return NULL;
    }
    for (size_t i = 0; i < n; i++) fv[i] = (float) dv[i];
    free(dv);

    s = format_vector_json(so, fv, n, length);
    free(fv);
    fractal_session_release_tier();
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}
