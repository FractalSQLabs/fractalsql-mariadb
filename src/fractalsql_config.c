/* src/fractalsql_config.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The configuration surface shared by the daemon's config file, the
 * per-session overlay, and the path rules -- see fractalsql_config.h
 * for the design and the per-key allow/deny rationale.
 *
 * Pure C99: no <mysql.h>, so this translation unit can also be linked
 * into the daemon's config loader (service/daemon/fractalsqld.c) and
 * into the standalone test drivers.
 */

#include "fractalsql_config.h"
#include "fractalsql_msvc_compat.h"  /* setenv on MSVC */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <Windows.h>
#else
#  include <pthread.h>
#endif

/* Writes a one-line reason into the caller's buffer. The `err`
 * argument is OPTIONAL -- a caller that does not want the reason
 * passes NULL -- so every reason write goes through this. */
#define CFG_SET_ERR(buf, cap, ...)                                        \
    do {                                                                   \
        if ((buf) != NULL && (cap) > 0)                                   \
            snprintf((buf), (cap), __VA_ARGS__);                           \
    } while (0)

/* ------------------------------------------------------------------ */
/* The key table                                                       */
/* ------------------------------------------------------------------ */

/* The env-bridged keys name the FSQL_REASONING_* variables the
 * reasoning plugin reads. The keys with no env_var are read by this
 * repo's own code instead (the text-to-SQL knobs) or are process-wide
 * only (the paths, the URLs, the tokens). */
static const fsq_cfg_key g_keys[FSQL_CFG_KEY_COUNT] = {
    { "reasoning_plugin",            FSQL_CFG_TYPE_PATH, 0, 0, NULL,
      false, false, NULL, 0 },
    { "reasoning_url",               FSQL_CFG_TYPE_STR,  0, 0, NULL,
      false, false, NULL, 0 },
    { "reasoning_token",             FSQL_CFG_TYPE_STR,  0, 0, NULL,
      false, true,  NULL, 0 },
    { "reasoning_model",             FSQL_CFG_TYPE_STR,  0, 0, NULL,
      true,  false, "FSQL_REASONING_HTTP_MODEL",
      FSQL_CFG_TIER_REASON | FSQL_CFG_TIER_T2S },
    { "reasoning_allow_plaintext",   FSQL_CFG_TYPE_BOOL, 0, 0, NULL,
      false, false, NULL, 0 },
    { "embed_url",                   FSQL_CFG_TYPE_STR,  0, 0, NULL,
      false, false, NULL, 0 },
    { "embed_model",                 FSQL_CFG_TYPE_STR,  0, 0, NULL,
      true,  false, "FSQL_REASONING_HTTP_MODEL", FSQL_CFG_TIER_EMBED },
    { "think",                       FSQL_CFG_TYPE_STR,  0, 0, NULL,
      true,  false, "FSQL_REASONING_HTTP_THINK",
      FSQL_CFG_TIER_REASON | FSQL_CFG_TIER_T2S },
    { "think_provider",              FSQL_CFG_TYPE_STR,  0, 0, NULL,
      false, false, NULL, 0 },
    { "think_native_url",            FSQL_CFG_TYPE_STR,  0, 0, NULL,
      false, false, NULL, 0 },
    { "think_num_ctx",               FSQL_CFG_TYPE_INT,  1, 10000000, NULL,
      true,  false, "FSQL_REASONING_HTTP_NUM_CTX",
      FSQL_CFG_TIER_REASON | FSQL_CFG_TIER_T2S },
    { "t2s_max_attempts",            FSQL_CFG_TYPE_INT,  1, 10, NULL,
      true,  false, NULL, 0 },
    { "t2s_allowed_statements",      FSQL_CFG_TYPE_ENUM, 0, 0,
      "select|select_insert_update", false, false, NULL, 0 },
    { "t2s_use_review",              FSQL_CFG_TYPE_BOOL, 0, 0, NULL,
      true,  false, NULL, 0 },
    { "enterprise_lib",              FSQL_CFG_TYPE_PATH, 0, 0, NULL,
      false, false, NULL, 0 },
    { "enterprise_ledger_path",      FSQL_CFG_TYPE_PATH, 0, 0, NULL,
      false, false, NULL, 0 },
    { "enterprise_ledger_key",       FSQL_CFG_TYPE_STR,  0, 0, NULL,
      false, true,  NULL, 0 },
    { "enterprise_require_signature",FSQL_CFG_TYPE_BOOL, 0, 0, NULL,
      false, false, NULL, 0 }
};

