/* src/fractalsql_textsql.c
 * Text-to-SQL C UDF layer: fractal_t2s_generate, fractal_t2s_review,
 * fractal_t2s_check_allowlist, and fractal_t2s_config.
 *
 * Architecture note: validating and running a generated SQL candidate
 * (EXPLAIN, catalog introspection) needs to run under the calling
 * role's own privileges. Plain MariaDB UDFs have no way to do that: the
 * UDF ABI (UDF_INIT/UDF_ARGS) gives a C function no handle back to
 * the connection that called it, so it cannot run SQL against that
 * session at all.
 *
 * fractal_text_to_sql and fractal_schema_context are therefore
 * implemented as SQL SECURITY INVOKER stored procedures
 * (sql/install_udf.sql), not C UDFs. They are called via CALL, not
 * SELECT, which is a deliberate departure from every other function
 * in this repo. SQL SECURITY INVOKER makes their PREPARE/EXPLAIN and
 * information_schema queries run under the calling user's own grants.
 * The alternative, a C UDF opening a second, separately credentialed
 * loopback connection back to the server, would run those queries
 * under a different set of grants than the caller's own: a
 * privilege-model mismatch for a feature whose entire point is being
 * safety-gated.
 *
 * This file supplies the pieces that genuinely need C: the LLM
 * dispatch itself (fractal_t2s_generate, fractal_t2s_review) and pure
 * text/lexical validation with no database access
 * (fractal_t2s_check_allowlist). The orchestrating retry loop, the
 * EXPLAIN-equivalent mechanical check (PREPARE/DEALLOCATE PREPARE;
 * see the stored procedure's own comment for why PREPARE-only, never
 * EXECUTE), and all information_schema introspection live in SQL/PSM
 * in sql/install_udf.sql, where they naturally inherit the caller's
 * privileges for free.
 *
 * Configuration is a set of process environment variables, read once
 * at startup and cached for the life of the mariadbd process (the
 * same convention used throughout this repo; see
 * fractalsql_cognition.c's file header for why this is process
 * environment rather than a my.cnf sysvar):
 *   FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS        int, default 2
 *   FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS  "select" (default) |
 *                                               "select_insert_update"
 *   FRACTALSQL_TEXT_TO_SQL_USE_REVIEW          "1" to enable, default off
 * fractal_t2s_config() exposes these as one JSON object so the
 * orchestrating stored procedure, which has no builtin to read
 * process environment variables, can read them once per CALL.
 *
 * Plain MariaDB UDFs have no backend parser to call into for a real
 * parse-tree inspection (see the architecture note above), so
 * fractal_t2s_check_allowlist below is a hand-written,
 * quote/comment/paren-aware lexical scanner. It classifies the
 * statement's leading keyword (skipping past any WITH-clause CTE
 * definitions first), rejects more than one top-level statement, and
 * rejects a disallowed statement type. Two things this needed to get
 * right, verified against MariaDB's own grammar:
 *
 *   1. MariaDB's WITH clause is SELECT-only at the CTE-body level.
 *      "WITH d AS (DELETE FROM t ...) SELECT ..." is not valid
 *      MariaDB syntax (a CTE body must be a query, not a DML
 *      statement), so a data-modifying CTE hiding behind a top-level
 *      SELECT is not a hazard this scanner needs to guard against.
 *      (A CTE can still feed a top-level DML statement, e.g. "WITH
 *      cte AS (SELECT ...) DELETE FROM t WHERE id IN (SELECT id FROM
 *      cte)". That is exactly what the WITH-clause skip below is for:
 *      finding the real leading keyword after the CTE definitions,
 *      which in that example is DELETE and gets correctly rejected in
 *      "select" mode.)
 *   2. "SELECT ... INTO OUTFILE/DUMPFILE" is syntactically a SELECT
 *      (it passes any leading-keyword classification as read-only)
 *      but writes arbitrary content to the filesystem under mysqld's
 *      privileges. It is rejected unconditionally, in every
 *      allowed_statements mode, by a whole-statement scan for INTO
 *      OUTFILE/DUMPFILE.
 *
 * Known limitation, documented rather than silently ignored: this
 * scanner assumes the default sql_mode (backslash escapes on) when
 * skipping quoted strings. Under NO_BACKSLASH_ESCAPES it may mis-scan
 * a quoted literal containing a trailing backslash. The failure
 * direction is always toward over-rejecting (treating well-formed SQL
 * as ambiguous and asking the GENERATE step to retry), never toward
 * missing a real statement-shape violation, so this is an
 * availability cost, not a safety gap.
 */

