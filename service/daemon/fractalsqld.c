/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fractalsqld: separate process that serves the FractalSQL UDFs to the
 * GPL-2.0-only shim over the FSQ protocol (../protocol). The spike build
 * links no core library. Handlers are added per phase (spec Section 13).
 */

#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#include <mysql.h>
#include <stdbool.h>

#include "../common/fsq_sha256.h"
#include "../protocol/fsq_protocol.h"
#include "fractalsql_interrupt.h"  /* src/: the cancel seams the UDF bodies poll */
#include "fractalsql_provider.h"   /* src/: the conf -> provider-consumer push */

/* Platform layer: AF_UNIX + pthreads on POSIX, a named pipe + Win32
 * threads on Windows. Everything below this block is shared. */
#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <process.h>
#  include <sddl.h>
#  include <aclapi.h>
#  define FSQ_PRINTF(fmt_idx, arg_idx)
#  define FSQ_TLS __declspec(thread)
#  define FSQ_CONFIG_DEFAULT "C:\\ProgramData\\FractalSQL\\fractalsqld.conf"
#  define FSQ_PIPE_PREFIX "\\\\.\\pipe\\"
#  define FSQ_SLEEP_MS(ms) Sleep(ms)
#  define FSQ_THREAD_RET unsigned __stdcall
#  define FSQ_THREAD_EXIT 0
#  define fsq_strtok_r strtok_s
#  define fsq_pid() ((long) GetCurrentProcessId())
#  define EWOULDBLOCK EAGAIN
typedef SRWLOCK fsq_mutex;
#  define FSQ_MUTEX_INIT SRWLOCK_INIT
#  define FSQ_LOCK(m) AcquireSRWLockExclusive(&(m))
#  define FSQ_UNLOCK(m) ReleaseSRWLockExclusive(&(m))
typedef HANDLE fsq_sock;
#  define FSQ_SOCK_INVALID INVALID_HANDLE_VALUE
#  define FSQ_SOCK_VALID(s) ((s) != INVALID_HANDLE_VALUE)
#  define FSQ_SDDL_MAX 4096
#  define FSQ_SID_MAX 128
/* Handle cancel flags are written under g_handles_mu but read lock-free
 * from the connection thread mid-call (and inside the interrupt hook), so
 * they live in the platform's smallest atomic. */
typedef volatile LONG fsq_atomic_int;
#  define FSQ_ATOMIC_GET(p)   InterlockedOr((p), 0)
#  define FSQ_ATOMIC_SET(p,v) InterlockedExchange((p), (LONG)(v))
#else
#  include <pthread.h>
#  include <sys/socket.h>
#  include <sys/un.h>
#  include <unistd.h>
#  define FSQ_PRINTF(fmt_idx, arg_idx) __attribute__((format(printf, fmt_idx, arg_idx)))
#  define FSQ_TLS __thread
#  define FSQ_CONFIG_DEFAULT "/etc/fractalsql/fractalsqld.conf"
#  define FSQ_SLEEP_MS(ms) usleep((ms) * 1000)
#  define FSQ_THREAD_RET void *
#  define FSQ_THREAD_EXIT NULL
#  define fsq_strtok_r strtok_r
#  define fsq_pid() ((long) getpid())
typedef pthread_mutex_t fsq_mutex;
#  define FSQ_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#  define FSQ_LOCK(m) pthread_mutex_lock(&(m))
#  define FSQ_UNLOCK(m) pthread_mutex_unlock(&(m))
typedef int fsq_sock;
#  define FSQ_SOCK_INVALID (-1)
#  define FSQ_SOCK_VALID(s) ((s) >= 0)
/* Same atomic contract as the Windows branch above. */
typedef volatile int fsq_atomic_int;
#  define FSQ_ATOMIC_GET(p)   __atomic_load_n((p), __ATOMIC_SEQ_CST)
#  define FSQ_ATOMIC_SET(p,v) __atomic_store_n((p), (v), __ATOMIC_SEQ_CST)
#endif

#define FSQL_DAEMON_VERSION     "2.0.9"
#define FSQ_CONFIG_ENV          "FRACTALSQL_CONFIG"
#define FSQ_MAX_ALLOWED_UIDS    16
#define FSQ_PEER_MAX            160
#define FSQ_DEFAULT_MAX_CONNECTIONS   64
#define FSQ_MAX_CONNECTIONS_LIMIT     1024
#define FSQ_DEFAULT_IDLE_TIMEOUT_SECS 300

struct fsq_config {
    char socket_path[256];
    char key_path[512];
    char log_path[512];
#ifdef _WIN32
    char allowed_sids[FSQ_MAX_ALLOWED_UIDS][FSQ_SID_MAX];
#else
    uid_t allowed_uids[FSQ_MAX_ALLOWED_UIDS];
#endif
    size_t n_allowed;
    uint8_t key[64];
    size_t key_len;
    int max_connections;
    int idle_timeout_secs;
    /* Provider settings (fractalsql_provider.h): the reasoning/embed/
     * think/t2s/enterprise keys, with prov_present remembering which are
     * present in the file. Fixed buffers: a published snapshot is
     * immutable and freed wholesale, so a provider push can point
     * straight at them; the consumers deep-copy what they keep.
     * reasoning_token and enterprise_ledger_key are plaintext
     * credentials -- never printed, only "set"/"unset". */
    char reasoning_plugin[512];
    char reasoning_url[512];
    char reasoning_token[1024];
    char reasoning_model[128];
    bool reasoning_allow_plaintext;
    char embed_url[512];
    char embed_model[128];
    char think[64];
    char think_provider[64];
    char think_native_url[512];
    long think_num_ctx;
    char  think_num_ctx_str[24];
    long  t2s_max_attempts;
    char  t2s_allowed_statements[32];
    bool  t2s_use_review;
    char  enterprise_lib[512];
    char  enterprise_ledger_path[1024];
    char  enterprise_ledger_key[1024];
    bool  enterprise_require_signature;
    uint32_t prov_present;
};

/* A reply is a status, a core return code, and an opaque body. */
struct fsq_reply {
    uint32_t status;
    int32_t core_rc;
    uint8_t *body;
    uint32_t body_len;
};

static volatile sig_atomic_t g_stop = 0;
static fsq_sock g_listen_fd = FSQ_SOCK_INVALID;

/* One line per event on stderr, which the container runtime collects.
 * Payloads and query text are never logged (spec S6); only opcodes, sizes,
 * peer uids and the adapter's own error text. */
static FILE *g_logf = NULL;

static void fsq_log(const char *level, const char *fmt, ...) FSQ_PRINTF(2, 3);
static void fsq_log(const char *level, const char *fmt, ...) {
    char ts[32], msg[768];
    va_list ap;
#ifdef _WIN32
    SYSTEMTIME st;
    GetSystemTime(&st);
    snprintf(ts, sizeof(ts), "%04u-%02u-%02uT%02u:%02u:%02uZ",
             (unsigned) st.wYear, (unsigned) st.wMonth, (unsigned) st.wDay,
             (unsigned) st.wHour, (unsigned) st.wMinute, (unsigned) st.wSecond);
#else
    struct timespec now;
    struct tm tmv;
    clock_gettime(CLOCK_REALTIME, &now);
    gmtime_r(&now.tv_sec, &tmv);
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", &tmv);
#endif
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    FILE *out = g_logf ? g_logf : stderr;
    fprintf(out, "%s fractalsqld[%ld] %s %s\n", ts, fsq_pid(), level, msg);
    fflush(out);
}

/* ------------------------------------------------------------------ */
/* Configuration                                                       */
/* ------------------------------------------------------------------ */

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int load_key(struct fsq_config *cfg) {
    FILE *f = fopen(cfg->key_path, "r");
    char buf[256];
    size_t n = 0;
    int hi = -1;
    if (!f) return -1;
    while (n < sizeof(buf)) {
        int c = fgetc(f);
        if (c == EOF) break;
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        buf[n++] = (char) c;
    }
    fclose(f);
    if (n == 0 || n % 2 != 0 || n / 2 > sizeof(cfg->key)) return -1;
    cfg->key_len = 0;
    for (size_t i = 0; i < n; i++) {
        int v = hex_nibble(buf[i]);
        if (v < 0) return -1;
        if (hi < 0) {
            hi = v;
        } else {
            cfg->key[cfg->key_len++] = (uint8_t) ((hi << 4) | v);
            hi = -1;
        }
    }
    return 0;
}

#ifdef _WIN32
/* The SID of the account the daemon runs as: the default allow-list. */
static int process_user_sid(char *out, size_t outlen) {
    HANDLE tok = NULL;
    DWORD need = 0;
    TOKEN_USER *tu = NULL;
    char *sidstr = NULL;
    int ok = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return -1;
    GetTokenInformation(tok, TokenUser, NULL, 0, &need);
    tu = malloc(need ? need : 1);
    if (tu && GetTokenInformation(tok, TokenUser, tu, need, &need) &&
        ConvertSidToStringSidA(tu->User.Sid, &sidstr)) {
        if (strlen(sidstr) < outlen) {
            strcpy(out, sidstr);
            ok = 1;
        }
        LocalFree(sidstr);
    }
    free(tu);
    CloseHandle(tok);
    return ok ? 0 : -1;
}
#endif

static int load_config(const char *path, struct fsq_config *cfg) {
    FILE *f = fopen(path, "r");
    char line[1024];
    if (!f) return -1;
    memset(cfg, 0, sizeof(*cfg));
    cfg->max_connections = FSQ_DEFAULT_MAX_CONNECTIONS;
    cfg->idle_timeout_secs = FSQ_DEFAULT_IDLE_TIMEOUT_SECS;
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        char *k, *v;
        if (!eq || line[0] == '#') continue;
        *eq = '\0';
        k = line;
        v = eq + 1;
        while (*k == ' ' || *k == '\t') k++;
        for (char *e = k + strlen(k); e > k && (e[-1] == ' ' || e[-1] == '\t'); e--) e[-1] = '\0';
        while (*v == ' ' || *v == '\t') v++;
        for (char *e = v + strlen(v); e > v && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' '); e--) e[-1] = '\0';
        /* Copy a value into a fixed config buffer, failing the whole
         * parse on truncation: a silently clipped token or path would
         * surface later as a confusing provider error. */
#define CFG_SET_STR(field) \
        do { \
            if (strlen(v) >= sizeof(cfg->field)) { fclose(f); return -1; } \
            strcpy(cfg->field, v); \
        } while (0)
        /* A boolean value reads like the corresponding FRACTALSQL_* env
         * name: any non-empty value except "0" is true, empty is false. */