const fsq_cfg_key *fractal_config_key_table(void) { return g_keys; }

const char *fractal_config_key_name(int key_id)
{
    if (key_id < 0 || key_id >= FSQL_CFG_KEY_COUNT) return NULL;
    return g_keys[key_id].key;
}

bool fractal_config_key_session_ok(int key_id)
{
    if (key_id < 0 || key_id >= FSQL_CFG_KEY_COUNT) return false;
    return g_keys[key_id].session_ok;
}

int fractal_config_key_by_name(const char *name)
{
    size_t i;
    if (name == NULL) return -1;
    if (strncmp(name, "fractalsql.", 11) == 0) name += 11;
    for (i = 0; i < FSQL_CFG_KEY_COUNT; i++)
        if (strcmp(g_keys[i].key, name) == 0) return (int) i;
    return -1;
}

/* ------------------------------------------------------------------ */
/* Path validation                                                     */
/* ------------------------------------------------------------------ */

/* A path key must be absolute and must not contain a ".." traversal
 * segment. The rules mirror what the plugin loader itself accepts, so
 * a path that passes here is a path the loader can actually open --
 * validation happens at configuration time instead of surfacing later
 * as a load failure with no context.
 *
 * Windows accepts a drive-letter path ("C:\dir\file", "C:/dir/file"),
 * a UNC path ("\\server\share\file") and a rooted path ("\dir\file").
 * POSIX accepts a rooted path ("/dir/file"). A relative path is
 * refused: the daemon's working directory is not a contract, so a
 * relative path would resolve differently depending on how the
 * daemon was started. */