#include <mysql.h>

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql.h"          /* FSQL_OK, fsql_last_error */
#include "fractalsql_sql.h"      /* fsql_ctx, fsql_dispatch_ai, fsql_load_reasoning */
#include "fractalsql_session.h"  /* fractal_session_acquire_reason/_t2s, ... */
#include "fractalsql_msvc_compat.h"  /* setenv/unsetenv on MSVC */

#if defined(_WIN32) || defined(__CYGWIN__)
#  include <windows.h>
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  include <pthread.h>
#  define FRACTAL_EXPORT
#endif

/* Same stderr-mirroring SFS_INIT_ERROR as fractalsql_cognition.c
 * (duplicated per translation unit by this repo's established
 * precedent): on the UDF runtime path the formatted buffer would
 * otherwise be dropped, surfacing failures as bare NULLs. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* Same DoS-guard reasoning as fractalsql_cognition.c's
 * FRACTAL_COGNITION_MAX_INPUT_BYTES: caller-controlled text drives
 * both an allocation and an outbound HTTP request body. */
#define FRACTAL_T2S_MAX_INPUT_BYTES ((unsigned long) 4u * 1024u * 1024u) /* 4 MiB */
#define FRACTAL_T2S_MAX_SQL_BYTES   ((unsigned long) 256u * 1024u)       /* 256 KiB, sized for a single generated statement */

/* Same bound/rationale as fractalsql_cognition.c's
 * FRACTAL_MAX_AI_RESPONSE_BYTES. */
#define FRACTAL_MAX_AI_RESPONSE_BYTES ((size_t) 16u * 1024u * 1024u) /* 16 MiB */

/* ------------------------------------------------------------------ */
/* Growable output buffer. Duplicated per translation unit, following  */
/* this repo's established precedent (see fractalsql_cognition.c's    */
/* identical comment on str_out_ctx).                                  */
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
str_out_generic_init(UDF_INIT *initid, char *message, unsigned long max_length)
{
    str_out_ctx *so = calloc(1, sizeof(*so));
    if (so == NULL) {
        SFS_INIT_ERROR(message, "fractal_t2s: out of memory");
        return true;
    }
    initid->ptr        = (char *) so;
    initid->maybe_null = 1;
    initid->max_length = max_length;
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

static char *
str_out_set(str_out_ctx *so, const char *text, size_t len, unsigned long *out_len)
{
    if (!str_out_ensure(so, len + 1)) return NULL;
    memcpy(so->buf, text, len);
    so->buf[len] = '\0';
    *out_len = (unsigned long) len;
    return so->buf;
}

/* ------------------------------------------------------------------ */
/* Portable lock and once-init shim. See fractalsql_session.c's        */
/* identical comment; duplicated per translation unit by this repo's   */
/* established precedent rather than shared.                           */
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
/* Environment-variable config. Read once and cached for the process   */
/* lifetime.                                                            */
/* ------------------------------------------------------------------ */
typedef struct {
    char *reasoning_plugin;
    char *http_url;
    char *http_token;
    char *http_model;
    bool  http_allow_plaintext;
    int   max_attempts;
    char  allowed_statements[24];   /* "select" | "select_insert_update" */
    bool  use_review;
    char *http_think;
    char *http_think_provider;
    char *http_native_url;
    char *http_num_ctx;
} t2s_config;

static t2s_config g_cfg;

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
    const char *plain, *max_att, *allowed, *review;

    /* Reasoning plugin path/HTTP config is shared with
     * fractalsql_cognition.c's own FRACTALSQL_* vars: same plugin,
     * same endpoint, just a third dispatch purpose. Re-reading the
     * environment here, rather than sharing it across translation
     * units, matches this repo's convention of each source file
     * owning its own config (see that file's own env loader). */
    g_cfg.reasoning_plugin = dup_env("FRACTALSQL_REASONING_PLUGIN");
    g_cfg.http_url         = dup_env("FRACTALSQL_HTTP_URL");
    g_cfg.http_token       = dup_env("FRACTALSQL_HTTP_TOKEN");
    g_cfg.http_model       = dup_env("FRACTALSQL_HTTP_MODEL");
    plain = getenv("FRACTALSQL_HTTP_ALLOW_PLAINTEXT");
    g_cfg.http_allow_plaintext = (plain && *plain && strcmp(plain, "0") != 0);
    g_cfg.http_think          = dup_env("FRACTALSQL_HTTP_THINK");
    g_cfg.http_think_provider = dup_env("FRACTALSQL_HTTP_THINK_PROVIDER");
    g_cfg.http_native_url     = dup_env("FRACTALSQL_HTTP_NATIVE_URL");
    g_cfg.http_num_ctx        = dup_env("FRACTALSQL_HTTP_NUM_CTX");

    max_att = getenv("FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS");
    g_cfg.max_attempts = 2;
    if (max_att && *max_att) {
        int v = atoi(max_att);
        if (v >= 1 && v <= 10) g_cfg.max_attempts = v;
    }

    allowed = getenv("FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS");
    if (allowed && strcmp(allowed, "select_insert_update") == 0)
        snprintf(g_cfg.allowed_statements, sizeof g_cfg.allowed_statements, "select_insert_update");
    else
        snprintf(g_cfg.allowed_statements, sizeof g_cfg.allowed_statements, "select");

    review = getenv("FRACTALSQL_TEXT_TO_SQL_USE_REVIEW");
    g_cfg.use_review = (review && *review && strcmp(review, "0") != 0);
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

/* ==================================================================== */
/* fractal_t2s_config() -> JSON STRING                                  */
/* {"max_attempts":2,"allowed_statements":"select","use_review":false}  */
/* Lets the orchestrating stored procedure (sql/install_udf.sql) read   */
/* this file's env-var config once per CALL, since SQL/PSM has no       */
/* built-in mechanism to read process environment variables directly.  */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_t2s_config_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 0) {
        SFS_INIT_ERROR(message, "fractal_t2s_config(): expected 0 arguments, got %u", args->arg_count);
        return true;
    }
    return str_out_generic_init(initid, message, 256);
}