#define CFG_SET_BOOL(field) \
        do { cfg->field = (v[0] != '\0' && strcmp(v, "0") != 0); } while (0)
        if (strcmp(k, "socket_path") == 0) {
            CFG_SET_STR(socket_path);
        } else if (strcmp(k, "hmac_key_file") == 0) {
            CFG_SET_STR(key_path);
        } else if (strcmp(k, "log_file") == 0) {
            CFG_SET_STR(log_path);
        } else if (strcmp(k, "max_connections") == 0) {
            cfg->max_connections = atoi(v);
        } else if (strcmp(k, "idle_timeout_secs") == 0) {
            cfg->idle_timeout_secs = atoi(v);
#ifdef _WIN32
        } else if (strcmp(k, "allowed_pipe_sid") == 0) {
            char *save = NULL;
            for (char *tok = fsq_strtok_r(v, ",", &save); tok; tok = fsq_strtok_r(NULL, ",", &save)) {
                while (*tok == ' ') tok++;
                if (cfg->n_allowed >= FSQ_MAX_ALLOWED_UIDS || strlen(tok) >= FSQ_SID_MAX) { fclose(f); return -1; }
                strcpy(cfg->allowed_sids[cfg->n_allowed++], tok);
            }
#else
        } else if (strcmp(k, "allowed_uids") == 0) {
            char *save = NULL;
            for (char *tok = fsq_strtok_r(v, ",", &save); tok; tok = fsq_strtok_r(NULL, ",", &save)) {
                if (cfg->n_allowed >= FSQ_MAX_ALLOWED_UIDS) { fclose(f); return -1; }
                cfg->allowed_uids[cfg->n_allowed++] = (uid_t) strtoul(tok, NULL, 10);
            }
#endif
        /* Provider keys (fractalsql_provider.h). Parse is lenient here;
         * validate_provider_cfg does the loud, specific range checks a
         * deliberate file edit deserves -- and it knows which keys were
         * present, so absent keys' silent env defaults stay untouched. */
        } else if (strcmp(k, "reasoning_plugin") == 0) {
            CFG_SET_STR(reasoning_plugin);
            cfg->prov_present |= FSQL_PROV_REASONING_PLUGIN;
        } else if (strcmp(k, "reasoning_url") == 0) {
            CFG_SET_STR(reasoning_url);
            cfg->prov_present |= FSQL_PROV_REASONING_URL;
        } else if (strcmp(k, "reasoning_token") == 0) {
            CFG_SET_STR(reasoning_token);
            cfg->prov_present |= FSQL_PROV_REASONING_TOKEN;
        } else if (strcmp(k, "reasoning_model") == 0) {
            CFG_SET_STR(reasoning_model);
            cfg->prov_present |= FSQL_PROV_REASONING_MODEL;
        } else if (strcmp(k, "reasoning_allow_plaintext") == 0) {
            CFG_SET_BOOL(reasoning_allow_plaintext);
            cfg->prov_present |= FSQL_PROV_REASONING_PLAINTEXT;
        } else if (strcmp(k, "embed_url") == 0) {
            CFG_SET_STR(embed_url);
            cfg->prov_present |= FSQL_PROV_EMBED_URL;
        } else if (strcmp(k, "embed_model") == 0) {
            CFG_SET_STR(embed_model);
            cfg->prov_present |= FSQL_PROV_EMBED_MODEL;
        } else if (strcmp(k, "think") == 0) {
            CFG_SET_STR(think);
            cfg->prov_present |= FSQL_PROV_THINK;
        } else if (strcmp(k, "think_provider") == 0) {
            CFG_SET_STR(think_provider);
            cfg->prov_present |= FSQL_PROV_THINK_PROVIDER;
        } else if (strcmp(k, "think_native_url") == 0) {
            CFG_SET_STR(think_native_url);
            cfg->prov_present |= FSQL_PROV_NATIVE_URL;
        } else if (strcmp(k, "think_num_ctx") == 0) {
            /* Lenient parse: validate_provider_cfg refuses garbage and
             * out-of-range values by name. Trailing garbage after the
             * digits ("10abc") is rejected here too, not just a value
             * with no digits at all -- *endp must land on the NUL. */
            char *endp;
            cfg->think_num_ctx = strtol(v, &endp, 10);
            if (endp == v || *endp != '\0') cfg->think_num_ctx = -1;
            cfg->prov_present |= FSQL_PROV_NUM_CTX;
        } else if (strcmp(k, "t2s_max_attempts") == 0) {
            char *endp;
            cfg->t2s_max_attempts = strtol(v, &endp, 10);
            if (endp == v || *endp != '\0') cfg->t2s_max_attempts = -1;
            cfg->prov_present |= FSQL_PROV_T2S_MAX_ATTEMPTS;
        } else if (strcmp(k, "t2s_allowed_statements") == 0) {
            CFG_SET_STR(t2s_allowed_statements);
            cfg->prov_present |= FSQL_PROV_T2S_ALLOWED;
        } else if (strcmp(k, "t2s_use_review") == 0) {
            CFG_SET_BOOL(t2s_use_review);
            cfg->prov_present |= FSQL_PROV_T2S_USE_REVIEW;
        } else if (strcmp(k, "enterprise_lib") == 0) {
            CFG_SET_STR(enterprise_lib);
            cfg->prov_present |= FSQL_PROV_ENT_LIB;
        } else if (strcmp(k, "enterprise_ledger_path") == 0) {
            CFG_SET_STR(enterprise_ledger_path);
            cfg->prov_present |= FSQL_PROV_ENT_LEDGER_PATH;
        } else if (strcmp(k, "enterprise_ledger_key") == 0) {
            CFG_SET_STR(enterprise_ledger_key);
            cfg->prov_present |= FSQL_PROV_ENT_LEDGER_KEY;
        } else if (strcmp(k, "enterprise_require_signature") == 0) {
            CFG_SET_BOOL(enterprise_require_signature);
            cfg->prov_present |= FSQL_PROV_ENT_REQUIRE_SIG;
        } else {
            /* With the provider keys live, an unknown key almost always
             * means a typo -- a token meant for the daemon quietly
             * orphaned from it. Say so at WARN. */
            fsq_log("WARN", "config: unknown key '%s' ignored", k);
        }
#undef CFG_SET_STR
#undef CFG_SET_BOOL
    }
    fclose(f);
    if (cfg->socket_path[0] == '\0' || cfg->key_path[0] == '\0') return -1;
#ifdef _WIN32
    if (strncmp(cfg->socket_path, FSQ_PIPE_PREFIX, strlen(FSQ_PIPE_PREFIX)) != 0) return -1;
    if (cfg->n_allowed == 0 && process_user_sid(cfg->allowed_sids[0], FSQ_SID_MAX) == 0) cfg->n_allowed = 1;
    if (cfg->n_allowed == 0) return -1;
    for (size_t i = 0; i < cfg->n_allowed; i++) {
        PSID sid;
        if (!ConvertStringSidToSidA(cfg->allowed_sids[i], &sid)) return -1;
        LocalFree(sid);
    }
#else
    if (strlen(cfg->socket_path) >= 108) return -1;
    if (cfg->n_allowed == 0) cfg->allowed_uids[cfg->n_allowed++] = geteuid();
#endif
    if (cfg->max_connections <= 0 || cfg->max_connections > FSQ_MAX_CONNECTIONS_LIMIT) return -1;
    if (cfg->idle_timeout_secs <= 0) return -1;
    return load_key(cfg);
}

/* ------------------------------------------------------------------ */
/* Refcounted configuration snapshots                                  */
/* ------------------------------------------------------------------ */

/* The platform checks a config must pass to be usable. main() runs them
 * at startup and RELOAD runs them again before applying anything, so a
 * reload can never publish a config the daemon would refuse at boot.
 * Defined per platform below (the key-file privacy check differs). */
static int validate_cfg(const struct fsq_config *cfg);
#ifdef _WIN32
static int build_pipe_sd(const struct fsq_config *cfg);
static int key_file_private(const char *path);
#endif

/* One immutable configuration under a refcount. run_listener and every
 * serve thread borrow the config they read; RELOAD swaps in a fresh
 * snapshot and the previous one is freed when its last borrower releases.
 * A published snapshot is never mutated. */
struct fsq_config_snap {
    struct fsq_config cfg;
    int refs;
};

static fsq_mutex g_cfg_mu = FSQ_MUTEX_INIT;
static struct fsq_config_snap *g_snap = NULL;
/* Where re-reading happens on RELOAD: the resolved -c / env / default
 * path. A getenv or argv pointer is stable for the process's lifetime;
 * RELOAD re-reads exactly the file this daemon started with. */
static const char *g_config_path = NULL;

static struct fsq_config_snap *cfg_acquire(void) {
    struct fsq_config_snap *snap;
    FSQ_LOCK(g_cfg_mu);
    g_snap->refs++;
    snap = g_snap;
    FSQ_UNLOCK(g_cfg_mu);
    return snap;
}

static void cfg_release(struct fsq_config_snap *snap) {
    int live;
    FSQ_LOCK(g_cfg_mu);
    if (--snap->refs > 0) { FSQ_UNLOCK(g_cfg_mu); return; }
    live = g_snap == snap;
    FSQ_UNLOCK(g_cfg_mu);
    if (!live) free(snap);
}

/* Publishes a copy as the current snapshot, freeing the previous one when
 * no borrower still holds it (and deferring when one does -- cfg_release
 * frees then). Startup and RELOAD both arrive here. */
static int cfg_publish(const struct fsq_config *cfg) {
    struct fsq_config_snap *snap = malloc(sizeof(*snap)), *old;
    if (!snap) return -1;
    snap->cfg = *cfg;
    snap->refs = 0;
    FSQ_LOCK(g_cfg_mu);
    old = g_snap;
    g_snap = snap;
    if (old && old->refs == 0) { FSQ_UNLOCK(g_cfg_mu); free(old); }
    else FSQ_UNLOCK(g_cfg_mu);
    return 0;
}

/* Platform-specific checks a config must pass before this daemon runs it. */
#ifdef _WIN32
static int validate_cfg(const struct fsq_config *cfg) {
    /* The config file carries provider secrets once reasoning_token /
     * enterprise_ledger_key are populated, so it must be as private as
     * the key file. */
    if (g_config_path && !key_file_private(g_config_path)) {
        fsq_log("ERROR", "config file %s grants access to Everyone, Authenticated Users or Users: restrict it to the service account", g_config_path);
        return -1;
    }
    if (!key_file_private(cfg->key_path)) {
        fsq_log("ERROR", "hmac_key_file %s grants access to Everyone, Authenticated Users or Users: restrict it to the service account", cfg->key_path);
        return -1;
    }
    return 0;
}
#else
static int validate_cfg(const struct fsq_config *cfg) {
    struct stat kst, cst;
    if (g_config_path && stat(g_config_path, &cst) == 0 && (cst.st_mode & 0007) != 0) {
        fsq_log("ERROR", "config file %s grants access to other users: remove world permissions", g_config_path);
        return -1;
    }
    if (stat(cfg->key_path, &kst) == 0 && (kst.st_mode & 0007) != 0) {
        fsq_log("ERROR", "hmac_key_file %s grants access to other users: remove world permissions", cfg->key_path);
        return -1;
    }
    return 0;
}
#endif

/* Loud, specific validation of the provider keys in a parsed config
 * (fractalsql_provider.h). A config-file edit is a deliberate act, so
 * unlike the environment fallback's historical silent clamps, garbage or
 * out-of-range values refuse the load/reload with a named key and the
 * expected range. Runs after validate_cfg: startup refuses to start and
 * RELOAD refuses to publish. */
static int validate_provider_cfg(const struct fsq_config *cfg) {
    uint32_t p = cfg->prov_present;
    struct {
        uint32_t    bit;
        const char *val;
        const char *name;
    } strs[] = {
        { FSQL_PROV_REASONING_PLUGIN, cfg->reasoning_plugin, "reasoning_plugin" },
        { FSQL_PROV_REASONING_URL,    cfg->reasoning_url,    "reasoning_url" },
        { FSQL_PROV_REASONING_TOKEN,  cfg->reasoning_token,  "reasoning_token" },
        { FSQL_PROV_REASONING_MODEL,  cfg->reasoning_model,  "reasoning_model" },
        { FSQL_PROV_EMBED_URL,        cfg->embed_url,        "embed_url" },
        { FSQL_PROV_EMBED_MODEL,      cfg->embed_model,      "embed_model" },
        { FSQL_PROV_THINK,            cfg->think,            "think" },
        { FSQL_PROV_THINK_PROVIDER,   cfg->think_provider,   "think_provider" },
        { FSQL_PROV_NATIVE_URL,       cfg->think_native_url, "think_native_url" },
        { FSQL_PROV_T2S_ALLOWED,      cfg->t2s_allowed_statements, "t2s_allowed_statements" },
        { FSQL_PROV_ENT_LIB,          cfg->enterprise_lib,          "enterprise_lib" },
        { FSQL_PROV_ENT_LEDGER_PATH,  cfg->enterprise_ledger_path,  "enterprise_ledger_path" },
        { FSQL_PROV_ENT_LEDGER_KEY,   cfg->enterprise_ledger_key,   "enterprise_ledger_key" },
    };
    for (size_t i = 0; i < sizeof(strs) / sizeof(strs[0]); i++) {
        if ((p & strs[i].bit) && strs[i].val[0] == '\0') {
            fsq_log("ERROR", "provider key %s: value must not be empty", strs[i].name);
            return -1;
        }
    }
    /* Upper bound is generous (no real provider's context window comes
     * close), but a bound still beats none: an unchecked value here was
     * the one provider integer with no ceiling, unlike t2s_max_attempts
     * right below -- strtol saturates an absurd/overflowing config value
     * to LONG_MAX rather than erroring, and LONG_MAX > 1 passed the old
     * ">= 1"-only check. */
    if ((p & FSQL_PROV_NUM_CTX) &&
        (cfg->think_num_ctx < 1 || cfg->think_num_ctx > 10000000)) {
        fsq_log("ERROR", "provider key think_num_ctx: must be an integer in [1,10000000] (got %ld)", cfg->think_num_ctx);
        return -1;
    }
    if ((p & FSQL_PROV_T2S_MAX_ATTEMPTS) &&
        (cfg->t2s_max_attempts < 1 || cfg->t2s_max_attempts > 10)) {
        fsq_log("ERROR", "provider key t2s_max_attempts: must be an integer in [1,10] (got %ld)", cfg->t2s_max_attempts);
        return -1;
    }
    if ((p & FSQL_PROV_T2S_ALLOWED) &&
        strcmp(cfg->t2s_allowed_statements, "select") != 0 &&
        strcmp(cfg->t2s_allowed_statements, "select_insert_update") != 0) {
        fsq_log("ERROR", "provider key t2s_allowed_statements: must be \"select\" or \"select_insert_update\"");
        return -1;
    }
    return 0;
}