int fractal_config_validate_path(const char *path, char *err, size_t errcap)
{
    size_t n, i;
    int is_abs = 0;

    if (err != NULL && errcap > 0) err[0] = '\0';
    if (path == NULL || path[0] == '\0') {
        CFG_SET_ERR(err, errcap, "path must not be empty");
        return -1;
    }
    n = strlen(path);
    if (n >= FSQL_CFG_MAX_VALUE) {
        CFG_SET_ERR(err, errcap, "path is too long");
        return -1;
    }

#if defined(_WIN32) || defined(__CYGWIN__)
    if (((path[0] >= 'A' && path[0] <= 'Z') ||
         (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':' &&
        (path[2] == '\\' || path[2] == '/'))
        is_abs = 1;
    if (path[0] == '\\' && path[1] == '\\') is_abs = 1;   /* UNC */
    if (path[0] == '\\' || path[0] == '/') is_abs = 1;     /* rooted */
#else
    if (path[0] == '/') is_abs = 1;
#endif

    if (!is_abs) {
        CFG_SET_ERR(err, errcap,
                    "must be an absolute path with no '..' segments");
        return -1;
    }

    /* Lexical traversal: any ".." segment, whatever it is glued to.
     * Checking the whole path for ".." (rather than for a "/../"
     * segment) also refuses a file whose own name contains two dots,
     * which is not a name this codebase ever generates. */
    for (i = 0; i + 1 < n; i++) {
        if (path[i] == '.' && path[i + 1] == '.') {
            CFG_SET_ERR(err, errcap,
                        "must be an absolute path with no '..' segments");
            return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Per-session overlay store                                           */
/* ------------------------------------------------------------------ */

typedef struct fsq_cfg_entry {
    unsigned long long session_id;
    bool              used;
    uint64_t          touched;   /* LRU stamp (monotonic counter) */
    char             *values[FSQL_CFG_KEY_COUNT];
} fsq_cfg_entry;

static fsq_cfg_entry g_entries[FSQL_CFG_MAX_SESSIONS];
static unsigned int  g_entry_count = 0;
static uint64_t      g_clock = 0;

/* ------------------------------------------------------------------ */
/* Portable lock (same shim as fractalsql_session.c's).               */
/* ------------------------------------------------------------------ */
#if defined(_WIN32)
static INIT_ONCE        g_lock_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_lock;

static BOOL CALLBACK
init_lock_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
    InitializeCriticalSection(&g_lock);
    return TRUE;
}
static void cfg_lock(void)
{
    InitOnceExecuteOnce(&g_lock_once, init_lock_once, NULL, NULL);
    EnterCriticalSection(&g_lock);
}
static void cfg_unlock(void) { LeaveCriticalSection(&g_lock); }
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void cfg_lock(void)   { pthread_mutex_lock(&g_lock); }
static void cfg_unlock(void) { pthread_mutex_unlock(&g_lock); }
#endif

/* Caller holds the lock. */
static fsq_cfg_entry *
find_entry(unsigned long long sid)
{
    unsigned int i;
    for (i = 0; i < FSQL_CFG_MAX_SESSIONS; i++)
        if (g_entries[i].used && g_entries[i].session_id == sid)
            return &g_entries[i];
    return NULL;
}

/* Caller holds the lock. Returns NULL only when the table is full AND
 * no entry can be reclaimed -- which cannot happen with the LRU sweep
 * below, since every slot in a full table is reclaimable. The sweep
 * reclaims the least-recently-touched entry: the overlay holds tuning
 * values, not live resources, so the session that owned the reclaimed
 * slot falls back to the process-wide configuration. That fallback is
 * silent by design (there is no session to report it to once its
 * connection is gone), so a client that churns through many session
 * ids can knock a live session's tuning off. The table is small and
 * the values are per-connection, so this is a convenience limit, not
 * a security boundary. */
static fsq_cfg_entry *
new_entry(unsigned long long sid)
{
    unsigned int i;
    fsq_cfg_entry *oldest = NULL;

    /* A session that already has an entry gets THAT entry. A session
     * may hold more than one override at a time (think AND
     * think_num_ctx, say), and a second entry for the same session id
     * would be a silent trap: every read (find_entry) returns the
     * FIRST match, so the second key's override would be invisible to
     * get() and to the list, yet it would still be stored -- and it
     * would survive a reset(), which only ever drops the first entry. */
    {
        fsq_cfg_entry *existing = find_entry(sid);
        if (existing != NULL) return existing;
    }
    for (i = 0; i < FSQL_CFG_MAX_SESSIONS; i++) {
        if (!g_entries[i].used) {
            memset(&g_entries[i], 0, sizeof g_entries[i]);
            g_entries[i].used = true;
            g_entries[i].session_id = sid;
            g_entry_count++;
            return &g_entries[i];
        }
    }
    /* Full: reclaim the least-recently-touched entry. The overlay
     * holds tuning values, not live resources, so reclaiming the
     * oldest is safe -- the session that owned it simply loses its
     * overrides and falls back to the process-wide configuration. */
    for (i = 0; i < FSQL_CFG_MAX_SESSIONS; i++) {
        if (oldest == NULL || g_entries[i].touched < oldest->touched)
            oldest = &g_entries[i];
    }
    if (oldest == NULL) return NULL;
    for (i = 0; i < FSQL_CFG_KEY_COUNT; i++) {
        free(oldest->values[i]);
        oldest->values[i] = NULL;
    }
    oldest->session_id = sid;
    oldest->touched = ++g_clock;
    return oldest;
}

static void
free_entry(fsq_cfg_entry *e)
{
    unsigned int i;
    if (e == NULL) return;
    for (i = 0; i < FSQL_CFG_KEY_COUNT; i++) {
        free(e->values[i]);
        e->values[i] = NULL;
    }
    e->used = false;
    e->session_id = 0;
    if (g_entry_count > 0) g_entry_count--;
}

/* ------------------------------------------------------------------ */
/* Value validation                                                    */
/* ------------------------------------------------------------------ */

static bool
parse_bool(const char *v, int *out)
{
    if (v == NULL) { *out = 0; return true; }
    if (strcmp(v, "true") == 0 || strcmp(v, "on") == 0 ||
        strcmp(v, "1") == 0  || strcmp(v, "yes") == 0) { *out = 1; return true; }
    if (strcmp(v, "false") == 0 || strcmp(v, "off") == 0 ||
        strcmp(v, "0") == 0  || strcmp(v, "no") == 0  ||
        v[0] == '\0') { *out = 0; return true; }
    return false;
}

static bool
parse_long(const char *v, long *out)
{
    char *end = NULL;
    long n;
    if (v == NULL || v[0] == '\0') return false;
    n = strtol(v, &end, 10);
    if (end == NULL || *end != '\0' || end == v) return false;
    *out = n;
    return true;
}

static bool
enum_has(const char *list, const char *value)
{
    const char *p = list;
    size_t vlen = strlen(value);
    while (p != NULL && *p != '\0') {
        const char *bar = strchr(p, '|');
        size_t len = bar != NULL ? (size_t)(bar - p) : strlen(p);
        if (len == vlen && strncmp(value, p, len) == 0) return true;
        p = bar != NULL ? bar + 1 : NULL;
    }
    return false;
}

/* Validates `value` against the key's own kind. Returns 0 on success,
 * -1 with a one-line reason otherwise. An empty value is always
 * acceptable: it unsets the session's override. */
static int
validate_value(const fsq_cfg_key *k, const char *value, char *err, size_t errcap)
{
    long n = 0;
    if (value == NULL || value[0] == '\0') return 0;

    switch (k->type) {
    case FSQL_CFG_TYPE_PATH:
        if (fractal_config_validate_path(value, err, errcap) != 0) return -1;
        return 0;
    case FSQL_CFG_TYPE_INT:
        if (!parse_long(value, &n)) {
            CFG_SET_ERR(err, errcap, "'%s' expects an integer", k->key);
            return -1;
        }
        if (n < k->min || n > k->max) {
            CFG_SET_ERR(err, errcap, "'%s' must be %ld..%ld", k->key, k->min, k->max);
            return -1;
        }
        return 0;
    case FSQL_CFG_TYPE_BOOL:
        {
            int b = 0;
            if (!parse_bool(value, &b)) {
                CFG_SET_ERR(err, errcap,
                            "'%s' expects true/false/on/off/1/0", k->key);
                return -1;
            }
        }
        return 0;
    case FSQL_CFG_TYPE_ENUM:
        if (!enum_has(k->enum_vals, value)) {
            CFG_SET_ERR(err, errcap, "'%s' must be one of: %s", k->key, k->enum_vals);
            return -1;
        }
        return 0;
    case FSQL_CFG_TYPE_STR:
    default:
        /* The limit is the whole buffer, terminator included: a value of
         * FSQL_CFG_MAX_VALUE bytes does not fit in an FSQL_CFG_MAX_VALUE
         * buffer with its NUL, and the read path would hand back a
         * truncated value. The same off-by-one is avoided on the path
         * check above. */
        if (strlen(value) >= FSQL_CFG_MAX_VALUE) {
            CFG_SET_ERR(err, errcap, "'%s' is too long", k->key);
            return -1;
        }
        return 0;
    }
}

/* ------------------------------------------------------------------ */
/* The session overlay API                                             */
/* ------------------------------------------------------------------ */

int fractal_config_set_value(unsigned long long session_id, const char *name,
                       const char *value, char *err, size_t errcap)
{
    int key_id;
    const fsq_cfg_key *k;
    fsq_cfg_entry *e;
    char *copy = NULL;

    if (err != NULL && errcap > 0) err[0] = '\0';
    key_id = fractal_config_key_by_name(name);
    if (key_id < 0) {
        CFG_SET_ERR(err, errcap, "unknown configuration key '%s'",
                    name != NULL ? name : "(null)");
        return -1;
    }
    k = &g_keys[key_id];

    if (!k->session_ok) {
        CFG_SET_ERR(err, errcap,
                    "'%s' is a daemon-wide setting and cannot be changed by a "
                    "session; edit fractalsqld.conf and run `fsqlctl reload`",
                    k->key);
        return -1;
    }
    if (validate_value(k, value, err, errcap) != 0) return -1;

    if (value != NULL && value[0] != '\0') {
        copy = (char *) malloc(strlen(value) + 1);
        if (copy == NULL) {
            CFG_SET_ERR(err, errcap, "out of memory");
            return -1;
        }
        memcpy(copy, value, strlen(value) + 1);
    }

    cfg_lock();
    if (value != NULL && value[0] != '\0') {
        e = new_entry(session_id);
    } else {
        /* An empty value UNSETS the override. A session that holds no
         * override for this key has nothing to unset: that is a no-op
         * success, not a refusal. (Reporting "the table is full" here
         * was both untrue and untraceable -- the table had free slots;
         * the session simply had no entry.) */
        e = find_entry(session_id);
        if (e == NULL) {
            cfg_unlock();
            return 0;
        }
    }
    if (e == NULL) {
        cfg_unlock();
        free(copy);
        CFG_SET_ERR(err, errcap,
                    "the per-session configuration table is full");
        return -1;
    }
    free(e->values[key_id]);
    e->values[key_id] = copy;
    e->touched = ++g_clock;
    cfg_unlock();
    return 0;
}

bool fractal_config_lookup_str(unsigned long long session_id, const char *name,
                               char *out, size_t outcap)
{
    int key_id = fractal_config_key_by_name(name);
    fsq_cfg_entry *e;
    bool found = false;

    if (key_id < 0) return false;
    cfg_lock();
    e = find_entry(session_id);
    if (e != NULL && e->values[key_id] != NULL) {
        if (out != NULL && outcap > 0) {
            /* Copy with an explicit length: strncpy would pad the
             * whole buffer and MSVC deprecates it outright. */
            const char *src = e->values[key_id];
            size_t n = strlen(src);
            if (n > outcap - 1) n = outcap - 1;
            memcpy(out, src, n);
            out[n] = '\0';
        }
        e->touched = ++g_clock;
        found = true;
    }
    cfg_unlock();
    return found;
}

bool fractal_config_lookup_long(unsigned long long session_id, const char *name,
                                long *out)
{
    char buf[64];
    long v = 0;
    if (!fractal_config_lookup_str(session_id, name, buf, sizeof buf)) return false;
    if (!parse_long(buf, &v)) return false;
    if (out != NULL) *out = v;
    return true;
}

/* The process-wide value for a key, read from the tier that owns it.
 * Each tier keeps its own copy of the effective configuration (the
 * apply_provider contract in fractalsql_provider.h), so the read side
 * asks the owning tier. Declared here rather than in a shared header
 * to keep the dependency one-way: the tiers know about the config
 * module, the config module only knows the tiers' accessor names. */
int fractalsql_cognition_config_value(const char *name, char *out, size_t outcap);
int fractalsql_textsql_config_value(const char *name, char *out, size_t outcap);
int fractalsql_enterprise_config_value(const char *name, char *out, size_t outcap);

int fractal_config_get_value(unsigned long long session_id, const char *name,
                       char *out, size_t outcap)
{
    int key_id = fractal_config_key_by_name(name);

    if (out != NULL && outcap > 0) out[0] = '\0';
    if (key_id < 0) return -1;

    /* A secret's value is never handed to a session. The caller learns
     * that a credential is configured (or not) and nothing more. */
    if (g_keys[key_id].secret) {
        char present[2] = { 0, 0 };
        bool set = fractal_config_lookup_str(session_id, name, present, sizeof present);
        if (!set) {
            /* Not overridden by the session: is the daemon-wide value
             * set? Read it into a scratch buffer so the secret never
             * lands in the caller's buffer, not even briefly. */
            char scratch[64];
            set = (fractalsql_cognition_config_value(g_keys[key_id].key,
                                                      scratch, sizeof scratch) == 0) ||
                  (fractalsql_enterprise_config_value(g_keys[key_id].key,
                                                      scratch, sizeof scratch) == 0);
        }
        if (out == NULL || outcap == 0) return -1;
        {
            int n = snprintf(out, outcap, set ? "<redacted>" : "<unset>");
            return (n < 0 || (size_t) n >= outcap) ? -1 : 0;
        }
    }

    if (fractal_config_lookup_str(session_id, name, out, outcap)) return 0;

    switch (key_id) {
    case FSQL_CFG_REASONING_PLUGIN:
    case FSQL_CFG_REASONING_URL:
    case FSQL_CFG_REASONING_TOKEN:
    case FSQL_CFG_REASONING_MODEL:
    case FSQL_CFG_REASONING_ALLOW_PLAINTEXT:
    case FSQL_CFG_EMBED_URL:
    case FSQL_CFG_EMBED_MODEL:
    case FSQL_CFG_THINK:
    case FSQL_CFG_THINK_PROVIDER:
    case FSQL_CFG_THINK_NATIVE_URL:
    case FSQL_CFG_THINK_NUM_CTX:
        return fractalsql_cognition_config_value(g_keys[key_id].key, out, outcap);
    case FSQL_CFG_T2S_MAX_ATTEMPTS:
    case FSQL_CFG_T2S_ALLOWED_STATEMENTS:
    case FSQL_CFG_T2S_USE_REVIEW:
        return fractalsql_textsql_config_value(g_keys[key_id].key, out, outcap);
    case FSQL_CFG_ENTERPRISE_LIB:
    case FSQL_CFG_ENTERPRISE_LEDGER_PATH:
    case FSQL_CFG_ENTERPRISE_LEDGER_KEY:
    case FSQL_CFG_ENTERPRISE_REQUIRE_SIGNATURE:
        return fractalsql_enterprise_config_value(g_keys[key_id].key, out, outcap);
    default:
        break;
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* A growable output buffer                                            */
/* ------------------------------------------------------------------ */

/* The session overlay's JSON is rendered under the lock in one pass, and
 * its length is not knowable in advance: a stored value is ESCAPED on
 * the way out, so a single control byte costs six bytes (\u00XX) in the
 * document. Sizing a fixed buffer from the value table instead means
 * guessing that escape factor, and a guess that is too small turns
 * "this session holds a lot of text" into a bare NULL. Growing the
 * buffer makes the rendered document exactly as long as it needs to be
 * and no longer. */
typedef struct cfg_buf {
    char  *buf;
    size_t len;
    size_t cap;
} cfg_buf;

static bool
cfg_buf_reserve(cfg_buf *b, size_t need)
{
    size_t ncap;
    char  *nb;
    if (need <= b->cap) return true;
    ncap = b->cap ? b->cap : 256;
    while (ncap < need) {
        /* Doubling overflows on a huge need; fall back to the exact
         * size rather than wrapping to a smaller allocation. */
        if (ncap > ((size_t) -1) / 2) { ncap = need; break; }
        ncap *= 2;
    }
    nb = (char *) realloc(b->buf, ncap);
    if (nb == NULL) return false;
    b->buf = nb;
    b->cap = ncap;
    return true;
}

static bool
cfg_buf_putc(cfg_buf *b, char c)
{
    if (!cfg_buf_reserve(b, b->len + 2)) return false;
    b->buf[b->len++] = c;
    b->buf[b->len] = '\0';
    return true;
}

static bool
cfg_buf_puts(cfg_buf *b, const char *s, size_t n)
{
    if (!cfg_buf_reserve(b, b->len + n + 1)) return false;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return true;
}

/* Appends one JSON string literal (quotes included) to `b`, escaping
 * the two characters a JSON string cannot carry raw. Returns true on
 * success, false when the buffer could not grow. */
static bool
json_append_string(cfg_buf *b, const char *s)
{
    size_t i;
    /* The OPENING quote. The closing quote is written below; a JSON
     * string literal needs both, and a list built without the opening
     * one is not parseable JSON at all. */
    if (!cfg_buf_putc(b, '"')) return false;
    for (i = 0; s[i] != '\0'; i++) {
        char c = s[i];
        char esc[8];
        const char *piece = esc;
        size_t plen = 1;
        if (c == '"' || c == '\\') {
            esc[0] = '\\'; esc[1] = c; plen = 2;
        } else if ((unsigned char) c < 0x20) {
            /* A raw control byte is not legal inside a JSON string. The
             * values a session can store are ordinary text, but a
             * newline or a tab must not be emitted raw: the result would
             * not parse, and a caller that falls back to treating the
             * text as an opaque value would then hold a malformed
             * document. \u00XX is the JSON-legal spelling. */
            static const char hexd[] = "0123456789abcdef";
            unsigned char u = (unsigned char) c;
            esc[0] = '\\'; esc[1] = 'u'; esc[2] = '0'; esc[3] = '0';
            esc[4] = hexd[(u >> 4) & 0xf];
            esc[5] = hexd[u & 0xf];
            plen = 6;
        } else {
            esc[0] = c;
        }
        if (!cfg_buf_puts(b, piece, plen)) return false;
    }
    return cfg_buf_putc(b, '"');
}

/* Renders the session's own overrides as a JSON object. The caller
 * OWNS the returned string and frees it; NULL means the render failed
 * (out of memory), which is a failure the caller must be able to tell
 * apart from "this session holds no overrides" -- the latter is the
 * empty object "{}". */
char *fractal_config_session_json(unsigned long long session_id)
{
    fsq_cfg_entry *e;
    cfg_buf b;
    int i;
    bool ok = true;

    memset(&b, 0, sizeof b);
    cfg_lock();
    e = find_entry(session_id);
    if (e == NULL) {
        cfg_unlock();
        /* No entry: the session holds no overrides. */
        b.buf = (char *) malloc(3);
        if (b.buf == NULL) return NULL;
        memcpy(b.buf, "{}", 3);
        b.len = 2;
        b.cap = 3;
        return b.buf;
    }
    ok = cfg_buf_putc(&b, '{');
    for (i = 0; ok && i < FSQL_CFG_KEY_COUNT; i++) {
        if (e->values[i] == NULL) continue;
        if (b.len > 1) ok = cfg_buf_putc(&b, ',');
        if (ok) ok = json_append_string(&b, g_keys[i].key);
        if (ok) ok = cfg_buf_putc(&b, ':');
        if (ok) ok = json_append_string(&b, e->values[i]);
    }
    if (ok) ok = cfg_buf_putc(&b, '}');
    cfg_unlock();
    if (!ok) { free(b.buf); return NULL; }
    return b.buf;
}

int fractal_config_reset_session(unsigned long long session_id)
{
    unsigned int s;
    int i, dropped = 0;

    cfg_lock();
    /* EVERY entry the session holds, not just the first: a reset that
     * leaves an override behind is worse than no reset at all, because
     * the session looks reset and is not. */
    for (s = 0; s < FSQL_CFG_MAX_SESSIONS; s++) {
        fsq_cfg_entry *e = &g_entries[s];
        if (!e->used || e->session_id != session_id) continue;
        for (i = 0; i < FSQL_CFG_KEY_COUNT; i++) {
            if (e->values[i] != NULL) { free(e->values[i]); e->values[i] = NULL; dropped++; }
        }
        free_entry(e);
    }
    cfg_unlock();
    return dropped;
}

void fractal_config_apply_env_overrides(unsigned long long session_id,
                                        unsigned tiers)
{
    int i;
    char buf[FSQL_CFG_MAX_VALUE];

    for (i = 0; i < FSQL_CFG_KEY_COUNT; i++) {
        const fsq_cfg_key *k = &g_keys[i];
        if (!k->session_ok || k->env_var == NULL) continue;
        if ((k->env_tiers & tiers) == 0) continue;
        if (!fractal_config_lookup_str(session_id, k->key, buf, sizeof buf)) continue;
        if (k->type == FSQL_CFG_TYPE_BOOL) {
            int b = 0;
            if (!parse_bool(buf, &b)) continue;
            if (b) setenv(k->env_var, "1", 1);
            else    unsetenv(k->env_var);
            continue;
        }
        setenv(k->env_var, buf, 1);
    }
}

/* ------------------------------------------------------------------ */
/* The bridge environment                                              */
/* ------------------------------------------------------------------ */

/* The variables the reasoning plugin reads, in a fixed order so the
 * fingerprint below is stable. The embed tier's save/restore bracket
 * (fractalsql_cognition.c) walks this same list, so the two cannot
 * drift apart: a variable the tier does not save is a variable the
 * tier leaks into the next tier's load. */
const char *const fsq_cfg_bridge_vars[FSQ_CFG_BRIDGE_VAR_COUNT] = {
    "FSQL_REASONING_HTTP_URL", "FSQL_REASONING_HTTP_TOKEN",
    "FSQL_REASONING_HTTP_MODEL", "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT",
    "FSQL_REASONING_HTTP_MODE", "FSQL_REASONING_HTTP_RESPONSE_MODE",
    "FSQL_REASONING_HTTP_SYSTEM_TAG", "FSQL_REASONING_HTTP_THINK",
    "FSQL_REASONING_HTTP_THINK_PROVIDER", "FSQL_REASONING_HTTP_NATIVE_URL",
    "FSQL_REASONING_HTTP_NUM_CTX",
};

/* The environment lock is separate from the overlay lock above: the
 * overlay lock guards the per-session table, this one guards the
 * process-wide environment the four tiers publish into. */
#if defined(_WIN32)
static INIT_ONCE        g_env_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_env_lock;

static BOOL CALLBACK
init_env_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
    InitializeCriticalSection(&g_env_lock);
    return TRUE;
}
void fractal_config_env_lock(void)
{
    InitOnceExecuteOnce(&g_env_once, init_env_once, NULL, NULL);
    EnterCriticalSection(&g_env_lock);
}
void fractal_config_env_unlock(void) { LeaveCriticalSection(&g_env_lock); }
#else
static pthread_mutex_t g_env_lock = PTHREAD_MUTEX_INITIALIZER;
void fractal_config_env_lock(void)   { pthread_mutex_lock(&g_env_lock); }
void fractal_config_env_unlock(void) { pthread_mutex_unlock(&g_env_lock); }
#endif

/* FNV-1a, 64-bit. */
#define FNV_OFFSET_BASIS 1469598103934665603ULL
#define FNV_PRIME        1099511628211ULL

static void
fnv_bytes(uint64_t *h, const char *s)
{
    size_t i;
    if (s == NULL) return;
    for (i = 0; s[i] != '\0'; i++) {
        *h ^= (uint64_t) (unsigned char) s[i];
        *h *= FNV_PRIME;
    }
    /* A NUL after the bytes, so ("ab","c") and ("a","bc") do not hash
     * the same. */
    *h ^= 0x00u;
    *h *= FNV_PRIME;
}

uint64_t fractal_config_env_fingerprint(void)
{
    uint64_t h = FNV_OFFSET_BASIS;
    size_t i;

    for (i = 0; i < FSQ_CFG_BRIDGE_VAR_COUNT; i++) {
        const char *name = fsq_cfg_bridge_vars[i];
        /* SYSTEM_TAG is per-call for the text-to-SQL generate tier, so
         * it is left out of the fingerprint -- see the header. */
        if (strcmp(name, "FSQL_REASONING_HTTP_SYSTEM_TAG") == 0) continue;
        fnv_bytes(&h, name);
        fnv_bytes(&h, getenv(name));
    }
    return h;
}