FRACTAL_EXPORT void
fractal_t2s_config_deinit(UDF_INIT *initid) { str_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_t2s_config(UDF_INIT *initid, UDF_ARGS *args, char *result,
                   unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    char buf[256];
    int  n;
    (void) args; (void) result;

    ensure_env_config();

    n = snprintf(buf, sizeof buf,
                 "{\"max_attempts\":%d,\"allowed_statements\":\"%s\",\"use_review\":%s}",
                 g_cfg.max_attempts, g_cfg.allowed_statements,
                 g_cfg.use_review ? "true" : "false");
    if (n < 0 || (size_t) n >= sizeof buf) { *error = 1; return NULL; }

    char *s = str_out_set(so, buf, (size_t) n, length);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ==================================================================== */
/* Reasoning ctx bridge. See fractalsql_cognition.c's file header for   */
/* the full setenv() race rationale; this is the same pattern for a     */
/* third dispatch purpose (GENERATE, RESPONSE_MODE=code).               */
/* ==================================================================== */

/* "generate" mode: chat completions, RESPONSE_MODE=code so the
 * plugin's fenced-block extraction pulls the SQL out of the model's
 * ```sql ... ``` response. system_tag is caller-supplied (the
 * orchestrating procedure derives it from VERSION(), e.g.
 * "mariadb1011") rather than computed here, since a plain UDF has no
 * access to the connected server's version the way a live SQL
 * session does. Caller MUST hold g_load_lock. */
static void
apply_generate_env_locked(const char *system_tag)
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
    setenv("FSQL_REASONING_HTTP_RESPONSE_MODE", "code", 1);
    if (system_tag && *system_tag)
        setenv("FSQL_REASONING_HTTP_SYSTEM_TAG", system_tag, 1);
    else
        unsetenv("FSQL_REASONING_HTTP_SYSTEM_TAG");
}

/* "review" mode: plain chat, no RESPONSE_MODE override. Shares
 * fractal_reason()'s own ctx-loading shape (see
 * fractalsql_cognition.c's apply_reason_env_locked), used via the
 * REASON ctx slot, not the GENERATE one, because a code-mode extractor
 * would risk pulling a quoted SQL fragment out of the review's
 * PASS/FAIL explanation instead of returning the verdict text itself.
 * Caller MUST hold g_load_lock. */
static void
apply_review_env_locked(void)
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

static bool
ensure_generate_loaded(unsigned long long session_id, fsql_ctx *ctx,
                       bool already_loaded, const char *system_tag, char *errbuf)
{
    int rc;
    if (already_loaded) return true;
    ensure_env_config();
    if (!g_cfg.reasoning_plugin) {
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_generate: no reasoning plugin configured, set "
            "FRACTALSQL_REASONING_PLUGIN in mysqld's environment and restart");
        return false;
    }
    load_lock();
    apply_generate_env_locked(system_tag);
    rc = fsql_load_reasoning(ctx, g_cfg.reasoning_plugin);
    load_unlock();
    if (rc != FSQL_OK) {
        const char *err = fsql_last_error(ctx);
        SFS_INIT_ERROR(errbuf, "fractal_t2s_generate: failed to load reasoning plugin (rc=%d): %s",
                       rc, err && *err ? err : "(no detail)");
        return false;
    }
    fractal_session_mark_t2s_loaded(session_id);
    return true;
}