/* Push the provider settings out of a parsed config into the three
 * consumers (fractalsql_provider.h). Pointers reference cfg's fixed
 * buffers; the consumers own deep copies. CHECK first (read-only: any
 * refusal aborts before any consumer mutates), then APPLY -- but a
 * mid-apply consumer failure (allocation) leaves the earlier consumers
 * updated while the reload as a whole is refused; each consumer's own
 * rollback keeps even that partial state internally consistent. */
static int daemon_check_provider(const struct fsq_config *cfg) {
    struct fsq_provider_cfg pc;
    memset(&pc, 0, sizeof(pc));
    pc.present = cfg->prov_present;
    pc.reasoning_plugin = cfg->reasoning_plugin;
    pc.reasoning_url = cfg->reasoning_url;
    pc.reasoning_token = cfg->reasoning_token;
    pc.reasoning_model = cfg->reasoning_model;
    pc.reasoning_allow_plaintext = cfg->reasoning_allow_plaintext;
    pc.embed_url = cfg->embed_url;
    pc.embed_model = cfg->embed_model;
    pc.think = cfg->think;
    pc.think_provider = cfg->think_provider;
    pc.think_native_url = cfg->think_native_url;
    pc.think_num_ctx = cfg->think_num_ctx;
    pc.t2s_max_attempts = cfg->t2s_max_attempts;
    pc.t2s_allowed_statements = cfg->t2s_allowed_statements;
    pc.t2s_use_review = cfg->t2s_use_review;
    pc.enterprise_lib = cfg->enterprise_lib;
    pc.enterprise_ledger_path = cfg->enterprise_ledger_path;
    pc.enterprise_ledger_key = cfg->enterprise_ledger_key;
    pc.enterprise_require_signature = cfg->enterprise_require_signature;

    if (validate_provider_cfg(cfg) != 0) return -1;
    if (fractalsql_cognition_check_provider(&pc) != 0 ||
        fractalsql_textsql_check_provider(&pc) != 0 ||
        fractalsql_enterprise_check_provider(&pc) != 0)
        return -1;
    return 0;
}

static int daemon_apply_provider(const struct fsq_config *cfg) {
    struct fsq_provider_cfg pc;
    char num_ctx_str[24];
    /* Keys whose value is on their provider face -- set names only,
     * never values: reasoning_token and enterprise_ledger_key are
     * plaintext credentials. */
    static const struct { uint32_t bit; const char *name; } keys[] = {
        { FSQL_PROV_REASONING_PLUGIN,    "reasoning_plugin" },
        { FSQL_PROV_REASONING_URL,       "reasoning_url" },
        { FSQL_PROV_REASONING_TOKEN,     "reasoning_token" },
        { FSQL_PROV_REASONING_MODEL,     "reasoning_model" },
        { FSQL_PROV_REASONING_PLAINTEXT, "reasoning_allow_plaintext" },
        { FSQL_PROV_EMBED_URL,           "embed_url" },
        { FSQL_PROV_EMBED_MODEL,         "embed_model" },
        { FSQL_PROV_THINK,               "think" },
        { FSQL_PROV_THINK_PROVIDER,      "think_provider" },
        { FSQL_PROV_NATIVE_URL,          "think_native_url" },
        { FSQL_PROV_NUM_CTX,             "think_num_ctx" },
        { FSQL_PROV_T2S_MAX_ATTEMPTS,    "t2s_max_attempts" },
        { FSQL_PROV_T2S_ALLOWED,         "t2s_allowed_statements" },
        { FSQL_PROV_T2S_USE_REVIEW,      "t2s_use_review" },
        { FSQL_PROV_ENT_LIB,             "enterprise_lib" },
        { FSQL_PROV_ENT_LEDGER_PATH,     "enterprise_ledger_path" },
        { FSQL_PROV_ENT_LEDGER_KEY,      "enterprise_ledger_key" },
        { FSQL_PROV_ENT_REQUIRE_SIG,     "enterprise_require_signature" },
    };
    /* Zeroed, not left uninitialized: when prov_present has no bits set
     * (no provider keys configured at all -- the common case), the
     * loop below never calls snprintf even once, and the %s in the
     * fsq_log call at the end of this function would otherwise read
     * this buffer's uninitialized stack contents as a C string. */
    char names[384] = { 0 };
    size_t off = 0;

    memset(&pc, 0, sizeof(pc));
    pc.present = cfg->prov_present;
    /* (strings/bools/longs exactly as in daemon_check_provider) */
    pc.reasoning_plugin = cfg->reasoning_plugin;
    pc.reasoning_url = cfg->reasoning_url;
    pc.reasoning_token = cfg->reasoning_token;
    pc.reasoning_model = cfg->reasoning_model;
    pc.reasoning_allow_plaintext = cfg->reasoning_allow_plaintext;
    pc.embed_url = cfg->embed_url;
    pc.embed_model = cfg->embed_model;
    pc.think = cfg->think;
    pc.think_provider = cfg->think_provider;
    pc.think_native_url = cfg->think_native_url;
    pc.think_num_ctx = cfg->think_num_ctx;
    pc.t2s_max_attempts = cfg->t2s_max_attempts;
    pc.t2s_allowed_statements = cfg->t2s_allowed_statements;
    pc.t2s_use_review = cfg->t2s_use_review;
    pc.enterprise_lib = cfg->enterprise_lib;
    pc.enterprise_ledger_path = cfg->enterprise_ledger_path;
    pc.enterprise_ledger_key = cfg->enterprise_ledger_key;
    pc.enterprise_require_signature = cfg->enterprise_require_signature;
    if (cfg->prov_present & FSQL_PROV_NUM_CTX) {
        snprintf(num_ctx_str, sizeof num_ctx_str, "%ld", cfg->think_num_ctx);
        pc.think_num_ctx_str = num_ctx_str;
    }

    if (fractalsql_cognition_apply_provider(&pc) != 0 ||
        fractalsql_textsql_apply_provider(&pc) != 0 ||
        fractalsql_enterprise_apply_provider(&pc) != 0)
        return -1;

    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (!(cfg->prov_present & keys[i].bit)) continue;
        int w = snprintf(names + off, sizeof(names) - off, "%s%s",
                         off ? ", " : "", keys[i].name);
        if (w < 0 || (size_t) w >= sizeof(names) - off) break;
        off += (size_t) w;
    }
    fsq_log("INFO", "provider settings applied (keys present: [%s], absent keys fall back to boot environment)", names);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Frame I/O                                                           */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
/* Per-connection idle timeout, set by the thread that serves the pipe. */
static FSQ_TLS DWORD t_io_timeout_ms = 300000;

static void fsq_set_idle(fsq_sock s, int secs) {
    (void) s;
    t_io_timeout_ms = (DWORD) secs * 1000u;
}

static void fsq_close(fsq_sock s) {
    if (FSQ_SOCK_VALID(s)) CloseHandle(s);
}

/* Overlapped transfer bounded by the idle timeout. Timeouts report EAGAIN,
 * the same errno the POSIX path reports, so the caller logs them alike. */
static int fsq_xfer(fsq_sock s, void *buf, DWORD n, int writing) {
    OVERLAPPED ov;
    DWORD got = 0;
    BOOL ok;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return -1;
    ok = writing ? WriteFile(s, buf, n, NULL, &ov) : ReadFile(s, buf, n, NULL, &ov);
    if (!ok) {
        if (GetLastError() != ERROR_IO_PENDING) { CloseHandle(ov.hEvent); return -1; }
        if (WaitForSingleObject(ov.hEvent, t_io_timeout_ms) != WAIT_OBJECT_0) {
            CancelIoEx(s, &ov);
            WaitForSingleObject(ov.hEvent, INFINITE);
            CloseHandle(ov.hEvent);
            errno = EAGAIN;
            return -1;
        }
    }
    ok = GetOverlappedResult(s, &ov, &got, FALSE);
    CloseHandle(ov.hEvent);
    return ok ? (int) got : -1;
}

static int read_all(fsq_sock s, uint8_t *p, size_t n) {
    while (n > 0) {
        int r = fsq_xfer(s, p, (DWORD) n, 0);
        if (r <= 0) return -1;
        p += r;
        n -= (size_t) r;
    }
    return 0;
}

static int write_all(fsq_sock s, const uint8_t *p, size_t n) {
    while (n > 0) {
        int w = fsq_xfer(s, (void *) p, (DWORD) n, 1);
        if (w <= 0) return -1;
        p += w;
        n -= (size_t) w;
    }
    return 0;
}
#else
static void fsq_set_idle(fsq_sock fd, int secs) {
    struct timeval idle;
    idle.tv_sec = secs;
    idle.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &idle, sizeof(idle));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &idle, sizeof(idle));
}

static void fsq_close(fsq_sock fd) {
    close(fd);
}

static int read_all(fsq_sock fd, uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        p += r;
        n -= (size_t) r;
    }
    return 0;
}

/* MSG_NOSIGNAL (suppress SIGPIPE on a write to a peer that already
 * closed) is Linux-only. Darwin has no such send() flag; the socket
 * itself is set SO_NOSIGPIPE instead, once, where it is created
 * (open_listener's accept() below). */
#ifndef MSG_NOSIGNAL
#  define MSG_NOSIGNAL 0
#endif

static int write_all(fsq_sock fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w;
        n -= (size_t) w;
    }
    return 0;
}
#endif

static void mac(const struct fsq_config *cfg, const uint8_t *hdr,
                const uint8_t *payload, size_t plen, uint8_t tag[FSQ_TAG_LEN]) {
    uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
    if (!msg) { memset(tag, 0, FSQ_TAG_LEN); return; }
    memcpy(msg, hdr, FSQ_HEADER_LEN);
    if (plen) memcpy(msg + FSQ_HEADER_LEN, payload, plen);
    fsq_hmac_sha256(cfg->key, cfg->key_len, msg, FSQ_HEADER_LEN + plen, tag);
    free(msg);
}

static int send_reply(fsq_sock fd, const struct fsq_config *cfg, const struct fsq_header *req,
                      const struct fsq_reply *rep) {
    uint32_t plen = 8 + rep->body_len;
    uint8_t *payload = malloc(plen);
    uint8_t hdr[FSQ_HEADER_LEN], tag[FSQ_TAG_LEN];
    struct fsq_header h;
    int rc;
    if (!payload) return -1;
    fsq_put_u32(payload, rep->status);
    fsq_put_u32(payload + 4, (uint32_t) rep->core_rc);
    if (rep->body_len) memcpy(payload + 8, rep->body, rep->body_len);

    memset(&h, 0, sizeof(h));
    h.version = FSQ_PROTOCOL_VERSION;
    h.opcode = req->opcode;
    h.flags = FSQ_FLAG_RESPONSE | (rep->status != FSQ_OK ? FSQ_FLAG_ERROR : 0);
    h.request_id = req->request_id;
    h.context = req->context;
    h.auth_len = FSQ_TAG_LEN;
    h.payload_len = plen;
    fsq_header_encode(hdr, &h);
    mac(cfg, hdr, payload, plen, tag);
    rc = write_all(fd, hdr, FSQ_HEADER_LEN) || write_all(fd, tag, FSQ_TAG_LEN) ||
         write_all(fd, payload, plen);
    free(payload);
    return rc ? -1 : 0;
}

static void set_text(struct fsq_reply *rep, uint32_t status, const char *text) {
    size_t n = strlen(text);
    if (n >= FSQ_MSG_MAX) n = FSQ_MSG_MAX - 1;
    rep->status = status;
    /* NUL-terminated (body_len still excludes it, wire format unchanged):
     * serve_connection logs a failed request's body with "%.200s", which
     * reads past the end of a buffer with no NUL to find. */
    rep->body = malloc(n + 1);
    if (!rep->body) { rep->body_len = 0; return; }
    memcpy(rep->body, text, n);
    rep->body[n] = '\0';
    rep->body_len = (uint32_t) n;
}

/* ------------------------------------------------------------------ */
/* Function table: generated by scripts/gen_udf.py                      */
/* ------------------------------------------------------------------ */

enum fsq_kind { FSQ_KIND_CTL, FSQ_KIND_STR, FSQ_KIND_INT, FSQ_KIND_REAL };

struct fsq_fn {
    const char *name;
    enum fsq_kind kind;
    void *init;
    void *deinit;
    void *main;
};

#include "daemon_udfs.h"

typedef char *(*fsq_str_fn)(UDF_INIT *, UDF_ARGS *, char *, unsigned long *, char *, char *);
typedef long long (*fsq_int_fn)(UDF_INIT *, UDF_ARGS *, char *, char *);
typedef double (*fsq_real_fn)(UDF_INIT *, UDF_ARGS *, char *, char *);
typedef void (*fsq_deinit_fn)(UDF_INIT *);

static const struct fsq_fn *find_fn(const char *name, uint32_t len) {
    for (size_t i = 0; i < sizeof(g_fn_table) / sizeof(g_fn_table[0]); i++)
        if (strlen(g_fn_table[i].name) == len && memcmp(g_fn_table[i].name, name, len) == 0)
            return &g_fn_table[i];
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Handles: one per statement, from UDF_INIT until UDF_DEINIT.          */
/* The adapter's init may park state in initid->ptr, so the UDF_INIT   */
/* and UDF_ARGS for a statement live here until its deinit.            */
/* ------------------------------------------------------------------ */

struct fsq_handle {
    uint64_t id;
    const struct fsq_fn *fn;
    UDF_INIT init;
    UDF_ARGS args;
    /* Owned copies of constant argument values, visible to init only. */
    char *const_buf[FSQ_MAX_ARGS];
    uint64_t owner;     /* connection that created the handle */
    /* CANCEL's flag (opcodes.def): read lock-free by the running call
     * itself and by the interrupt-hooked loops, written under
     * g_handles_mu (or by the atomic on the between-calls checkpoint). */
    fsq_atomic_int cancelled;
    struct fsq_handle *next;
};

static fsq_mutex g_handles_mu = FSQ_MUTEX_INIT;
static FSQ_TLS uint64_t t_conn = 0;   /* connection serving this thread */
/* The handle the interrupt-hooked computation loops run for, if any. The
 * loops are called on the same thread that serves the UDF_CALL, so the
 * hook reads this TLS pointer and its cancel flag (with no active call --
 * e.g. during INIT/DEINIT body execution -- or before the hook is
 * installed, polls report "not interrupted"). */
static FSQ_TLS struct fsq_handle *t_active_handle = NULL;
static struct fsq_handle *g_handles = NULL;
static uint64_t g_next_handle = 1;

/* The interruption hook installed at startup (src/fractalsql_interrupt.h):
 * nonzero aborts the polling loop. This is what makes CANCEL from another
 * connection reach a busy in-repo computation without any signal from the
 * caller. */
static int fsq_check_cancelled(void) {
    struct fsq_handle *h = t_active_handle;
    return h ? FSQ_ATOMIC_GET(&h->cancelled) : 0;
}

static enum Item_result wire_to_item(uint8_t t) {
    switch (t) {
        case FSQ_T_INT:     return INT_RESULT;
        case FSQ_T_REAL:    return REAL_RESULT;
        case FSQ_T_DECIMAL: return DECIMAL_RESULT;
        default:            return STRING_RESULT;
    }
}

static uint8_t item_to_wire(enum Item_result t) {
    switch (t) {
        case INT_RESULT:     return FSQ_T_INT;
        case REAL_RESULT:    return FSQ_T_REAL;
        case DECIMAL_RESULT: return FSQ_T_DECIMAL;
        default:             return FSQ_T_STRING;
    }
}

static void handle_free_args(struct fsq_handle *h) {
    for (uint32_t i = 0; i < FSQ_MAX_ARGS; i++) {
        free(h->const_buf[i]);
        h->const_buf[i] = NULL;
    }
    free(h->args.arg_type);
    free(h->args.args);
    free(h->args.lengths);
    free(h->args.maybe_null);
    h->args.arg_type = NULL;
    h->args.args = NULL;
    h->args.lengths = NULL;
    h->args.maybe_null = NULL;
}

/* Handles are sequential, so IDs are guessable. A connection may only reach
 * handles it created: a foreign ID is "not found", never a use-after-free
 * of another connection's statement. */
static struct fsq_handle *handle_find_locked(uint64_t id) {
    for (struct fsq_handle *h = g_handles; h; h = h->next)
        if (h->id == id && h->owner == t_conn) return h;
    return NULL;
}

struct fsq_arg {
    uint8_t type;
    uint8_t is_null;
    const uint8_t *bytes;
    uint32_t len;
};

static int parse_args(const uint8_t *p, uint32_t n, uint32_t nargs, struct fsq_arg *out) {
    uint32_t off = 0;
    for (uint32_t i = 0; i < nargs; i++) {
        uint32_t len;
        if (n - off < 6) return -1;
        out[i].type = p[off];
        out[i].is_null = p[off + 1];
        len = fsq_get_u32(p + off + 2);
        off += 6;
        if (n - off < len) return -1;
        out[i].len = len;
        out[i].bytes = p + off;
        off += len;
    }
    return off == n ? 0 : -1;
}

static void handle_init(const uint8_t *p, uint32_t n, struct fsq_reply *rep) {
    uint8_t namelen;
    const char *name;
    uint32_t nargs;
    const struct fsq_fn *f;
    struct fsq_handle *h;
    char msg[FSQ_MSG_MAX];
    bool failed;
    uint8_t *body;
    struct fsq_arg in[FSQ_MAX_ARGS];

    /* namelen u8, name[namelen], nargs u32, TLV args. */
    if (n < 1) { set_text(rep, FSQ_ERR_ARGS, "malformed init request"); return; }
    namelen = p[0];
    if (n < 1u + namelen + 4u) { set_text(rep, FSQ_ERR_ARGS, "malformed init request"); return; }
    name = (const char *) (p + 1);
    nargs = fsq_get_u32(p + 1 + namelen);
    if (nargs > FSQ_MAX_ARGS) { set_text(rep, FSQ_ERR_ARGS, "malformed init request"); return; }
    if (parse_args(p + 1 + namelen + 4, n - (1u + namelen + 4u), nargs, in) != 0) {
        set_text(rep, FSQ_ERR_ARGS, "malformed init request");
        return;
    }
    f = find_fn(name, namelen);
    if (!f) { set_text(rep, FSQ_ERR_NOTSUP, "unknown function"); return; }

    h = calloc(1, sizeof(*h));
    if (!h) { set_text(rep, FSQ_ERR_INTERNAL, "out of memory"); return; }
    h->fn = f;
    h->args.arg_count = nargs;
    h->args.arg_type = calloc(nargs ? nargs : 1, sizeof(enum Item_result));
    h->args.args = calloc(nargs ? nargs : 1, sizeof(char *));
    h->args.lengths = calloc(nargs ? nargs : 1, sizeof(unsigned long));
    h->args.maybe_null = calloc(nargs ? nargs : 1, 1);
    if (!h->args.arg_type || !h->args.args || !h->args.lengths || !h->args.maybe_null) {
        handle_free_args(h);
        free(h);
        set_text(rep, FSQ_ERR_INTERNAL, "out of memory");
        return;
    }
    for (uint32_t i = 0; i < nargs; i++) {
        enum Item_result t = wire_to_item(in[i].type);
        h->args.arg_type[i] = t;
        if (in[i].is_null) continue;
        /* A constant argument's value is visible to init in MariaDB, and the
         * adapter validates on it (for example fractal_search's k bounds). */
        h->const_buf[i] = malloc((size_t) in[i].len + 1);
        if (!h->const_buf[i]) {
            handle_free_args(h);
            free(h);
            set_text(rep, FSQ_ERR_INTERNAL, "out of memory");
            return;
        }
        if (t == INT_RESULT) {
            long long v;
            if (in[i].len != 8) { handle_free_args(h); free(h); set_text(rep, FSQ_ERR_ARGS, "malformed init request"); return; }
            v = (long long) fsq_get_u64(in[i].bytes);
            memcpy(h->const_buf[i], &v, 8);
            h->args.lengths[i] = 8;
        } else if (t == REAL_RESULT) {
            uint64_t bits;
            double d;
            if (in[i].len != 8) { handle_free_args(h); free(h); set_text(rep, FSQ_ERR_ARGS, "malformed init request"); return; }
            bits = fsq_get_u64(in[i].bytes);
            memcpy(&d, &bits, 8);
            memcpy(h->const_buf[i], &d, 8);
            h->args.lengths[i] = 8;
        } else {
            memcpy(h->const_buf[i], in[i].bytes, in[i].len);
            h->const_buf[i][in[i].len] = '\0';
            h->args.lengths[i] = in[i].len;
        }
        h->args.args[i] = h->const_buf[i];
    }

    msg[0] = '\0';
    failed = ((bool (*)(UDF_INIT *, UDF_ARGS *, char *)) f->init)(&h->init, &h->args, msg);
    if (failed) {
        handle_free_args(h);
        free(h);
        set_text(rep, FSQ_ERR_ARGS, msg[0] ? msg : "initialization failed");
        return;
    }

    FSQ_LOCK(g_handles_mu);
    h->id = g_next_handle++;
    h->owner = t_conn;
    h->next = g_handles;
    g_handles = h;
    FSQ_UNLOCK(g_handles_mu);

    /* Body: handle u64, max_length u32, maybe_null u8, nargs u32, types[nargs] u8. */
    rep->status = FSQ_OK;
    rep->body_len = 17 + nargs;
    body = calloc(rep->body_len, 1);
    if (!body) { set_text(rep, FSQ_ERR_INTERNAL, "out of memory"); return; }
    fsq_put_u64(body, h->id);
    fsq_put_u32(body + 8, (uint32_t) h->init.max_length);
    body[12] = h->init.maybe_null ? 1 : 0;
    fsq_put_u32(body + 13, nargs);
    for (uint32_t i = 0; i < nargs; i++) body[17 + i] = item_to_wire(h->args.arg_type[i]);
    rep->body = body;
}

static void tlv_result(struct fsq_reply *rep, uint8_t type, int is_null,
                       const uint8_t *bytes, uint32_t len) {
    rep->status = FSQ_OK;
    rep->body_len = 6 + len;
    rep->body = malloc(rep->body_len);
    if (!rep->body) { rep->body_len = 0; set_text(rep, FSQ_ERR_INTERNAL, "out of memory"); return; }
    rep->body[0] = type;
    rep->body[1] = (uint8_t) (is_null ? 1 : 0);
    fsq_put_u32(rep->body + 2, len);
    if (len) memcpy(rep->body + 6, bytes, len);
}

/* A CANCEL that arrived while this call was running is what aborted
 * it: surface the cancellation instead of a bare adapter error, and
 * consume the one-shot flag (so `h` must be writable), so the
 * statement's next row starts fresh (the between-calls checkpoint
 * consumes identically). */
static void core_fail(struct fsq_reply *rep, struct fsq_handle *h) {
    if (FSQ_ATOMIC_GET(&h->cancelled)) {
        FSQ_ATOMIC_SET(&h->cancelled, 0);
        fsq_log("INFO", "%s: cancelled mid-call", h->fn->name);
        set_text(rep, FSQ_ERR_BUSY, "cancelled");
        return;
    }
    fsq_log("WARN", "%s: adapter reported an error for this call", h->fn->name);
    set_text(rep, FSQ_ERR_CORE, "");
}

/* ------------------------------------------------------------------ */
/* Idempotency response cache (UDF_CALL, token-keyed)                   */
/* ------------------------------------------------------------------ */

/* A UDF_CALL whose header context u64 is nonzero carries the shim's
 * idempotency token; when the transport drops mid-flight (or the HMAC
 * check fails on the reply), the shim resends the SAME token and the
 * daemon answers from here instead of re-executing -- which is the only
 * safe move for stateful functions (ledger loads, diversify toggles...).
 * The cache is cross-connection on purpose: the resend nearly always
 * arrives on a NEW connection because the old socket is the thing that
 * died, so no per-connection map would ever be hit.
 *
 * Keyed by the token alone. Only FSQ_OK and FSQ_ERR_CORE responses are
 * cached: every other status is an effect-free rejection (ARGS/BUSY/
 * LIMIT/NOTSUP) that simply re-running the call reproduces. Token 0 is
 * never cached -- it is not a token.
 *
 * The ring is a fixed FIFO of FSQ_CACHE_ENTRIES slots under one mutex;
 * the aggregate byte cap bounds memory. This is process memory only: a
 * daemon restart loses the cache, and the shim's CSPRNG token base makes
 * any token from a previous mariadbd boot unable to reach a stale entry. */

#define FSQ_CACHE_ENTRIES   256
#define FSQ_CACHE_MAX_BYTES ((uint64_t) 64u * 1024u * 1024u)
#define FSQ_CACHE_ENTRY_MAX ((uint32_t) 8u * 1024u * 1024u)

struct fsq_cache_entry {
    uint64_t token;
    uint32_t status;
    int32_t  core_rc;
    uint32_t body_len;
    uint8_t *body;      /* NULL when the slot is empty */
};

static fsq_mutex g_cache_mu = FSQ_MUTEX_INIT;
static struct fsq_cache_entry g_cache[FSQ_CACHE_ENTRIES];
static size_t g_cache_next;     /* oldest slot; the next eviction/insertion target */
static uint64_t g_cache_bytes;

static struct fsq_cache_entry *cache_find_locked(uint64_t token) {
    for (size_t i = 0; i < FSQ_CACHE_ENTRIES; i++)
        if (g_cache[i].body && g_cache[i].token == token) return &g_cache[i];
    return NULL;
}

/* Returns 1 and fills rep when token has a cached response. The body is
 * cloned: rep->body is the caller's to free like any dispatch result.
 * An out-of-memory clone is reported as a miss -- the call re-executes,
 * which the retry classes say is safe for everything that got this far. */
static int cache_replay(uint64_t token, struct fsq_reply *rep) {
    struct fsq_cache_entry *e;
    uint32_t status, len;
    int32_t core_rc;
    uint8_t *body;
    FSQ_LOCK(g_cache_mu);
    e = cache_find_locked(token);
    if (!e) { FSQ_UNLOCK(g_cache_mu); return 0; }
    status = e->status; core_rc = e->core_rc; len = e->body_len;
    body = malloc(len ? len : 1);
    if (body && len) memcpy(body, e->body, len);
    FSQ_UNLOCK(g_cache_mu);
    if (!body) return 0;
    rep->status = status;
    rep->core_rc = core_rc;
    rep->body = body;
    rep->body_len = len;
    fsq_log("INFO", "UDF_CALL replayed from the idempotency cache (token %llu, %u bytes)",
            (unsigned long long) token, len);
    return 1;
}

static void cache_put(uint64_t token, const struct fsq_reply *rep) {
    uint32_t len = rep->body_len;
    uint8_t *copy;
    struct fsq_cache_entry *slot;
    if (token == 0 || len > FSQ_CACHE_ENTRY_MAX) return;
    copy = malloc(len ? len : 1);
    if (!copy) return;
    if (len) memcpy(copy, rep->body, len);

    FSQ_LOCK(g_cache_mu);
    if ((slot = cache_find_locked(token)) != NULL) {
        /* Same token answered again outside a retry (an operator re-sent
         * it deliberately): replace in place, ring order untouched. The
         * aggregate cap may transiently exceed FSQ_CACHE_MAX_BYTES here;
         * the next fresh insert's eviction loop trims it. */
        g_cache_bytes -= slot->body_len;
        free(slot->body);
    } else {
        /* Evict oldest-first until the aggregate cap admits the new body.
         * len is bounded by the 8 MiB entry cap against a 64 MiB total, so
         * emptying the ring always leaves room; the scan bound is a belt-
         * and-braces guard against an accounting slip turning this into a
         * spin, in which case the insert is skipped below. */
        for (size_t scanned = 0;
             g_cache_bytes + len > FSQ_CACHE_MAX_BYTES && scanned <= FSQ_CACHE_ENTRIES;
             scanned++) {
            struct fsq_cache_entry *ev = &g_cache[g_cache_next];
            if (ev->body) {
                g_cache_bytes -= ev->body_len;
                free(ev->body);
                ev->body = NULL;
            }
            g_cache_next = (g_cache_next + 1) % FSQ_CACHE_ENTRIES;
        }
        slot = &g_cache[g_cache_next];
        if (slot->body) {
            g_cache_bytes -= slot->body_len;
            free(slot->body);
        }
        g_cache_next = (g_cache_next + 1) % FSQ_CACHE_ENTRIES;
    }
    slot->token = token;
    slot->status = rep->status;
    slot->core_rc = rep->core_rc;
    slot->body_len = len;
    slot->body = copy;
    g_cache_bytes += len;
    FSQ_UNLOCK(g_cache_mu);
}

static void handle_call(uint64_t token, const uint8_t *p, uint32_t n, struct fsq_reply *rep) {
    uint8_t namelen;
    const char *name;
    uint64_t id;
    uint32_t nargs;
    struct fsq_handle *h;
    struct fsq_arg in[FSQ_MAX_ARGS];
    long long ivals[FSQ_MAX_ARGS];
    double rvals[FSQ_MAX_ARGS];
    char *bufs[FSQ_MAX_ARGS];
    uint32_t i;
    char is_null = 0, err = 0;

    memset(bufs, 0, sizeof(bufs));
    /* namelen u8, name[namelen], handle u64, nargs u32, TLV args. */
    if (n < 1) { set_text(rep, FSQ_ERR_ARGS, ""); return; }
    namelen = p[0];
    if (n < 1u + namelen + 12u) { set_text(rep, FSQ_ERR_ARGS, ""); return; }
    name = (const char *) (p + 1);
    id = fsq_get_u64(p + 1 + namelen);
    nargs = fsq_get_u32(p + 1 + namelen + 8);
    if (nargs > FSQ_MAX_ARGS ||
        parse_args(p + 1 + namelen + 12, n - (1u + namelen + 12u), nargs, in) != 0) {
        set_text(rep, FSQ_ERR_ARGS, "");
        return;
    }

    FSQ_LOCK(g_handles_mu);
    h = handle_find_locked(id);
    FSQ_UNLOCK(g_handles_mu);
    if (!h || strlen(h->fn->name) != namelen || memcmp(h->fn->name, name, namelen) != 0 ||
        (uint32_t) h->args.arg_count != nargs) {
        set_text(rep, FSQ_ERR_ARGS, "");
        return;
    }

    /* Between-calls cancellation checkpoint (SS11.4): a row-by-row statement
     * reuses this handle across many UDF_CALLs, so refusing to start the
     * next one here stops the remaining rows without touching the core. A
     * call already running when CANCEL arrived is instead stopped by the
     * interrupt-hooked loops (see opcodes.def's CANCEL entry). */
    if (FSQ_ATOMIC_GET(&h->cancelled)) {
        FSQ_ATOMIC_SET(&h->cancelled, 0);
        set_text(rep, FSQ_ERR_BUSY, "cancelled");
        return;
    }

    /* Idempotent resend: a stateful call's response, answered from the
     * cache rather than re-executed -- the resend arrives on some other,
     * newer connection, which is why the cache is not per-connection. */
    if (token != 0 && cache_replay(token, rep)) return;

    for (i = 0; i < nargs; i++) {
        enum Item_result t = h->args.arg_type[i];
        h->args.lengths[i] = 0;
        h->args.maybe_null[i] = 0;
        if (in[i].is_null) { h->args.args[i] = NULL; continue; }
        if (t == INT_RESULT) {
            if (in[i].len != 8) { set_text(rep, FSQ_ERR_ARGS, ""); goto done; }
            ivals[i] = (long long) fsq_get_u64(in[i].bytes);
            h->args.args[i] = (char *) &ivals[i];
            h->args.lengths[i] = 8;
        } else if (t == REAL_RESULT) {
            uint64_t bits;
            if (in[i].len != 8) { set_text(rep, FSQ_ERR_ARGS, ""); goto done; }
            bits = fsq_get_u64(in[i].bytes);
            memcpy(&rvals[i], &bits, 8);
            h->args.args[i] = (char *) &rvals[i];
            h->args.lengths[i] = 8;
        } else {
            bufs[i] = malloc((size_t) in[i].len + 1);
            if (!bufs[i]) { set_text(rep, FSQ_ERR_INTERNAL, ""); goto done; }
            if (in[i].len) memcpy(bufs[i], in[i].bytes, in[i].len);
            bufs[i][in[i].len] = '\0';
            h->args.args[i] = bufs[i];
            h->args.lengths[i] = in[i].len;
        }
    }

    /* The call itself starts here: from this point the interrupt hooks in
     * the in-repo loops (src/fractalsql_interrupt.h) consult THIS handle's
     * cancel flag for the duration. */
    t_active_handle = h;
    if (h->fn->kind == FSQ_KIND_STR) {
        size_t cap = (size_t) h->init.max_length + 1;
        char *result = malloc(cap);
        unsigned long len = 0;
        char *ret;
        if (!result) { set_text(rep, FSQ_ERR_INTERNAL, ""); goto done; }
        ret = ((fsq_str_fn) h->fn->main)(&h->init, &h->args, result, &len, &is_null, &err);
        if (err) {
            core_fail(rep, h);
        } else if (is_null) {
            tlv_result(rep, FSQ_T_STRING, 1, NULL, 0);
        } else if (len > h->init.max_length) {
            set_text(rep, FSQ_ERR_LIMIT, "");
        } else {
            tlv_result(rep, FSQ_T_STRING, 0, (const uint8_t *) (ret ? ret : result), (uint32_t) len);
        }
        free(result);
    } else if (h->fn->kind == FSQ_KIND_INT) {
        long long v = ((fsq_int_fn) h->fn->main)(&h->init, &h->args, &is_null, &err);
        uint8_t out[8];
        if (err) { core_fail(rep, h); }
        else {
            fsq_put_u64(out, (uint64_t) v);
            tlv_result(rep, FSQ_T_INT, is_null, out, 8);
        }
    } else if (h->fn->kind == FSQ_KIND_REAL) {
        double v = ((fsq_real_fn) h->fn->main)(&h->init, &h->args, &is_null, &err);
        uint64_t bits;
        uint8_t out[8];
        if (err) { core_fail(rep, h); }
        else {
            memcpy(&bits, &v, 8);
            fsq_put_u64(out, bits);
            tlv_result(rep, FSQ_T_REAL, is_null, out, 8);
        }
    } else {
        set_text(rep, FSQ_ERR_NOTSUP, "");
    }

    /* A replayable response outcome: remember it under this call's token.
     * FSQ_ERR_CORE is cached too (a stateful function erroring twice should
     * stay one execution); effect-free statuses are not. */
    if (token != 0 && (rep->status == FSQ_OK || rep->status == FSQ_ERR_CORE))
        cache_put(token, rep);

done:
    t_active_handle = NULL;
    for (i = 0; i < nargs; i++) free(bufs[i]);
}

static void handle_deinit(const uint8_t *p, uint32_t n, struct fsq_reply *rep) {
    uint64_t id;
    struct fsq_handle **link, *h = NULL;
    if (n < 8) { set_text(rep, FSQ_ERR_ARGS, ""); return; }
    id = fsq_get_u64(p);
    FSQ_LOCK(g_handles_mu);
    for (link = &g_handles; *link; link = &(*link)->next) {
        if ((*link)->id == id && (*link)->owner == t_conn) { h = *link; *link = h->next; break; }
    }
    FSQ_UNLOCK(g_handles_mu);
    if (h) {
        ((fsq_deinit_fn) h->fn->deinit)(&h->init);
        handle_free_args(h);
        free(h);
    }
    set_text(rep, FSQ_OK, "");
}

/* Unlike handle_find_locked, this does not restrict by owner: the whole
 * point is cancelling a statement from a different connection (an operator
 * on an admin connection, cancelling a stuck mariadbd backend's handle) --
 * the owning connection's thread is the one busy inside the call. Handle
 * ids are already sequential and guessable by design (see
 * handle_find_locked's comment); the worst a wrong guess does here is make
 * someone else's next row fail with ERR_BUSY, not read their data. */
static void handle_cancel(const uint8_t *p, uint32_t n, struct fsq_reply *rep) {
    uint64_t id;
    struct fsq_handle *h, *target = NULL;
    if (n < 8) { set_text(rep, FSQ_ERR_ARGS, ""); return; }
    id = fsq_get_u64(p);
    FSQ_LOCK(g_handles_mu);
    for (h = g_handles; h; h = h->next) {
        if (h->id == id) { target = h; FSQ_ATOMIC_SET(&target->cancelled, 1); break; }
    }
    FSQ_UNLOCK(g_handles_mu);
    set_text(rep, target ? FSQ_OK : FSQ_ERR_ARGS, target ? "" : "unknown handle");
}

/* RELOAD (fsqlctl reload; opcodes.def): re-parse the config file into a
 * fresh snapshot and swap it in. All-or-nothing: a failure at any point
 * below leaves the running configuration untouched. socket_path and
 * hmac_key_file changes are refused -- the shim reads its side once, at
 * first call, so applied changes there would strand every running
 * mariadbd; re-reading the same key file picks up a rotated key, which
 * breaks clients whose connections still use the old key until they
 * reconnect. The provider keys (reasoning/embed/think/t2s/enterprise,
 * fractalsql_provider.h) ARE reloadable live: validated, checked, then
 * pushed into the src/ consumers before the snapshot publishes. */
static void handle_reload(const struct fsq_config *cur, struct fsq_reply *rep) {
    struct fsq_config next;
    if (load_config(g_config_path, &next) != 0) {
        fsq_log("WARN", "reload: re-reading %s failed; keeping the running configuration",
                g_config_path ? g_config_path : "(unset)");
        set_text(rep, FSQ_ERR_ARGS, "reload failed: config file unreadable");
        return;
    }
    if (strcmp(next.socket_path, cur->socket_path) != 0 ||
        strcmp(next.key_path, cur->key_path) != 0) {
        fsq_log("WARN", "reload: socket_path/hmac_key_file changed in %s; that requires a restart",
                g_config_path ? g_config_path : "(unset)");
        set_text(rep, FSQ_ERR_ARGS, "socket_path and hmac_key_file changes require a restart");
        return;
    }
    if (validate_cfg(&next) != 0) {
        fsq_log("WARN", "reload: the new configuration would be refused at startup; keeping the running configuration");
        set_text(rep, FSQ_ERR_ARGS, "reload failed: key/config file permissions rejected");
        return;
    }
    /* Provider settings: loud daemon-side validation, then the consumers'
     * cross-state checks (read-only), all BEFORE anything is rebuilt or
     * applied below. A refusal here keeps the running configuration. */
    if (daemon_check_provider(&next) != 0) {
        fsq_log("WARN", "reload: provider settings rejected; keeping the running configuration");
        set_text(rep, FSQ_ERR_ARGS, "reload failed: provider settings rejected (see the daemon log)");
        return;
    }
#ifdef _WIN32
    {
        int sids_changed = next.n_allowed != cur->n_allowed;
        for (size_t i = 0; !sids_changed && i < next.n_allowed; i++)
            sids_changed = _stricmp(next.allowed_sids[i], cur->allowed_sids[i]) != 0;
        if (sids_changed && build_pipe_sd(&next) != 0) {
            fsq_log("WARN", "reload: cannot rebuild the pipe security descriptor from the new allowed_pipe_sid; keeping the running configuration");
            set_text(rep, FSQ_ERR_ARGS, "reload failed: cannot rebuild the pipe security descriptor");
            return;
        }
        /* If the list changed, g_pipe_sd now points at the new descriptor
         * while this reload could still fail below -- harmless: the new SD
         * reflects only allow-list entries the new config carries anyway. */
        if (next.log_path[0] && strcmp(next.log_path, cur->log_path) != 0) {
            FILE *nf = fopen(next.log_path, "a");
            if (!nf) {
                fsq_log("WARN", "reload: cannot open the new log file %s; keeping the running configuration", next.log_path);
                set_text(rep, FSQ_ERR_ARGS, "reload failed: cannot open the new log file");
                return;
            }
            /* The old FILE* is deliberately left open, not fclose()d: a
             * concurrent fsq_log on another connection thread may be
             * mid-write to it. Closing under the writer is a crash, a
             * bounded stale-stream leak is not. New lines go to the new
             * file from here on. */
            g_logf = nf;
        }
    }
#else
    /* POSIX logs to stderr (the container runtime collects it); log_file
     * is parsed into the config but carries no runtime effect here. */
#endif
    /* Apply the provider push AFTER the SD/log swap, BEFORE publishing:
     * each consumer swaps its effective settings under its own lock (with
     * per-consumer rollback) and clears its tiers' plugin-loaded flags;
     * a new/changed plugin or enterprise lib path is loaded on the tier's
     * NEXT call, naming its path in that call's error if it fails -- a
     * reload itself never attempts a load. */
    if (daemon_apply_provider(&next) != 0) {
        fsq_log("WARN", "reload: applying provider settings failed; keeping the running configuration");
        set_text(rep, FSQ_ERR_ARGS, "reload failed: applying provider settings (see the daemon log)");
        return;
    }
    if (cfg_publish(&next) != 0) {
        set_text(rep, FSQ_ERR_INTERNAL, "out of memory");
        return;
    }
    fsq_log("INFO", "reload: configuration reloaded (max_connections=%d, idle_timeout_secs=%d, allowed=%zu)",
            next.max_connections, next.idle_timeout_secs, next.n_allowed);
    set_text(rep, FSQ_OK, "reloaded");
}

static void dispatch(const struct fsq_config *cfg, const struct fsq_header *h,
                     const uint8_t *payload, uint32_t plen, struct fsq_reply *rep) {
    memset(rep, 0, sizeof(*rep));
    switch (h->opcode) {
        case FSQ_OP_PING: {
            uint8_t v[2];
            fsq_put_u16(v, FSQ_PROTOCOL_VERSION);
            rep->status = FSQ_OK;
            rep->body = malloc(2);
            if (rep->body) { memcpy(rep->body, v, 2); rep->body_len = 2; }
            return;
        }
        case FSQ_OP_VERSION: {
            char text[64];
            snprintf(text, sizeof(text), "fractalsqld %s protocol %u", FSQL_DAEMON_VERSION, FSQ_PROTOCOL_VERSION);
            set_text(rep, FSQ_OK, text);
            return;
        }
        case FSQ_OP_UDF_INIT:
            handle_init(payload, plen, rep);
            return;
        case FSQ_OP_UDF_CALL:
            handle_call(h->context, payload, plen, rep);
            return;
        case FSQ_OP_UDF_DEINIT:
            handle_deinit(payload, plen, rep);
            return;
        case FSQ_OP_CANCEL:
            handle_cancel(payload, plen, rep);
            return;
        case FSQ_OP_RELOAD:
            /* Spec'd as a payload-less request: anything attached is a
             * malformed reload, refused without touching the running
             * config (future revisions could carry options here). */
            if (plen != 0) { set_text(rep, FSQ_ERR_ARGS, "RELOAD takes no payload"); return; }
            handle_reload(cfg, rep);
            return;
        default:
            set_text(rep, FSQ_ERR_NOTSUP, "");
            return;
    }
}

/* ------------------------------------------------------------------ */
/* Connections                                                         */
/* ------------------------------------------------------------------ */

struct conn_arg {
    fsq_sock fd;
    /* No config pointer here: the serving thread borrows the current
     * snapshot itself on entry (see serve_connection). */
};

/* Fills peer with a log-safe description of the caller and reports whether
 * the caller is on the allow-list, against allowed_uids (allowed_pipe_sid
 * on Windows). Linux checks SO_PEERCRED/struct ucred; Darwin has neither,
 * so it uses getpeereid() instead. Windows reads the client's token off
 * its process (by PID, via GetNamedPipeClientProcessId), falling back to
 * ImpersonateNamedPipeClient when the process can't be opened (see the
 * comment at the fallback below); impersonation needs SeImpersonatePrivilege
 * -- a privilege a service logon holds by default but a plain interactive
 * account lacks, even one in Administrators (UAC gives it a filtered
 * token). So under an interactive daemon, a cross-account client can only
 * be vetted when its process is openable. */
static int peer_allowed(fsq_sock fd, const struct fsq_config *cfg, char *peer, size_t peerlen) {
#ifdef _WIN32
    ULONG pid = 0;
    HANDLE proc = NULL, tok = NULL;
    DWORD need = 0;
    TOKEN_USER *tu = NULL;
    char *sidstr = NULL;
    int ok = 0;
    peer[0] = '\0';
    if (!GetNamedPipeClientProcessId(fd, &pid)) {
        snprintf(peer, peerlen, "unknown peer (pid lookup failed, error %lu)",
                 (unsigned long) GetLastError());
        return 0;
    }
    proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD) pid);
    if (!proc) {
        DWORD open_err = GetLastError();
        /* Cross-service open can be refused outright: a service token's
         * default DACL grants process-query rights to its OWN service SID
         * and to SYSTEM/Administrators, and nothing else -- confirmed
         * live: the daemon (LOCAL SERVICE) could not open a mariadbd
         * running as a different NT SERVICE\<name> account (error 5), so
         * it refused every connection from that server and the shim saw
         * only "bad response frame from fractalsqld". Fall back to
         * impersonating the pipe client: the connection has already
         * passed the pipe DACL (which grants only the allow-listed
         * SIDs), service logons hold SeImpersonatePrivilege by default,
         * and this obtains the caller's token user -- the same data the
         * OpenProcess+OpenProcessToken path above would have provided --
         * so the allow-list comparison is unchanged. The header
         * comment's interactive-daemon caveat still applies: without
         * SeImpersonatePrivilege the fallback refuses and the peer
         * string below says exactly what failed. */
        if (ImpersonateNamedPipeClient(fd)) {
            if (OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, FALSE, &tok) && tok) {
                GetTokenInformation(tok, TokenUser, NULL, 0, &need);
                tu = malloc(need ? need : 1);
                if (tu && GetTokenInformation(tok, TokenUser, tu, need, &need) &&
                    ConvertSidToStringSidA(tu->User.Sid, &sidstr)) {
                    snprintf(peer, peerlen, "pid %lu sid %s",
                             (unsigned long) pid, sidstr);
                    for (size_t i = 0; i < cfg->n_allowed && !ok; i++)
                        if (_stricmp(cfg->allowed_sids[i], sidstr) == 0) ok = 1;
                    LocalFree(sidstr);
                }
                free(tu);
                tu = NULL;
                CloseHandle(tok);
                tok = NULL;
            }
            RevertToSelf();
        }
        if (peer[0] == '\0') {
            snprintf(peer, peerlen,
                     "pid %lu (process open failed, error %lu, impersonation fallback refused, error %lu)",
                     (unsigned long) pid,
                     (unsigned long) open_err,
                     (unsigned long) GetLastError());
        }
        return ok;
    }
    if (OpenProcessToken(proc, TOKEN_QUERY, &tok)) {
        GetTokenInformation(tok, TokenUser, NULL, 0, &need);
        tu = malloc(need ? need : 1);
        if (tu && GetTokenInformation(tok, TokenUser, tu, need, &need) &&
            ConvertSidToStringSidA(tu->User.Sid, &sidstr)) {
            snprintf(peer, peerlen, "pid %lu sid %s", (unsigned long) pid, sidstr);
            for (size_t i = 0; i < cfg->n_allowed && !ok; i++)
                if (_stricmp(cfg->allowed_sids[i], sidstr) == 0) ok = 1;
            LocalFree(sidstr);
        }
        free(tu);
        CloseHandle(tok);
    }
    CloseHandle(proc);
    if (peer[0] == '\0') snprintf(peer, peerlen, "pid %lu (token lookup failed, error %lu)",
                                   (unsigned long) pid, (unsigned long) GetLastError());
    return ok;