static bool
ensure_review_loaded(unsigned long long session_id, fsql_ctx *ctx,
                     bool already_loaded, char *errbuf)
{
    int rc;
    if (already_loaded) return true;
    ensure_env_config();
    if (!g_cfg.reasoning_plugin) {
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_review: no reasoning plugin configured, set "
            "FRACTALSQL_REASONING_PLUGIN in mysqld's environment and restart");
        return false;
    }
    load_lock();
    apply_review_env_locked();
    rc = fsql_load_reasoning(ctx, g_cfg.reasoning_plugin);
    load_unlock();
    if (rc != FSQL_OK) {
        const char *err = fsql_last_error(ctx);
        SFS_INIT_ERROR(errbuf, "fractal_t2s_review: failed to load reasoning plugin (rc=%d): %s",
                       rc, err && *err ? err : "(no detail)");
        return false;
    }
    fractal_session_mark_reason_loaded(session_id);
    return true;
}

/* ==================================================================== */
/* fractal_t2s_generate(session_id, prompt, context_text, system_tag)   */
/*   -> TEXT (candidate SQL, code-mode-extracted)                       */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_t2s_generate_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 4) {
        SFS_INIT_ERROR(message,
            "fractal_t2s_generate(session_id, prompt, context_text, system_tag): "
            "expected 4 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = STRING_RESULT;
    args->arg_type[3] = STRING_RESULT;
    return str_out_generic_init(initid, message, FRACTAL_MAX_AI_RESPONSE_BYTES);
}

FRACTAL_EXPORT void
fractal_t2s_generate_deinit(UDF_INIT *initid) { str_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_t2s_generate(UDF_INIT *initid, UDF_ARGS *args, char *result,
                     unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    unsigned long long sid;
    const char *context_json; unsigned long context_len;
    const char *system_tag;
    bool    loaded = false;
    fsql_ctx *ctx;
    fsql_ai_response_t resp;
    int     rc;
    char   *s;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[1] > FRACTAL_T2S_MAX_INPUT_BYTES) { *error = 1; return NULL; }

    if (args->args[2] != NULL) {
        if (args->lengths[2] > FRACTAL_T2S_MAX_INPUT_BYTES) { *error = 1; return NULL; }
        context_json = args->args[2];
        context_len  = args->lengths[2];
    } else {
        context_json = "{}";
        context_len  = 2;
    }
    /* Copy with the ABI-given length and NUL-terminate: the UDF ABI does
     * not terminate string arguments (the same fact the session/ctx
     * comment below concedes for args[1]/[2]), and a raw pointer here
     * would let setenv()'s strlen run off the end of the record buffer. */
    char system_tag_buf[64];
    if (args->args[3] != NULL && args->lengths[3] > 0) {
        if (args->lengths[3] >= sizeof system_tag_buf) {
            *error = 1; return NULL;
        }
        memcpy(system_tag_buf, args->args[3], args->lengths[3]);
        system_tag_buf[args->lengths[3]] = '\0';
        system_tag = system_tag_buf;
    } else {
        system_tag = NULL;   /* ensure_generate_loaded tolerates it */
    }

    sid = (unsigned long long) *(long long *) args->args[0];

    ctx = fractal_session_acquire_t2s(sid, &loaded);
    if (ctx == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_generate: session acquire failed for id %llu", sid);
        *error = 1; return NULL;
    }

    if (!ensure_generate_loaded(sid, ctx, loaded, system_tag, errbuf)) {
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    memset(&resp, 0, sizeof(resp));
    rc = fsql_dispatch_ai(ctx, args->args[1], args->lengths[1],
                          context_json, context_len, &resp);
    if (rc != FSQL_OK || resp.rc != 0) {
        const char *err = fsql_last_error(ctx);
        /* Mirrored to stderr via SFS_INIT_ERROR: a plain *error=1 here
         * surfaces only as the orchestrating procedure's generic
         * "generate dispatch failed" NULL, hiding the plugin's actual
         * reason (e.g. code-mode fence extraction failure). */
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_generate: dispatch failed (rc=%d, resp.rc=%d): %s",
            rc, resp.rc, err && *err ? err : "(no detail)");
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    if (resp.summary_len > FRACTAL_MAX_AI_RESPONSE_BYTES) {
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_generate: response %zu bytes exceeds "
            "FRACTAL_MAX_AI_RESPONSE_BYTES", resp.summary_len);
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    s = str_out_set(so, resp.summary, resp.summary_len, length);
    fsql_ai_response_free(&resp);
    fractal_session_release(sid);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ==================================================================== */
/* fractal_t2s_review(session_id, question, candidate_sql)              */
/*   -> TEXT (NULL = PASS, else the model's critique, which feeds       */
/*      straight back into the next GENERATE attempt as retry feedback, */
/*      the same NULL-means-pass convention as                         */
/*      fractal_t2s_check_allowlist)                                    */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_t2s_review_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_t2s_review(session_id, question, candidate_sql): "
            "expected 3 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = STRING_RESULT;
    return str_out_generic_init(initid, message, FRACTAL_MAX_AI_RESPONSE_BYTES);
}

FRACTAL_EXPORT void
fractal_t2s_review_deinit(UDF_INIT *initid) { str_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_t2s_review(UDF_INIT *initid, UDF_ARGS *args, char *result,
                   unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    unsigned long long sid;
    bool    loaded = false;
    fsql_ctx *ctx;
    fsql_ai_response_t resp;
    int     rc;
    char    prompt[8192];
    int     n;
    const char *p;
    size_t  plen;
    bool    passed;
    char   *s;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[1] > FRACTAL_T2S_MAX_INPUT_BYTES ||
        args->lengths[2] > FRACTAL_T2S_MAX_SQL_BYTES) { *error = 1; return NULL; }

    sid = (unsigned long long) *(long long *) args->args[0];

    ctx = fractal_session_acquire_reason(sid, &loaded);
    if (ctx == NULL) {
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_review: session acquire failed for id %llu", sid);
        *error = 1; return NULL;
    }

    if (!ensure_review_loaded(sid, ctx, loaded, errbuf)) {
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    /* args->args[1]/[2] are not guaranteed NUL-terminated by the UDF
     * ABI; %.*s bounds both by their explicit lengths. Truncating a
     * pathologically long question/candidate into this fixed prompt
     * buffer is acceptable here: review is an optional quality pass
     * (default off), not a security boundary. */
    n = snprintf(prompt, sizeof prompt,
        "Original request: %.*s\n\n"
        "Candidate SQL:\n%.*s\n\n"
        "Does this candidate correctly and completely answer the request? "
        "Answer PASS or FAIL on the first line, then explain briefly.",
        (int) args->lengths[1], args->args[1],
        (int) args->lengths[2], args->args[2]);
    if (n < 0) { fractal_session_release(sid); *error = 1; return NULL; }
    plen = (size_t) n < sizeof prompt ? (size_t) n : sizeof prompt - 1;

    memset(&resp, 0, sizeof(resp));
    rc = fsql_dispatch_ai(ctx, prompt, plen, "{}", 2, &resp);
    if (rc != FSQL_OK || resp.rc != 0) {
        const char *err = fsql_last_error(ctx);
        /* Same stderr mirror as fractal_t2s_generate's dispatch branch:
         * a bare *error=1 would only ever show as a NULL review verdict. */
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_review: dispatch failed (rc=%d, resp.rc=%d): %s",
            rc, resp.rc, err && *err ? err : "(no detail)");
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }
    if (resp.summary_len > FRACTAL_MAX_AI_RESPONSE_BYTES) {
        SFS_INIT_ERROR(errbuf,
            "fractal_t2s_review: response %zu bytes exceeds "
            "FRACTAL_MAX_AI_RESPONSE_BYTES", resp.summary_len);
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *error = 1; return NULL;
    }

    p = resp.summary;
    size_t rem = resp.summary_len;
    while (rem > 0 && isspace((unsigned char) *p)) { p++; rem--; }
    passed = (rem >= 4 &&
              tolower((unsigned char) p[0]) == 'p' && tolower((unsigned char) p[1]) == 'a' &&
              tolower((unsigned char) p[2]) == 's' && tolower((unsigned char) p[3]) == 's');

    if (passed) {
        fsql_ai_response_free(&resp);
        fractal_session_release(sid);
        *is_null = 1;
        return NULL;
    }

    s = str_out_set(so, resp.summary, resp.summary_len, length);
    fsql_ai_response_free(&resp);
    fractal_session_release(sid);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ==================================================================== */
/* fractal_t2s_check_allowlist(sql) -> TEXT                             */
/*   NULL = passes; else a human-readable rejection reason, suitable    */
/*   to feed straight back into the next GENERATE attempt as feedback.  */
/*   Pure text/lexical validation: no database access, no LLM call.     */
/*   See this file's own header comment for the full MariaDB-dialect    */
/*   design rationale (WITH-clause skip, INTO OUTFILE/DUMPFILE gate).   */
/* ==================================================================== */

typedef struct { const char *s; size_t len; size_t pos; } t2s_scan;

static bool
t2s_is_ident_char(unsigned char c) { return isalnum(c) || c == '_' || c == '$'; }

/* Skips whitespace and every MariaDB comment form (--<ws>, #, block
 * comments) at the current position, repeatedly, until none remain. */
static void
t2s_skip_ws_comments(t2s_scan *sc)
{
    bool moved = true;
    while (moved && sc->pos < sc->len) {
        moved = false;
        while (sc->pos < sc->len && isspace((unsigned char) sc->s[sc->pos])) { sc->pos++; moved = true; }
        if (sc->pos + 1 < sc->len && sc->s[sc->pos] == '-' && sc->s[sc->pos + 1] == '-' &&
            (sc->pos + 2 >= sc->len || isspace((unsigned char) sc->s[sc->pos + 2]))) {
            while (sc->pos < sc->len && sc->s[sc->pos] != '\n') sc->pos++;
            moved = true;
        } else if (sc->pos < sc->len && sc->s[sc->pos] == '#') {
            while (sc->pos < sc->len && sc->s[sc->pos] != '\n') sc->pos++;
            moved = true;
        } else if (sc->pos + 1 < sc->len && sc->s[sc->pos] == '/' && sc->s[sc->pos + 1] == '*') {
            sc->pos += 2;
            while (sc->pos + 1 < sc->len && !(sc->s[sc->pos] == '*' && sc->s[sc->pos + 1] == '/'))
                sc->pos++;
            sc->pos = (sc->pos + 1 < sc->len) ? sc->pos + 2 : sc->len;
            moved = true;
        }
    }
}

/* sc->s[sc->pos] must be a quote char ('\'', '"', or '`') on entry.
 * Advances past the matching close, handling backslash-escapes
 * (single/double-quoted only, see this file's NO_BACKSLASH_ESCAPES
 * limitation note) and doubled-quote escapes (all three quote kinds). */
static void
t2s_skip_quoted(t2s_scan *sc)
{
    char q = sc->s[sc->pos];
    sc->pos++;
    while (sc->pos < sc->len) {
        char c = sc->s[sc->pos];
        if (c == '\\' && q != '`' && sc->pos + 1 < sc->len) { sc->pos += 2; continue; }
        if (c == q) {
            if (sc->pos + 1 < sc->len && sc->s[sc->pos + 1] == q) { sc->pos += 2; continue; }
            sc->pos++;
            return;
        }
        sc->pos++;
    }
}

/* Case-insensitive keyword match at the current position, requiring a
 * non-identifier char (or end of input) immediately after: a real
 * word-boundary match, not a prefix match ("SELECTOR" must not match
 * "SELECT"). Advances past the keyword on success; does not skip
 * trailing whitespace (caller's job). */
static bool
t2s_match_kw(t2s_scan *sc, const char *kw)
{
    size_t klen = strlen(kw);
    if (sc->pos + klen > sc->len) return false;
    for (size_t i = 0; i < klen; i++)
        if (tolower((unsigned char) sc->s[sc->pos + i]) != tolower((unsigned char) kw[i]))
            return false;
    if (sc->pos + klen < sc->len && t2s_is_ident_char((unsigned char) sc->s[sc->pos + klen]))
        return false;
    sc->pos += klen;
    return true;
}

/* sc->s[sc->pos] must be '(' on entry. Advances past the matching
 * close paren (quote-aware, so a ')' inside a string literal doesn't
 * miscount). Returns false if the parens never balance before EOF. */
static bool
t2s_skip_paren_balanced(t2s_scan *sc)
{
    int depth = 0;
    while (sc->pos < sc->len) {
        char c = sc->s[sc->pos];
        if (c == '\'' || c == '"' || c == '`') { t2s_skip_quoted(sc); continue; }
        if (c == '(') { depth++; sc->pos++; continue; }
        if (c == ')') { depth--; sc->pos++; if (depth == 0) return true; continue; }
        sc->pos++;
    }
    return false;
}

/* Counts top-level (paren-depth-0, outside quotes/comments) SQL
 * statements in `sql`, i.e. semicolon-separated chunks that contain
 * at least one non-whitespace, non-comment token. A single statement
 * with a harmless trailing semicolon (and/or trailing whitespace/
 * comments) still counts as 1, matching how a normal SQL client would
 * treat it. This must NOT reject the common case of a generated
 * statement ending in ";". */
static int
t2s_count_statements(const char *sql, size_t len)
{
    t2s_scan sc = { sql, len, 0 };
    int  n_stmts = 0;
    bool any_content = false;

    while (sc.pos < sc.len) {
        char c = sc.s[sc.pos];
        if (c == '\'' || c == '"' || c == '`') { t2s_skip_quoted(&sc); any_content = true; continue; }
        if (c == '(' || c == ')') { sc.pos++; any_content = true; continue; }
        if (c == ';') {
            sc.pos++;
            if (any_content) n_stmts++;
            any_content = false;
            continue;
        }
        if (isspace((unsigned char) c)) { sc.pos++; continue; }
        if ((c == '-' && sc.pos + 1 < sc.len && sc.s[sc.pos + 1] == '-') ||
            c == '#' ||
            (c == '/' && sc.pos + 1 < sc.len && sc.s[sc.pos + 1] == '*')) {
            size_t before = sc.pos;
            t2s_skip_ws_comments(&sc);
            if (sc.pos == before) sc.pos++;   /* defensive: never spin */
            continue;
        }
        any_content = true;
        sc.pos++;
    }
    if (any_content) n_stmts++;
    return n_stmts;
}

/* Classifies the TOP-LEVEL statement keyword, skipping past a leading
 * WITH clause's CTE definitions first (see this file's header comment
 * on why this matters for MariaDB specifically: a CTE can feed a
 * top-level DML statement even though the CTE bodies themselves can
 * only be SELECTs). Returns one of "SELECT"/"INSERT"/"UPDATE"/
 * "DELETE"/"REPLACE"/"OTHER", or NULL if the WITH clause itself is
 * malformed (unbalanced parens / missing AS); treated as a parse
 * failure by the caller. */
static const char *
t2s_classify_leading_stmt(const char *sql, size_t len)
{
    t2s_scan sc = { sql, len, 0 };
    t2s_skip_ws_comments(&sc);
    if (sc.pos >= sc.len) return "OTHER";   /* empty; caller's statement-count check already rejects this */

    if (t2s_match_kw(&sc, "WITH")) {
        t2s_skip_ws_comments(&sc);
        t2s_match_kw(&sc, "RECURSIVE");   /* optional, don't care either way */
        t2s_skip_ws_comments(&sc);
        for (;;) {
            if (sc.pos < sc.len && sc.s[sc.pos] == '`') t2s_skip_quoted(&sc);
            else { while (sc.pos < sc.len && t2s_is_ident_char((unsigned char) sc.s[sc.pos])) sc.pos++; }
            t2s_skip_ws_comments(&sc);
            if (sc.pos < sc.len && sc.s[sc.pos] == '(') {
                /* optional column-name list before AS */
                if (!t2s_skip_paren_balanced(&sc)) return NULL;
                t2s_skip_ws_comments(&sc);
            }
            if (!t2s_match_kw(&sc, "AS")) return NULL;
            t2s_skip_ws_comments(&sc);
            if (sc.pos >= sc.len || sc.s[sc.pos] != '(') return NULL;
            if (!t2s_skip_paren_balanced(&sc)) return NULL;
            t2s_skip_ws_comments(&sc);
            if (sc.pos < sc.len && sc.s[sc.pos] == ',') { sc.pos++; t2s_skip_ws_comments(&sc); continue; }
            break;
        }
    }

    /* A leading '(' at the top level (after any WITH-clause) is only
     * valid MariaDB grammar for a parenthesized SELECT/set-operation.
     * DML statements cannot be parenthesized at statement level. */
    if (sc.pos < sc.len && sc.s[sc.pos] == '(') return "SELECT";

    if (t2s_match_kw(&sc, "SELECT"))  return "SELECT";
    if (t2s_match_kw(&sc, "INSERT"))  return "INSERT";
    if (t2s_match_kw(&sc, "UPDATE"))  return "UPDATE";
    if (t2s_match_kw(&sc, "DELETE"))  return "DELETE";
    if (t2s_match_kw(&sc, "REPLACE")) return "REPLACE";
    return "OTHER";
}

/* Whole-statement (all depths) scan for INTO OUTFILE / INTO DUMPFILE,
 * outside quotes/comments. See this file's header comment: rejected
 * unconditionally regardless of allowed_statements mode. */
static bool
t2s_has_into_outfile(const char *sql, size_t len)
{
    t2s_scan sc = { sql, len, 0 };
    while (sc.pos < sc.len) {
        char c = sc.s[sc.pos];
        if (c == '\'' || c == '"' || c == '`') { t2s_skip_quoted(&sc); continue; }
        if ((c == '-' && sc.pos + 1 < sc.len && sc.s[sc.pos + 1] == '-') ||
            c == '#' ||
            (c == '/' && sc.pos + 1 < sc.len && sc.s[sc.pos + 1] == '*')) {
            size_t before = sc.pos;
            t2s_skip_ws_comments(&sc);
            if (sc.pos == before) sc.pos++;
            continue;
        }
        if (t2s_match_kw(&sc, "INTO")) {
            t2s_scan save = sc;
            t2s_skip_ws_comments(&sc);
            if (t2s_match_kw(&sc, "OUTFILE") || t2s_match_kw(&sc, "DUMPFILE"))
                return true;
            sc = save;
            continue;
        }
        sc.pos++;
    }
    return false;
}

/* MariaDB executes the contents of a versioned comment (slash-star-
 * bang-star) and an optimizer-hint comment (slash-star-plus) as
 * statement text, so neither is inert here the way a plain block
 * comment is. Any such comment in candidate SQL is rejected outright
 * (over-rejection is this gate's stated failure direction): splicing
 * tokens into one would otherwise defeat both the statement counter
 * and the INTO OUTFILE scan -- e.g.
 *   SELECT 1 INTO <slash-star-bang> OUTFILE star-slash '/tmp/x'
 * passes both scanners as written while the server executes the
 * outfile write. The scan is quote- and plain-comment-aware, so a
 * literal inside a string value does not false-positive. */
static bool
t2s_has_exec_comment(const char *sql, size_t len)
{
    t2s_scan sc = { sql, len, 0 };
    while (sc.pos < sc.len) {
        char c = sc.s[sc.pos];
        if (c == '\'' || c == '"' || c == '`') { t2s_skip_quoted(&sc); continue; }
        if (c == '/' && sc.pos + 1 < sc.len && sc.s[sc.pos + 1] == '*') {
            if (sc.pos + 2 < sc.len &&
                (sc.s[sc.pos + 2] == '!' || sc.s[sc.pos + 2] == '+'))
                return true;
            /* plain comment: skip to its close, same loop shape as
             * t2s_skip_ws_comments */
            sc.pos += 2;
            while (sc.pos + 1 < sc.len && !(sc.s[sc.pos] == '*' && sc.s[sc.pos + 1] == '/'))
                sc.pos++;
            sc.pos = (sc.pos + 1 < sc.len) ? sc.pos + 2 : sc.len;
            continue;
        }
        sc.pos++;
    }
    return false;
}

FRACTAL_EXPORT bool
fractal_t2s_check_allowlist_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_t2s_check_allowlist(sql): expected 1 argument, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    return str_out_generic_init(initid, message, 1024);
}

FRACTAL_EXPORT void
fractal_t2s_check_allowlist_deinit(UDF_INIT *initid) { str_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_t2s_check_allowlist(UDF_INIT *initid, UDF_ARGS *args, char *result,
                            unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    const char *sql;
    unsigned long sqllen;
    char buf[1024];
    int  n;
    int  n_stmts;
    const char *kw;
    bool select_only;
    bool ok;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    sql    = args->args[0];
    sqllen = args->lengths[0];
    if (sqllen > FRACTAL_T2S_MAX_SQL_BYTES) { *error = 1; return NULL; }

    ensure_env_config();
    select_only = (strcmp(g_cfg.allowed_statements, "select_insert_update") != 0);

    if (t2s_has_exec_comment(sql, sqllen)) {
        n = snprintf(buf, sizeof buf,
            "versioned (slash-star-bang) and optimizer-hint (slash-star-plus) "
            "comments are not allowed: the server executes their contents");
        goto reject;
    }

    n_stmts = t2s_count_statements(sql, sqllen);
    if (n_stmts == 0) {
        n = snprintf(buf, sizeof buf, "SQL is empty");
        goto reject;
    }
    if (n_stmts != 1) {
        n = snprintf(buf, sizeof buf,
            "expected exactly one SQL statement, found %d. "
            "fractal_text_to_sql only returns a single statement", n_stmts);
        goto reject;
    }

    kw = t2s_classify_leading_stmt(sql, sqllen);
    if (kw == NULL) {
        n = snprintf(buf, sizeof buf, "SQL does not parse: malformed WITH clause");
        goto reject;
    }

    ok = select_only ? (strcmp(kw, "SELECT") == 0)
                      : (strcmp(kw, "SELECT") == 0 || strcmp(kw, "INSERT") == 0 || strcmp(kw, "UPDATE") == 0);
    if (!ok) {
        n = snprintf(buf, sizeof buf,
            "statement type \"%s\" is not permitted. "
            "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS is set to \"%s\"",
            kw, select_only ? "select" : "select_insert_update");
        goto reject;
    }

    if (t2s_has_into_outfile(sql, sqllen)) {
        n = snprintf(buf, sizeof buf,
            "statement embeds INTO OUTFILE/DUMPFILE, which writes to the "
            "filesystem and is never permitted regardless of "
            "FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS");
        goto reject;
    }

    *is_null = 1;
    return NULL;

reject:
    if (n < 0) n = 0;
    char *s = str_out_set(so, buf, (size_t) (n < (int) sizeof buf ? n : (int) sizeof buf - 1), length);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}