#elif defined(__APPLE__)
    /* Darwin has no SO_PEERCRED/struct ucred (that pair is Linux-only).
     * getpeereid() is the BSD equivalent: it reads the credentials of
     * the process on the other end of a connected AF_UNIX socket
     * directly, with no setsockopt dance and no special privilege. */
    uid_t euid;
    gid_t egid;
    int ok = 0;
    if (getpeereid(fd, &euid, &egid) != 0) {
        snprintf(peer, peerlen, "unknown peer");
        return 0;
    }
    snprintf(peer, peerlen, "uid %ld", (long) euid);
    for (size_t i = 0; i < cfg->n_allowed; i++)
        if (cfg->allowed_uids[i] == euid) ok = 1;
    return ok;
#else
    struct ucred cred;
    socklen_t len = sizeof(cred);
    int ok = 0;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) {
        snprintf(peer, peerlen, "unknown peer");
        return 0;
    }
    snprintf(peer, peerlen, "uid %ld", (long) cred.uid);
    for (size_t i = 0; i < cfg->n_allowed; i++)
        if (cfg->allowed_uids[i] == cred.uid) ok = 1;
    return ok;
#endif
}

static fsq_mutex g_conn_mu = FSQ_MUTEX_INIT;
static int g_conns = 0;
static uint64_t g_next_conn = 1;

static uint64_t next_conn_id(void) {
    uint64_t id;
    FSQ_LOCK(g_conn_mu);
    id = g_next_conn++;
    FSQ_UNLOCK(g_conn_mu);
    return id;
}

static void conn_released(void) {
    FSQ_LOCK(g_conn_mu);
    g_conns--;
    FSQ_UNLOCK(g_conn_mu);
}

/* A connection that drops without UDF_DEINIT must not keep its handles
 * forever. Each handle is freed through its own deinit, as UDF_DEINIT does. */
static void handle_release_owner(uint64_t conn) {
    struct fsq_handle *list = NULL, **link, *h;
    int released = 0;
    FSQ_LOCK(g_handles_mu);
    for (link = &g_handles; *link;) {
        if ((*link)->owner == conn) {
            h = *link;
            *link = h->next;
            h->next = list;
            list = h;
        } else {
            link = &(*link)->next;
        }
    }
    FSQ_UNLOCK(g_handles_mu);
    while (list) {
        h = list;
        list = h->next;
        ((fsq_deinit_fn) h->fn->deinit)(&h->init);
        handle_free_args(h);
        free(h);
        released++;
    }
    if (released)
        fsq_log("INFO", "released %d statement handle(s) from connection %llu",
                released, (unsigned long long) conn);
}

static FSQ_THREAD_RET serve_connection(void *arg) {
    struct conn_arg *ca = arg;
    fsq_sock fd = ca->fd;
    /* Borrow the current snapshot: idle timeout, vetting and this
     * connection's HMACs all come from it, and RELOAD leaves the frames
     * of an established connection on its borrowed (old) key. */
    struct fsq_config_snap *snap = cfg_acquire();
    const struct fsq_config *cfg = &snap->cfg;
    uint8_t hdr[FSQ_HEADER_LEN], tag[FSQ_TAG_LEN], want[FSQ_TAG_LEN];
    struct fsq_header h;
    char peer[FSQ_PEER_MAX];
    free(ca);

    t_conn = next_conn_id();
    fsq_set_idle(fd, cfg->idle_timeout_secs);

    if (!peer_allowed(fd, cfg, peer, sizeof(peer))) {
        fsq_log("WARN", "connection from %s refused: not in the allow-list", peer);
        fsq_close(fd);
        conn_released();
        cfg_release(snap);
        return FSQ_THREAD_EXIT;
    }

    for (;;) {
        uint8_t *payload = NULL;
        struct fsq_reply rep;
        if (read_all(fd, hdr, FSQ_HEADER_LEN) != 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                fsq_log("INFO", "connection %llu from %s idle for %d s, closing",
                        (unsigned long long) t_conn, peer, cfg->idle_timeout_secs);
            break;
        }
        if (fsq_header_decode(hdr, &h) != 0) {
            fsq_log("WARN", "connection %llu from %s sent a malformed header",
                    (unsigned long long) t_conn, peer);
            break;
        }
        if (h.version != FSQ_PROTOCOL_VERSION || h.auth_len != FSQ_TAG_LEN) {
            fsq_log("WARN", "connection %llu from %s sent protocol version %u",
                    (unsigned long long) t_conn, peer, (unsigned) h.version);
            break;
        }
        if (h.payload_len > FSQ_MAX_PAYLOAD) {
            fsq_log("WARN", "connection %llu from %s sent a %u-byte payload over the limit",
                    (unsigned long long) t_conn, peer, (unsigned) h.payload_len);
            break;
        }
        if (h.flags & FSQ_FLAG_RESPONSE) break;
        if (read_all(fd, tag, FSQ_TAG_LEN) != 0) break;
        if (h.payload_len) {
            payload = malloc(h.payload_len);
            if (!payload || read_all(fd, payload, h.payload_len) != 0) { free(payload); break; }
        }
        mac(cfg, hdr, payload, h.payload_len, want);
        if (!fsq_ct_equal(tag, want, FSQ_TAG_LEN)) {
            fsq_log("WARN", "connection %llu from %s failed authentication (opcode 0x%04x, request %u)",
                    (unsigned long long) t_conn, peer, (unsigned) h.opcode, (unsigned) h.request_id);
            free(payload);
            break;
        }

        dispatch(cfg, &h, payload, h.payload_len, &rep);
        free(payload);
        if (rep.status != FSQ_OK)
            fsq_log("WARN", "opcode 0x%04x failed: status %u, core rc %d, %.200s",
                    (unsigned) h.opcode, (unsigned) rep.status, (int) rep.core_rc,
                    rep.body_len ? (const char *) rep.body : "");
        if (send_reply(fd, cfg, &h, &rep) != 0) {
            fsq_log("WARN", "connection %llu: could not send reply, closing",
                    (unsigned long long) t_conn);
            free(rep.body);
            break;
        }
        free(rep.body);
    }
    handle_release_owner(t_conn);
    fsq_close(fd);
    conn_released();
    cfg_release(snap);
    return FSQ_THREAD_EXIT;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

static void log_exit(void) {
    fsq_log("INFO", "process exiting");
}

/* Signal-number to name lookup by table (not by index): the C signal
 * macros' values differ per platform (e.g. on Windows SIGABRT==3,
 * SIGSEGV==11; on Linux SIGUSR1==10 and SIGSEGV==11), so indexing an
 * array by `sig` misnames or falls off the end exactly when it matters
 * -- in a crash we have one chance to print the right name. */
static const char *fsq_sig_name(int sig) {
    static const struct { int num; const char *name; } names[] = {
        { SIGINT, "SIGINT" },   { SIGILL, "SIGILL" },  { SIGABRT, "SIGABRT" },
        { SIGFPE, "SIGFPE" },   { SIGSEGV, "SIGSEGV" }, { SIGTERM, "SIGTERM" },
#ifdef SIGHUP
        { SIGHUP, "SIGHUP" },
#endif
#ifdef SIGQUIT
        { SIGQUIT, "SIGQUIT" },
#endif
#ifdef SIGTRAP
        { SIGTRAP, "SIGTRAP" },
#endif
#ifdef SIGBUS
        { SIGBUS, "SIGBUS" },
#endif
#ifdef SIGPIPE
        { SIGPIPE, "SIGPIPE" },
#endif
    };
    size_t i;
    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        if (names[i].num == sig) return names[i].name;
    return "fatal signal";
}

#ifdef _WIN32
static PSECURITY_DESCRIPTOR g_pipe_sd = NULL;

/* The key file's DACL must not grant anything to Everyone, Authenticated
 * Users or BUILTIN\Users: the Windows counterpart of the POSIX mode check. */
static int key_file_private(const char *path) {
    static const char *broad[] = { "S-1-1-0", "S-1-5-11", "S-1-5-32-545" };
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR sd = NULL;
    ACL_SIZE_INFORMATION info;
    int ok = 1;
    if (GetNamedSecurityInfoA((LPSTR) path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                              NULL, NULL, &dacl, NULL, &sd) != ERROR_SUCCESS) return 0;
    if (!dacl || !GetAclInformation(dacl, &info, sizeof(info), AclSizeInformation)) {
        LocalFree(sd);
        return 0;
    }
    for (DWORD i = 0; i < info.AceCount && ok; i++) {
        LPVOID ace = NULL;
        PSID sid;
        if (!GetAce(dacl, i, &ace)) { ok = 0; break; }
        if (((ACE_HEADER *) ace)->AceType != ACCESS_ALLOWED_ACE_TYPE) continue;
        sid = (PSID) &((ACCESS_ALLOWED_ACE *) ace)->SidStart;
        for (size_t j = 0; j < sizeof(broad) / sizeof(broad[0]); j++) {
            PSID bsid = NULL;
            if (ConvertStringSidToSidA(broad[j], &bsid)) {
                if (EqualSid(sid, bsid)) ok = 0;
                LocalFree(bsid);
            }
        }
    }
    LocalFree(sd);
    return ok;
}

static void on_fatal(int sig) {
    fprintf(stderr, "fractalsqld[%ld] FATAL %s (%d), exiting\n", fsq_pid(), fsq_sig_name(sig), sig);
    fflush(stderr);
    signal(sig, SIG_DFL);
    raise(sig);
}

static HANDLE g_stop_event = NULL;

static BOOL WINAPI on_console_event(DWORD ev) {
    (void) ev;
    fsq_log("INFO", "stop requested by console control event");
    SetEvent(g_stop_event);
    return TRUE;
}

/* The pipe DACL grants read and write to the allow-listed SIDs and nobody
 * else. Named pipe instances are created with REJECT_REMOTE_CLIENTS.
 *
 * The daemon's own account is granted too: it must keep matching this pipe
 * name with new instances after the first one is handed off to a client
 * thread (run_listener's retry loop), and creating instance #2 and later
 * goes through the DACL on the existing pipe object, which the first
 * CreateNamedPipe established. Whatever account the daemon runs as (NT
 * AUTHORITY\LocalService for the service, typically not in the
 * allow-list, which names the *server's* service SID) would otherwise
 * open the existing pipe for that creation, fail with access denied, and
 * log "cannot create pipe instance (error 5), retrying" on every
 * connection. */
static int build_pipe_sd(const struct fsq_config *cfg) {
    static char sddl[FSQ_SDDL_MAX];
    char own_sid[FSQ_SID_MAX];
    size_t n = (size_t) snprintf(sddl, sizeof(sddl), "D:P");
    for (size_t i = 0; i < cfg->n_allowed; i++) {
        int w = snprintf(sddl + n, sizeof(sddl) - n, "(A;;GRGW;;;%s)", cfg->allowed_sids[i]);
        if (w < 0 || (size_t) w >= sizeof(sddl) - n) return -1;
        n += (size_t) w;
    }
    if (process_user_sid(own_sid, sizeof(own_sid)) == 0) {
        int w = snprintf(sddl + n, sizeof(sddl) - n, "(A;;GRGW;;;%s)", own_sid);
        if (w < 0 || (size_t) w >= sizeof(sddl) - n) return -1;
        n += (size_t) w;
    } else {
        /* Local-service accounts resolve fine; this only fires if the
         * token is unusual enough to defeat OpenProcessToken itself, in
         * which case the retry loop below would spin on error 5 forever
         * -- a loud log line beats a silent one. */
        fsq_log("WARN", "could not resolve the daemon's own SID; the pipe DACL lacks it and second pipe instances may fail to create");
    }
    return ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl, SDDL_REVISION_1, &g_pipe_sd, NULL) ? 0 : -1;
}

static HANDLE create_pipe_instance(const char *name, DWORD extra_flags) {
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = g_pipe_sd;
    sa.bInheritHandle = FALSE;
    return CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | extra_flags,
                            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                            PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, &sa);
}

static int pipe_wait_client(HANDLE h) {
    OVERLAPPED ov;
    DWORD got = 0;
    int ok = 0;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return 0;
    if (ConnectNamedPipe(h, &ov)) {
        ok = 1;
    } else if (GetLastError() == ERROR_PIPE_CONNECTED) {
        ok = 1;
    } else if (GetLastError() == ERROR_IO_PENDING) {
        HANDLE waits[2];
        waits[0] = ov.hEvent;
        waits[1] = g_stop_event;
        if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) {
            ok = GetOverlappedResult(h, &ov, &got, FALSE) ? 1 : 0;
        } else {
            CancelIoEx(h, &ov);
            WaitForSingleObject(ov.hEvent, INFINITE);
        }
    }
    CloseHandle(ov.hEvent);
    return ok;
}

/* Accept loop. The next pipe instance is created before the current one is
 * handed to its thread, so a client never finds the name with no listener.
 * socket_path cannot change while the daemon runs (RELOAD refuses that),
 * so the instance name comes from one long-held borrow; the connection
 * limit is re-read per accept so a reload applies it to new connections. */
static int run_listener(void) {
    struct fsq_config_snap *lsnap = cfg_acquire();
    const struct fsq_config *cfg = &lsnap->cfg;
    HANDLE cur = create_pipe_instance(cfg->socket_path, FILE_FLAG_FIRST_PIPE_INSTANCE);
    if (cur == INVALID_HANDLE_VALUE) {
        fsq_log("ERROR", "cannot create pipe %s (error %lu): another fractalsqld may be running",
                cfg->socket_path, (unsigned long) GetLastError());
        cfg_release(lsnap);
        return -1;
    }
    fsq_log("INFO", "fractalsqld %s listening on %s (max_connections=%d, idle_timeout_secs=%d, allowed_sids=%zu)",
            FSQL_DAEMON_VERSION, cfg->socket_path, cfg->max_connections, cfg->idle_timeout_secs, cfg->n_allowed);
    for (;;) {
        HANDLE next;
        struct conn_arg *ca;
        if (WaitForSingleObject(g_stop_event, 0) == WAIT_OBJECT_0) break;
        uintptr_t th;
        int over;
        if (cur == INVALID_HANDLE_VALUE) {
            cur = create_pipe_instance(cfg->socket_path, 0);
            if (cur == INVALID_HANDLE_VALUE) {
                fsq_log("ERROR", "cannot create pipe instance (error %lu), retrying", (unsigned long) GetLastError());
                FSQ_SLEEP_MS(100);
                continue;
            }
        }
        if (!pipe_wait_client(cur)) {
            CloseHandle(cur);
            cur = INVALID_HANDLE_VALUE;
            continue;
        }
        next = create_pipe_instance(cfg->socket_path, 0);
        {
            struct fsq_config_snap *ssnap = cfg_acquire();
            over = g_conns >= ssnap->cfg.max_connections;
            cfg_release(ssnap);
        }
        FSQ_LOCK(g_conn_mu);
        if (!over) g_conns++;
        FSQ_UNLOCK(g_conn_mu);
        if (over) {
            fsq_log("WARN", "connection refused: max_connections reached");
            CloseHandle(cur);
        } else {
            ca = malloc(sizeof(*ca));
            if (!ca) { conn_released(); CloseHandle(cur); }
            else {
                ca->fd = cur;
                th = _beginthreadex(NULL, 0, serve_connection, ca, 0, NULL);
                if (!th) {
                    fsq_log("ERROR", "cannot start a thread for a connection (errno %d)", errno);
                    free(ca); conn_released(); CloseHandle(cur);
                } else {
                    CloseHandle((HANDLE) th);
                }
            }
        }
        cur = next;
    }
    if (cur != INVALID_HANDLE_VALUE) CloseHandle(cur);
    fsq_log("INFO", "shutting down: no longer accepting connections");
    cfg_release(lsnap);
    return 0;
}
#else
static void on_fatal(int sig) {
    char line[96];
    int n = snprintf(line, sizeof(line), "fractalsqld[%ld] FATAL %s (%d), exiting\n", fsq_pid(), fsq_sig_name(sig), sig);
    if (n > 0) { ssize_t w = write(STDERR_FILENO, line, (size_t) n); (void) w; }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void on_signal(int sig) {
    (void) sig;
    g_stop = 1;
    if (FSQ_SOCK_VALID(g_listen_fd)) close(g_listen_fd);
}

static int open_listener(const struct fsq_config *cfg) {
    struct sockaddr_un sa;
    struct stat st;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (stat(cfg->socket_path, &st) == 0 && S_ISSOCK(st.st_mode)) unlink(cfg->socket_path);
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, cfg->socket_path);
    if (bind(fd, (struct sockaddr *) &sa, sizeof(sa)) != 0) { close(fd); return -1; }
    chmod(cfg->socket_path, 0660);
    if (listen(fd, 64) != 0) { close(fd); unlink(cfg->socket_path); return -1; }
    return fd;
}

static void run_listener(void) {
    struct fsq_config_snap *lsnap = cfg_acquire();
    const struct fsq_config *cfg = &lsnap->cfg;
    fsq_log("INFO", "fractalsqld %s listening on %s (max_connections=%d, idle_timeout_secs=%d, allowed_uids=%zu)",
            FSQL_DAEMON_VERSION, cfg->socket_path, cfg->max_connections, cfg->idle_timeout_secs, cfg->n_allowed);
    cfg_release(lsnap);
    while (!g_stop) {
        int fd = accept(g_listen_fd, NULL, NULL);
        pthread_t tid;
        struct conn_arg *ca;
        int over;
        if (fd < 0) {
            if (g_stop) break;
            if (errno == EINTR || errno == ECONNABORTED || errno == EPROTO) continue;
            if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) {
                fsq_log("WARN", "accept: %s, backing off", strerror(errno));
                FSQ_SLEEP_MS(100);
                continue;
            }
            fsq_log("ERROR", "accept failed: %s", strerror(errno));
            break;
        }
#ifdef __APPLE__
        { int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); }
#endif
        {
            /* Re-read the limit per accept, so a reload applies it to the
             * next connection rather than whenever this loop restarted. */
            struct fsq_config_snap *ssnap = cfg_acquire();
            over = g_conns >= ssnap->cfg.max_connections;
            cfg_release(ssnap);
        }
        FSQ_LOCK(g_conn_mu);
        if (!over) g_conns++;
        FSQ_UNLOCK(g_conn_mu);
        if (over) {
            fsq_log("WARN", "connection refused: max_connections reached");
            close(fd);
            continue;
        }
        ca = malloc(sizeof(*ca));
        if (!ca) { conn_released(); close(fd); continue; }
        ca->fd = fd;
        if (pthread_create(&tid, NULL, serve_connection, ca) != 0) {
            fsq_log("ERROR", "cannot start a thread for a connection: %s", strerror(errno));
            free(ca); conn_released(); close(fd); continue;
        }
        pthread_detach(tid);
    }
    fsq_log("INFO", "shutting down: no longer accepting connections");
    if (FSQ_SOCK_VALID(g_listen_fd)) close(g_listen_fd);
    {
        /* The socket path cannot change under a running daemon (RELOAD
         * refuses that change): unlink via the current snapshot. */
        struct fsq_config_snap *ssnap = cfg_acquire();
        const struct fsq_config *cfg = &ssnap->cfg;
        unlink(cfg->socket_path);
        cfg_release(ssnap);
    }
}
#endif

#ifdef _WIN32
#define FSQ_SERVICE_NAME "fractalsqld"
#define FSQ_LOG_DEFAULT "C:\\ProgramData\\FractalSQL\\fractalsqld.log"

static SERVICE_STATUS_HANDLE g_svc_handle = NULL;
static SERVICE_STATUS g_svc_status;
static DWORD g_svc_checkpoint = 0;

static int serve_setup(const struct fsq_config *cfg) {
    if (!key_file_private(cfg->key_path)) {
        fsq_log("ERROR", "hmac_key_file %s grants access to Everyone, Authenticated Users or Users: restrict it to the service account", cfg->key_path);
        return -1;
    }
    if (build_pipe_sd(cfg) != 0) {
        fsq_log("ERROR", "cannot build the pipe security descriptor from allowed_pipe_sid");
        return -1;
    }
    return 0;
}

static void report_service(DWORD state, DWORD exit_code) {
    int pending = state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING;
    g_svc_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_svc_status.dwCurrentState = state;
    g_svc_status.dwWin32ExitCode = exit_code ? ERROR_SERVICE_SPECIFIC_ERROR : NO_ERROR;
    g_svc_status.dwServiceSpecificExitCode = exit_code;
    g_svc_status.dwControlsAccepted = state == SERVICE_RUNNING ? (SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN) : 0;
    g_svc_status.dwCheckPoint = pending ? ++g_svc_checkpoint : 0;
    g_svc_status.dwWaitHint = pending ? 5000 : 0;
    SetServiceStatus(g_svc_handle, &g_svc_status);
}

static void WINAPI service_ctrl(DWORD code) {
    if (code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN) {
        report_service(SERVICE_STOP_PENDING, 0);
        SetEvent(g_stop_event);
    }
}

static void WINAPI service_main(DWORD argc, LPSTR *argv) {
    struct fsq_config_snap *snap;
    (void) argc;
    (void) argv;
    g_svc_handle = RegisterServiceCtrlHandlerA(FSQ_SERVICE_NAME, service_ctrl);
    if (!g_svc_handle) return;
    report_service(SERVICE_START_PENDING, 0);
    snap = cfg_acquire();
    if (!snap) { report_service(SERVICE_STOPPED, 1); return; }
    if (serve_setup(&snap->cfg) != 0) { cfg_release(snap); report_service(SERVICE_STOPPED, 1); return; }
    report_service(SERVICE_RUNNING, 0);
    if (run_listener() != 0) { cfg_release(snap); report_service(SERVICE_STOPPED, 1); return; }
    cfg_release(snap);
    report_service(SERVICE_STOPPED, 0);
}
#endif

int main(int argc, char **argv) {
    const char *config_path = getenv(FSQ_CONFIG_ENV);
    struct fsq_config cfg;
    int service_mode = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) config_path = argv[++i];
#ifdef _WIN32
        else if (strcmp(argv[i], "--service") == 0) service_mode = 1;
        else { fprintf(stderr, "usage: fractalsqld [-c config] [--service]\n"); return 2; }
#else
        else { fprintf(stderr, "usage: fractalsqld [-c config]\n"); return 2; }
#endif
    }
    if (!config_path) config_path = FSQ_CONFIG_DEFAULT;
    if (load_config(config_path, &cfg) != 0) {
        fprintf(stderr, "fractalsqld: cannot read config %s\n", config_path);
        return 1;
    }
    g_config_path = config_path;
    /* The in-repo computation loops (src/fractalsql_interrupt.h) poll this
     * process-wide hook; a NULL check per loop boundary is the cost when
     * nothing is active, a cancel flag read when a call is in flight and a
     * CANCEL has arrived. */
    fractalsql_interrupt_hook_set(fsq_check_cancelled);

#ifdef _WIN32
    g_stop_event = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!g_stop_event) {
        fprintf(stderr, "fractalsqld: cannot create the stop event\n");
        return 1;
    }
    {
        const char *log_path = cfg.log_path[0] ? cfg.log_path : (service_mode ? FSQ_LOG_DEFAULT : NULL);
        if (log_path) {
            g_logf = fopen(log_path, "a");
            if (!g_logf) {
                fprintf(stderr, "fractalsqld: cannot open log %s\n", log_path);
                return 1;
            }
        }
    }
    atexit(log_exit);
    /* Startup: gate on the config (platform checks + provider checks),
     * then push the provider settings the consumers boot from. Refusing
     * to start on a bad value beats lazily surfacing it on the first LLM
     * call, and mirrors what a RELOAD will enforce later. */
    if (validate_cfg(&cfg) != 0) return 1;
    if (daemon_check_provider(&cfg) != 0) return 1;
    if (daemon_apply_provider(&cfg) != 0) {
        fprintf(stderr, "fractalsqld: out of memory applying provider settings\n");
        return 1;
    }
    if (service_mode) {
        SERVICE_TABLE_ENTRYA table[2];
        if (cfg_publish(&cfg) != 0) {
            fprintf(stderr, "fractalsqld: out of memory publishing the configuration\n");
            return 1;
        }
        table[0].lpServiceName = (LPSTR) FSQ_SERVICE_NAME;
        table[0].lpServiceProc = service_main;
        table[1].lpServiceName = NULL;
        table[1].lpServiceProc = NULL;
        if (!StartServiceCtrlDispatcherA(table)) {
            fsq_log("ERROR", "cannot start the service dispatcher (error %lu); run without --service to test from a console",
                    (unsigned long) GetLastError());
            return 1;
        }
        return 0;
    }
    SetConsoleCtrlHandler(on_console_event, TRUE);
    signal(SIGSEGV, on_fatal);
    signal(SIGABRT, on_fatal);
    signal(SIGFPE, on_fatal);
    signal(SIGILL, on_fatal);
    /* serve_setup borrows the stack config directly: it runs before anything
     * published, and cfg_acquire() would deref a NULL g_snap here. */
    if (serve_setup(&cfg) != 0) return 1;
    if (cfg_publish(&cfg) != 0) {
        fprintf(stderr, "fractalsqld: out of memory publishing the configuration\n");
        return 1;
    }
    return run_listener() == 0 ? 0 : 1;
#else
    (void) service_mode;
    {
        struct sigaction sa;
        if (geteuid() == 0) {
            fsq_log("ERROR", "refusing to run as root: run as the service user (the demo image uses mysql)");
            return 1;
        }
        if (validate_cfg(&cfg) != 0) return 1;
        if (daemon_check_provider(&cfg) != 0) return 1;
        signal(SIGPIPE, SIG_IGN);
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_signal;
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);
        signal(SIGSEGV, on_fatal);
        signal(SIGABRT, on_fatal);
        signal(SIGBUS, on_fatal);
        signal(SIGFPE, on_fatal);
    }
    atexit(log_exit);

    umask(0007);   /* the socket is never created wider than owner and group */
    /* Same startup gate as the Windows branch above; the apply must have
     * finished before anything can talk to the consumers. */
    if (daemon_apply_provider(&cfg) != 0) {
        fprintf(stderr, "fractalsqld: out of memory applying provider settings\n");
        return 1;
    }
    if (cfg_publish(&cfg) != 0) {
        fprintf(stderr, "fractalsqld: out of memory publishing the configuration\n");
        return 1;
    }
    g_listen_fd = open_listener(&cfg);
    if (!FSQ_SOCK_VALID(g_listen_fd)) {
        fsq_log("ERROR", "cannot listen on %s: %s", cfg.socket_path, strerror(errno));
        return 1;
    }
    run_listener();
    return 0;
#endif
}
