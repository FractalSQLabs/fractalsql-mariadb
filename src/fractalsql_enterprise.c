/* src/fractalsql_enterprise.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Enterprise tier: activation gating for the QTL ledger and CISO audit
 * primitives, plus a real, file-backed persistence layer for the ledger
 * itself.
 *
 * This file implements two layers:
 *
 * 1. ACTIVATION GATING: the enterprise_lib config key (fractalsqld.conf;
 *    FRACTALSQL_ENTERPRISE_LIB in the daemon's environment is the legacy
 *    boot-time fallback) names a separately built enterprise core shared
 *    library, which is
 *    dlopen'd lazily on first use, with 8 required symbols resolved via
 *    dlsym. The fractal_ledger_* and fractal_audit_unpack UDFs below are
 *    thin wrappers around those function pointers. When the library
 *    isn't loaded (the default, and the entire behavior of a Community
 *    deployment), every wrapper UDF sets the MariaDB UDF error flag and
 *    returns, which the UDF protocol surfaces to the client as a clean
 *    NULL result, not a crash and not a silently wrong success value. It
 *    is not a visible SQL error/exception: MariaDB's C UDF ABI has no
 *    equivalent of SIGNAL for a row-level failure inside the main
 *    function, only inside _init (used above for argument-count checks,
 *    which the client does see as a real error at CALL time).
 *
 * 2. LEDGER STORAGE: the ledger's write_entry/read_entry/seal_ledger
 *    storage-VFS callbacks (see fractalsql_sql.h's fsql_storage_vfs_t)
 *    are invoked synchronously, inside the core library's own call, with
 *    no way to defer the write to a later stored-procedure step the way
 *    fractal_sql_agent works around the same constraint for dynamic-SQL
 *    agent composition. A MariaDB C UDF cannot run SQL against the
 *    calling session (see fractalsql_textsql.c's file header for the
 *    fullest account of this constraint), so these callbacks can't be
 *    backed by a SQL table read/written from inside the callback itself.
 *
 *    Two ways exist to give write_entry/read_entry real persistence: (a)
 *    a loopback MariaDB client connection (this repo already builds
 *    against libmariadb-dev's public mysql.h, the same client API
 *    mysql_real_connect/mysql_query live in, so it's technically
 *    available), or (b) a local file. (a) needs new credential/socket
 *    config invented from scratch (a DSN env var, platform-specific
 *    transport: Unix socket on Linux/Darwin, named pipe or TCP on
 *    Windows) and embeds DB credentials inside a plugin, a real new
 *    attack surface. (b) needs neither. This file uses (b): a local
 *    file, path from the enterprise_ledger_path config key (default:
 *    fractalsql_ledger.dat, relative to the fractalsqld daemon's
 *    working directory; FRACTALSQL_ENTERPRISE_LEDGER_PATH in the
 *    daemon's environment is the legacy boot-time fallback). The path
 *    swaps live on a reload -- every ledger read/write opens and
 *    closes the file per operation, so the next operation lands in the
 *    new path.
 *
 *    The ledger is an APPEND-ONLY chain of records per `kind`, each
 *    linking to its predecessor via entry_hash = SHA256(prev_hash ||
 *    blob || mac) (see fractalsql_hmac.h, a header-only, public-domain
 *    SHA-256 + HMAC-SHA256 implementation, so this carries no OpenSSL
 *    dependency for the chain itself). A rewritten record breaks the
 *    very next record's prev_hash link; a deleted record leaves the same
 *    visible break, no separate id-sequence bookkeeping needed to detect
 *    it. Optional HMAC-SHA256 tamper authentication activates when the
 *    enterprise_ledger_key setting (FRACTALSQL_ENTERPRISE_LEDGER_KEY in
 *    the env fallback) is set. fractal_ledger_load's O(1)
 *    tip-only check before decode (ledger_verify_latest_file) and
 *    fractal_ledger_verify(session_id[, kind])'s O(n) full chain walk
 *    both scan the file sequentially rather than issuing SQL SELECTs.
 *
 *    Concurrency: MariaDB has no transaction-scoped lock reachable from
 *    a UDF, so this file holds the same process-wide mutex the
 *    dlopen/dlsym gating below already uses (ent_lock/ent_unlock) around
 *    the read-modify-append sequence in ledger_write_entry, for the
 *    duration of that one call. The daemon is one shared process for
 *    every connection, so this still fully serializes concurrent writers
 *    against each other, even without a longer-lived transaction
 *    boundary (the classic MariaDB UDF protocol has no multi-statement
 *    transaction boundary the extension can observe).
 *
 *    fractal_audit_log is a public UDF here too (kind=2 on the same
 *    ledger, gated behind ensure_enterprise_lib() as a product-tier gate
 *    even though the write itself doesn't touch the dlsym'd core .so),
 *    and ensure_enterprise_lib() verifies the enterprise .so's detached
 *    Ed25519 signature (see ent_verify_signature() below) against a
 *    fixed FractalSQLabs public key before dlopen. The portfolio
 *    multimodal variants (fsql_optimize_portfolio_multimodal plus its
 *    _ex OBL/Levy-flight and _pareto Pareto-front siblings) are optional
 *    symbols alongside it: absent from an older enterprise .so without
 *    breaking the ledger surface.
 *
 * CONFIG: keys come from fractalsqld.conf (preferred; `fsqlctl reload`
 *   applies changes live), with the daemon's boot-time environment
 *   (the FRACTALSQL_ENTERPRISE_* variable names below) as the legacy
 *   fallback; a key removed from the config file reverts to that
 *   fallback.
 *   FRACTALSQL_ENTERPRISE_LIB (required to activate): the enterprise
 *     core .so's absolute path. This is the ONE key that cannot swap
 *     live while an enterprise library is loaded (its 8 resolved
 *     symbols have no replace path); a reload refuses while loaded and
 *     only a daemon restart changes it.
 *   FRACTALSQL_ENTERPRISE_LEDGER_PATH (optional): the ledger file's
 *     path, default "fractalsql_ledger.dat" relative to the daemon's
 *     working directory. Swaps live: every ledger operation re-opens
 *     the effective path.
 *   FRACTALSQL_ENTERPRISE_LEDGER_KEY (optional): HMAC-SHA256 key for
 *     MAC-authenticated tamper evidence; unset means structural-only
 *     (entry_hash chain) validation. Swaps live like the ledger path.
 *   FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE (optional): refuses to load an
 *     enterprise .so with no sibling <path>.sig file (an INVALID signature
 *     is always fatal regardless of this setting). Default ON; set it to
 *     "0" to let an unsigned .so load (logged to stderr).
 *   One shared daemon process serves every connection's forwarded
 *   calls, so the dlopen attempt/result is cached process-wide, not
 *   per session.
 */

#include <mysql.h>

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#  include <Windows.h>
#  include <fcntl.h>             /* _sopen_s/_O_BINARY: owner-only file opens */
#  include <io.h>                /* _commit: flush the ledger write through to disk */
#  include <share.h>             /* _SH_DENYNO: the sharing mode for _sopen_s */
#  include <sys/stat.h>          /* _chmod: tighten an existing file's permissions */
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  include <dlfcn.h>
#  include <fcntl.h>             /* open/O_*: owner-only file opens */
#  include <pthread.h>
#  include <sys/stat.h>          /* fchmod: the temp library copy needs the execute bit */
#  include <syslog.h>            /* syslog: the off-host anchor log sink */
#  include <unistd.h>            /* fsync: flush the ledger write through to disk */
#  define FRACTAL_EXPORT
#endif

#include "fractalsql.h"          /* FSQL_OK, fsql_ledger_*, fsql_audit_unpack */
#include "fractalsql_sql.h"      /* fsql_ctx, fsql_ledger_*, fsql_audit_unpack */
#include "fractalsql_session.h"  /* fractal_session_acquire/_release */
#include "fractalsql_enterprise.h"
#include "fractalsql_provider.h" /* fractalsql_enterprise_{check,apply}_provider */
#include "fractalsql_hmac.h"     /* fsql_sha256/fsql_hmac_sha256: vendored, public-domain SHA-256 + HMAC-SHA256 */
#include "fractalsql_msvc_compat.h"  /* strdup -> _strdup rename on MSVC/clang-cl */
#include "fractalsql_parse.h"    /* parse_vector_csv, shared with fractalsql.c/fractalsql_vector.c */
#include "fsql_audit_redact.h"   /* FSQL_AUDIT_REDACT: fingerprint the audit trail's free text */

#if defined(__linux__)
#include <sys/syscall.h>         /* memfd_create, see ent_dlopen_verified_copy */
#include <unistd.h>
#endif
#include <openssl/evp.h>         /* Ed25519 signature verification, see ent_verify_signature() */
#include <openssl/crypto.h>      /* CRYPTO_memcmp: constant-time ledger MAC comparison */

/* Same stderr-mirroring SFS_INIT_ERROR as fractalsql_cognition.c
 * (duplicated per translation unit by this repo's established
 * precedent): on the UDF runtime path the formatted buffer would
 * otherwise be dropped, surfacing failures as bare NULLs. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

#define ENT_NOT_LOADED_MSG \
    "enterprise tier not loaded: set enterprise_lib in fractalsqld.conf and " \
    "run `fsqlctl reload`, or set FRACTALSQL_ENTERPRISE_LIB in fractalsqld's " \
    "environment at startup, or install FractalSQL Enterprise if this is a " \
    "Community deployment"

/* ------------------------------------------------------------------ */
/* dlopen/dlsym machinery. Process-wide, loaded at most once.         */
/* ------------------------------------------------------------------ */
typedef int  (*ent_ledger_void_fn)(fsql_ctx *ctx);
typedef int  (*ent_ledger_count_fn)(const fsql_ctx *ctx, size_t *out);
typedef int  (*ent_portfolio_multimodal_fn)(const double *mu, const double *cov,
                                            size_t n_assets, size_t k,
                                            int n_restarts,
                                            double overlap_threshold,
                                            double quality_frac,
                                            uint64_t seed,
                                            double *out_weights,
                                            double *out_sharpes,
                                            int *out_n_found);
typedef int  (*ent_portfolio_multimodal_ex_fn)(const double *mu, const double *cov,
                                               size_t n_assets, size_t k,
                                               int n_restarts,
                                               double overlap_threshold,
                                               double quality_frac,
                                               uint64_t seed,
                                               int use_obl, int diffusion_mode,
                                               double *out_weights,
                                               double *out_sharpes,
                                               int *out_n_found);
typedef int  (*ent_portfolio_multimodal_pareto_fn)(const double *mu, const double *cov,
                                                   size_t n_assets, size_t k,
                                                   int n_restarts, int max_front,
                                                   uint64_t seed,
                                                   int use_obl, int diffusion_mode,
                                                   double *out_weights,
                                                   double *out_returns,
                                                   double *out_risks,
                                                   int *out_n_found);
typedef int  (*ent_audit_unpack_fn)(const void *blob, size_t blob_len,
                                    char *json_out, size_t *json_cap);

static void       *g_ent_handle   = NULL;
static bool         g_ent_attempted = false;
static bool         g_ent_loaded    = false;

/* Provider settings (fractalsql_provider.h): the effective values the
 * loader and ledger helpers consult, and the boot-env fallback snapshot
 * they revert to for keys absent from fractalsqld.conf. All five strings
 * are owned; g_ent_env_* are captured once and never freed. Callers of
 * the _effective accessors / capture function must hold g_ent_lock --
 * which every call site already does, since all these values are
 * consumed only from paths that run under it (ensure_enterprise_lib and
 * the per-op ledger entry points). */
static char *g_ent_lib;               /* NULL = not configured */
static char *g_ent_ledger_path;       /* NULL = default "fractalsql_ledger.dat" */
static char *g_ent_ledger_key;        /* NULL = unsealed */
static bool  g_ent_require_sig;
static char *g_ent_env_lib;
static char *g_ent_env_ledger_path;
static char *g_ent_env_ledger_key;
static bool  g_ent_env_require_sig;
static bool  g_ent_env_captured;

/* strdup `s` (NULL stays NULL) into *out; 0, or -1 on allocation
 * failure. */
static int
ent_dup_or(const char *s, char **out)
{
    if (!s) { *out = NULL; return 0; }
    *out = strdup(s);
    return *out ? 0 : -1;
}

/* Same truthiness as the old getenv-per-call read of
 * FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE: any non-empty value except
 * the string "0" enables it. */
static bool
ent_env_flag(const char *name)
{
    const char *v = getenv(name);
    return v != NULL && v[0] != '\0' && v[0] != '0';
}

/* Called with g_ent_lock held. Captures the boot-env snapshot from the
 * process environment once and, until the daemon's apply_provider has
 * run, seeds the effective statics from it -- byte-identical to the old
 * getenv-per-call behavior. */
static void
ent_env_capture_locked(void)
{
    if (g_ent_env_captured) return;
    (void) ent_dup_or(getenv("FRACTALSQL_ENTERPRISE_LIB"), &g_ent_env_lib);
    (void) ent_dup_or(getenv("FRACTALSQL_ENTERPRISE_LEDGER_PATH"), &g_ent_env_ledger_path);
    (void) ent_dup_or(getenv("FRACTALSQL_ENTERPRISE_LEDGER_KEY"), &g_ent_env_ledger_key);
    /* Default ON: an unset variable now requires a signature; only an
     * explicit "0" (operator opt-out) lets an unsigned library load. */
    {
        const char *rq = getenv("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE");
        g_ent_env_require_sig = (rq == NULL || rq[0] == '\0') ? true : (rq[0] != '0');
    }
    /* Effective values start as owned copies of the snapshot, so apply's
     * free-and-replace never frees a snapshot string (see free_cfg's
     * aliasing note in fractalsql_cognition.c). On OOM these stay NULL,
     * which reads as "not configured" -- degraded, never unsafe. */
    (void) ent_dup_or(g_ent_env_lib, &g_ent_lib);
    (void) ent_dup_or(g_ent_env_ledger_path, &g_ent_ledger_path);
    (void) ent_dup_or(g_ent_env_ledger_key, &g_ent_ledger_key);
    g_ent_require_sig  = g_ent_env_require_sig;
    g_ent_env_captured = true;
}

static ent_ledger_void_fn   g_ent_ledger_flush;
static ent_ledger_void_fn   g_ent_ledger_load;
static ent_ledger_void_fn   g_ent_ledger_compact;
static ent_ledger_void_fn   g_ent_ledger_reset_soft;
static ent_ledger_void_fn   g_ent_ledger_reset_hard;
static ent_ledger_count_fn  g_ent_ledger_truth_count;
static ent_ledger_count_fn  g_ent_ledger_shadow_count;
static ent_audit_unpack_fn  g_ent_audit_unpack;

/* Optional -- not one of the 8 required symbols below. Resolved if
 * present so an enterprise .so built without them (older release) still
 * loads normally for the ledger surface; each wrapper UDF checks its own
 * pointer and returns NULL if unresolved. */
static ent_portfolio_multimodal_fn g_ent_portfolio_multimodal;
static ent_portfolio_multimodal_ex_fn g_ent_portfolio_multimodal_ex;
static ent_portfolio_multimodal_pareto_fn g_ent_portfolio_multimodal_pareto;

#if defined(_WIN32)
static CRITICAL_SECTION g_ent_lock;
static INIT_ONCE        g_ent_lock_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK
init_ent_lock_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
    InitializeCriticalSection(&g_ent_lock);
    return TRUE;
}
static void ent_lock(void)
{
    InitOnceExecuteOnce(&g_ent_lock_once, init_ent_lock_once, NULL, NULL);
    EnterCriticalSection(&g_ent_lock);
}
static void ent_unlock(void) { LeaveCriticalSection(&g_ent_lock); }

static void *ent_dlopen(const char *path) { return (void *) LoadLibraryA(path); }
static void *ent_dlsym(void *h, const char *name) { return (void *) GetProcAddress((HMODULE) h, name); }
#else
static pthread_mutex_t g_ent_lock = PTHREAD_MUTEX_INITIALIZER;
static void ent_lock(void)   { pthread_mutex_lock(&g_ent_lock); }
static void ent_unlock(void) { pthread_mutex_unlock(&g_ent_lock); }

static void *ent_dlopen(const char *path) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); }
static void *ent_dlsym(void *h, const char *name) { return dlsym(h, name); }
#endif

/* dlopen the exact bytes whose signature was verified, via a private
 * temp copy. ent_verify_signature reads the library through a FILE* and
 * verifies those bytes, but dlopen would otherwise re-open the path by
 * name: between the two operations the file on disk could be swapped
 * for an unverified one, so what gets mapped into the process is not
 * necessarily what was checked. Writing the verified bytes to a fresh
 * private file and loading THAT closes the window.
 *
 * POSIX unlinks the copy immediately after the load -- the mapping
 * survives, and nothing is left on disk. Windows cannot delete a loaded
 * library, so the copy persists for the life of the process: it is
 * pid-named (pids recycle, so a later process with the same pid
 * overwrites it) and lives in the OS temp directory, NOT next to the
 * original -- the original may be a source tree or staging directory,
 * and one unique pid per restart would otherwise accumulate a copy
 * there on every daemon restart. ent_clean_stale_copies() below
 * garbage-collects leftovers from dead processes as a side effect of
 * each verified load, so the temp directory stays bounded. */
#if defined(_WIN32)
static void
ent_clean_stale_copies(const char *dir)
{
    char               pattern[MAX_PATH];
    WIN32_FIND_DATAA   fd;
    HANDLE             h;

    if (snprintf(pattern, sizeof pattern, "%s.fractalsql-ent-*.tmp", dir)
        >= (int) sizeof pattern)
        return;
    h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do
    {
        char p[MAX_PATH];
        if (snprintf(p, sizeof p, "%s%s", dir, fd.cFileName) < (int) sizeof p)
            /* Best effort: a file still loaded by a live process (ours
             * before restart, or another daemon process) fails the delete with
             * a sharing violation, which is exactly right -- anything
             * deletable is by definition not mapped anywhere. */
            DeleteFileA(p);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
}
#endif /* _WIN32 */

static void *
ent_dlopen_verified_copy(const char *orig_path,
                         const unsigned char *bytes, size_t len)
{
    char  tmp_path[4096];
    FILE *f;

#if defined(_WIN32)
    {
        (void) orig_path;  /* temp dir comes from GetTempPathA here */
        char tmpdir[MAX_PATH];
        if (GetTempPathA(sizeof tmpdir, tmpdir) == 0) return NULL;
        ent_clean_stale_copies(tmpdir);
        if (snprintf(tmp_path, sizeof tmp_path, "%s.fractalsql-ent-%lu.tmp",
                     tmpdir, (unsigned long) GetCurrentProcessId())
            >= (int) sizeof tmp_path)
            return NULL;
        f = fopen(tmp_path, "wb");   /* pid-recycled overwrite, see above */
        if (f == NULL) return NULL;
    }
#else
#if defined(__linux__) && defined(SYS_memfd_create)
    /* Preferred on Linux: load the verified bytes from an anonymous memory
     * file. A tmpfs /tmp mounted noexec (common in containers) refuses to
     * map a library from disk, so the temp-file path below cannot be used
     * there; a memfd is not on any mount and is always loadable. */
    {
        (void) orig_path;
        int mfd = (int) syscall(SYS_memfd_create, "fractalsql-ent", 1U /* MFD_CLOEXEC */);
        if (mfd >= 0) {
            size_t off = 0;
            while (off < len) {
                ssize_t w = write(mfd, bytes + off, len - off);
                if (w <= 0) break;
                off += (size_t) w;
            }
            if (off == len) {
                char  fdpath[64];
                void *h;
                snprintf(fdpath, sizeof fdpath, "/proc/self/fd/%d", mfd);
                h = ent_dlopen(fdpath);
                close(mfd);
                return h;
            }
            close(mfd);
        }
    }
#endif
    /* memfd unavailable or the write failed: fall through to the temp file. */
    {
        (void) orig_path;
        /* The temp copy goes to the system temp dir, not beside the
         * library: a read-only or root-owned install directory would
         * otherwise make mkstemp fail and the load fail silently. */
        const char *tmpdir = getenv("TMPDIR");
        if (tmpdir == NULL || tmpdir[0] == '\0') tmpdir = "/tmp";
        if (snprintf(tmp_path, sizeof tmp_path, "%s/.fractalsql-ent-XXXXXX", tmpdir)
            >= (int) sizeof tmp_path) return NULL;
        {
            int fd = mkstemp(tmp_path);   /* exclusive create, mode 0600 */
            if (fd < 0) return NULL;
            /* The execute bit, before anything is written to the file.
             * mkstemp creates with mode 0600 (no execute permission),
             * and a shared library that is not executable cannot be
             * mapped for execution: on macOS (and the BSDs) dlopen
             * fails outright on a file without the execute bit, so a
             * VERIFIED library would fail to load there for no reason
             * other than the temp file's permissions. 0700 keeps the
             * file private to its owner and adds exactly the one bit
             * the loader needs. */
            if (fchmod(fd, S_IRUSR | S_IWUSR | S_IXUSR) != 0)
            {
                close(fd); remove(tmp_path); return NULL;
            }
            f = fdopen(fd, "wb");
            if (f == NULL) { close(fd); remove(tmp_path); return NULL; }
        }
    }
#endif
    {
        size_t wn = fwrite(bytes, 1, len, f);
        bool   ok = (wn == len) && (fclose(f) == 0);
        if (!ok) { remove(tmp_path); return NULL; }
    }

#if defined(_WIN32)
    {
        void *h = ent_dlopen(tmp_path);
        if (h == NULL) remove(tmp_path);
        return h;
    }
#else
    {
        void *h = ent_dlopen(tmp_path);
        remove(tmp_path);   /* the loaded mapping survives the unlink */
        return h;
    }
#endif
}

/* ------------------------------------------------------------------ */
/* Ed25519 signature verification of the enterprise .so.                */
/*                                                                      */
/* ensure_enterprise_lib()'s 8-symbol dlsym check only proves "this     */
/* file has the right function names" -- a tampered file with the same  */
/* names sails through untouched. This verifies a detached Ed25519      */
/* signature (a sibling <path>.sig file, exactly 64 raw bytes) over the */
/* enterprise .so's exact bytes, against a fixed FractalSQLabs public   */
/* key embedded here. New enterprise releases only need a fresh          */
/* signature from the same long-lived private key, no rebuild required.  */
/*                                                                      */
/* FractalSQLabs's long-lived Ed25519 signing public key. */
static const unsigned char FSQL_ENTERPRISE_PUBKEY[32] = {
    0xd5, 0xf6, 0x08, 0xa5, 0x8b, 0x1e, 0xb7, 0xe5, 0x9a, 0xcb, 0x8f, 0xab,
    0x80, 0x35, 0x9d, 0x58, 0x3f, 0x4e, 0xd1, 0xd1, 0xa2, 0x9c, 0x33, 0x6b,
    0xcb, 0x4b, 0x43, 0xcf, 0xf1, 0x07, 0x7f, 0xcb
};

/* The FractalSQLabs reasoning-plugin signing public key. A plugin release is
 * signed with the matching private key; its detached <plugin>.sig (64 raw
 * bytes) must verify against this key before the plugin is loaded. It is a
 * different key from the enterprise-library key above. Compiled in; no setting
 * can replace it. */
static const unsigned char FSQL_REASONING_PLUGIN_PUBKEY[32] = {
    0xbb, 0x24, 0x79, 0x25, 0x84, 0xe8, 0x9b, 0x1d, 0x1b, 0x48, 0x49, 0xba,
    0x70, 0x1d, 0xa1, 0x71, 0xa3, 0x4f, 0x8a, 0x29, 0x47, 0x83, 0xd1, 0xd4,
    0x74, 0xdf, 0x9b, 0x07, 0x44, 0xc5, 0x94, 0x53
};

typedef enum {
    ENT_SIG_OK,        /* .sig present and verifies against the pubkey */
    ENT_SIG_MISSING,   /* no .sig file found -- soft unless require=on */
    ENT_SIG_INVALID,   /* .sig present but wrong -- always fatal */
    ENT_SIG_IOERROR    /* could not read the .so or .sig file at all */
} ent_sig_result_t;

/* NOTE: the Windows UCRT stdio implementation has a documented
 * STATUS_STACK_BUFFER_OVERRUN crash inside fread/fread_s's own internal
 * validation when the code runs inside a dynamically-linked-CRT host
 * process (diagnosed when this file ran in-process inside the server;
 * the fractalsqld daemon is a plain, statically-linked-CRT exe, where
 * the mode is not expected). This function
 * uses plain fopen/fread on every platform for simplicity; if Windows
 * testing ever hits that failure mode, raw Win32 CreateFileA/ReadFile in
 * place of CRT stdio is the known fix. */
/* Verifies the detached signature over so_path's exact bytes. On
 * ENT_SIG_OK, and only then, the verified bytes are handed back through
 * out_verified_bytes (ownership transfers; caller frees) with their
 * length in out_verified_len -- the caller must load THOSE bytes, not
 * re-read the path, which may no longer hold what was verified. Either
 * out parameter may be NULL. */
static ent_sig_result_t
ent_verify_signature(const char *so_path,
                     const unsigned char pubkey[32],
                     unsigned char **out_verified_bytes,
                     size_t *out_verified_len)
{
    char           sig_path[4096];
    unsigned char  sig_bytes[64];
    unsigned char *so_bytes = NULL;
    long           so_len;
    FILE          *f;
    EVP_PKEY      *pkey  = NULL;
    EVP_MD_CTX    *mdctx = NULL;
    ent_sig_result_t result;

    if (snprintf(sig_path, sizeof sig_path, "%s.sig", so_path) >= (int) sizeof sig_path)
        return ENT_SIG_IOERROR;

    f = fopen(sig_path, "rb");
    if (f == NULL) return ENT_SIG_MISSING;
    {
        size_t n = fread(sig_bytes, 1, sizeof sig_bytes, f);
        /* Confirm the file is EXACTLY 64 bytes, not >=64 -- a longer
         * file silently truncated to 64 by fread would otherwise verify
         * against the wrong (partial) signature. */
        int c = fgetc(f);
        fclose(f);
        if (n != sizeof sig_bytes || c != EOF)
            return ENT_SIG_INVALID;   /* wrong-sized .sig -- corrupt/tampered, not "absent" */
    }

    f = fopen(so_path, "rb");
    if (f == NULL) return ENT_SIG_IOERROR;
    if (fseek(f, 0, SEEK_END) != 0)
    {
        fclose(f);
        return ENT_SIG_IOERROR;
    }
    so_len = ftell(f);
    if (so_len < 0 || fseek(f, 0, SEEK_SET) != 0)
    {
        fclose(f);
        return ENT_SIG_IOERROR;
    }
    so_bytes = (unsigned char *) malloc((size_t) so_len);
    if (so_bytes == NULL) { fclose(f); return ENT_SIG_IOERROR; }
    if (fread(so_bytes, 1, (size_t) so_len, f) != (size_t) so_len)
    {
        fclose(f);
        free(so_bytes);
        return ENT_SIG_IOERROR;
    }
    fclose(f);

    pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL,
                                       pubkey, 32);
    if (pkey == NULL) { free(so_bytes); return ENT_SIG_IOERROR; }

    mdctx = EVP_MD_CTX_new();
    if (mdctx == NULL) { EVP_PKEY_free(pkey); free(so_bytes); return ENT_SIG_IOERROR; }

    /* Ed25519 is "PureEdDSA" in OpenSSL's EVP API -- one-shot verify over
     * the whole message, no Update() calls, no pre-hash digest type. */
    if (EVP_DigestVerifyInit(mdctx, NULL, NULL, NULL, pkey) == 1 &&
        EVP_DigestVerify(mdctx, sig_bytes, sizeof sig_bytes, so_bytes, (size_t) so_len) == 1)
    {
        result = ENT_SIG_OK;
        if (out_verified_bytes != NULL)
        {
            *out_verified_bytes = so_bytes;
            if (out_verified_len != NULL)
                *out_verified_len = (size_t) so_len;
            so_bytes = NULL;   /* ownership moved to the caller */
        }
    }
    else
        result = ENT_SIG_INVALID;

    EVP_MD_CTX_free(mdctx);
    EVP_PKEY_free(pkey);
    free(so_bytes);
    return result;
}

bool
fractal_plugin_verify(const char *path, char *err, size_t errsz)
{
    /* A signature is required unless FSQL_REASONING_REQUIRE_SIGNATURE=0 is in the environment.
     * With it off, a plugin that has no .sig still loads (one warning); a .sig that is present
     * is always checked and a wrong one is always refused. */
    const char *rq = getenv("FSQL_REASONING_REQUIRE_SIGNATURE");
    const bool require = !(rq != NULL && rq[0] == '0');
    if (path == NULL || path[0] == '\0')
    {
        if (!require) return true;         /* the loader reports the missing plugin itself */
        snprintf(err, errsz, "no reasoning plugin path configured");
        return false;
    }

    ent_sig_result_t sig = ent_verify_signature(path, FSQL_REASONING_PLUGIN_PUBKEY, NULL, NULL);
    if (sig == ENT_SIG_OK) return true;
    if (sig == ENT_SIG_INVALID)
    {
        snprintf(err, errsz,
                 "reasoning plugin \"%s\" failed signature verification -- refusing to load (the plugin or its "
                 ".sig is corrupt or not from FractalSQLabs)", path);
        return false;
    }
    if (!require)
    {
        static int warned = 0;
        if (!warned)
        {
            warned = 1;
            fprintf(stderr, "fractalsql: loading reasoning plugin \"%s\" without a signature "
                            "(FSQL_REASONING_REQUIRE_SIGNATURE=0)\n", path);
        }
        return true;
    }
    if (sig == ENT_SIG_MISSING)
        snprintf(err, errsz,
                 "no signature found for reasoning plugin \"%s\" (expected \"%s.sig\"); place the .sig "
                 "beside the plugin, or set FSQL_REASONING_REQUIRE_SIGNATURE=0 to load an unsigned plugin", path, path);
    else
        snprintf(err, errsz,
                 "could not read reasoning plugin \"%s\" for signature verification -- refusing to load", path);
    return false;
}

/* FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1 (or enterprise_require_signature
 * in fractalsqld.conf) makes a MISSING .sig fatal (an INVALID .sig is
 * always fatal regardless). Default ON: a library without a .sig is
 * refused unless the operator sets FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0
 * (or enterprise_require_signature=false in fractalsqld.conf). */
static bool
ent_require_signature(void)
{
    ent_env_capture_locked();
    return g_ent_require_sig;
}

/* The signature gate: verifies the detached signature over the
 * library's exact bytes and applies the require_signature policy.
 *
 * Returns true iff the library may be loaded at all. An INVALID .sig
 * always refuses (a tampered/corrupt file, regardless of
 * require_signature); a MISSING .sig refuses only when
 * FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE is set. Everything else
 * loads, unverified, and says so.
 *
 * On the verified path the exact bytes that were signed are handed
 * back through out_bytes/out_len (ownership transfers to the caller,
 * who frees them) and *out_verified is set, so the load can use those
 * bytes rather than re-reading a path that may no longer hold what
 * was verified. On every other path *out_verified is false and the
 * out parameters are left untouched.
 *
 * The diagnostics go to stderr, the daemon's error log destination:
 * there is no SQL-visible WARNING channel reachable from here, since
 * this runs lazily from whichever UDF call happens to be first, not
 * from a context with a message buffer. */
static bool
ent_signature_gate(const char *path,
                   unsigned char **out_bytes,
                   size_t *out_len,
                   bool *out_verified)
{
    ent_sig_result_t sig;

    if (out_verified)
        *out_verified = false;

    sig = ent_verify_signature(path, FSQL_ENTERPRISE_PUBKEY, out_bytes, out_len);

    if (sig == ENT_SIG_INVALID)
    {
        fprintf(stderr,
               "fractalsql: enterprise library \"%s\" failed signature "
               "verification -- refusing to load (the library or its .sig "
               "is corrupt or not from FractalSQLabs)\n", path);
        return false;
    }
    if (sig == ENT_SIG_MISSING && ent_require_signature())
    {
        fprintf(stderr,
               "fractalsql: no signature found for enterprise library "
               "\"%s\" (expected \"%s.sig\"); place the .sig beside the library, or set "
               "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 to load an unsigned library\n", path, path);
        return false;
    }
    if (sig == ENT_SIG_MISSING)
    {
        fprintf(stderr,
               "fractalsql: no signature found for enterprise library "
               "\"%s\" (expected \"%s.sig\"); loading it unsigned because "
               "signature checks are off\n", path, path);
        return true;
    }
    if (sig == ENT_SIG_IOERROR)
    {
        /* The library (or its .sig) could not be read, so no signature
         * could be checked over it and nothing was verified.
         *
         * With the signature REQUIRED, this is a refusal, exactly like
         * a missing signature: the operator asked for "only a signed
         * library", and an unreadable file is not a signed library.
         * The old behaviour loaded it unverified anyway, which made
         * the requirement a no-op for the one case where the check
         * could not run -- a .so that is readable but whose .sig is
         * not (an unreadable .sig, a permissions problem, a race with
         * the operator re-signing the library) was enough to get an
         * UNVERIFIED library loaded into a daemon whose operator had
         * explicitly asked for verification.
         *
         * Without the requirement, the load is attempted anyway -- it
         * may succeed where the read failed -- and it says so rather
         * than passing for a verified one. */
        if (ent_require_signature())
        {
            fprintf(stderr,
                   "fractalsql: could not read enterprise library \"%s\" for "
                   "signature verification -- refusing to load\n", path);
            return false;
        }
        fprintf(stderr,
               "fractalsql: could not read enterprise library \"%s\" for "
               "signature verification; loading it unsigned because "
               "signature checks are off\n", path);
        return true;
    }

    if (out_verified)
        *out_verified = true;
    return true;
}

/* Resolves the enterprise symbol surface: the 8 required symbols (the
 * ledger and audit functions) and the 3 optional portfolio ones.
 * Returns true iff every required symbol resolved; a partial library
 * is not usable and the caller discards the handle. */
static bool
ent_resolve_symbols(void *h)
{
    g_ent_ledger_flush        = (ent_ledger_void_fn)  ent_dlsym(h, "fsql_ledger_flush");
    g_ent_ledger_load         = (ent_ledger_void_fn)  ent_dlsym(h, "fsql_ledger_load");
    g_ent_ledger_compact      = (ent_ledger_void_fn)  ent_dlsym(h, "fsql_ledger_compact");
    g_ent_ledger_reset_soft   = (ent_ledger_void_fn)  ent_dlsym(h, "fsql_ledger_reset_soft");
    g_ent_ledger_reset_hard   = (ent_ledger_void_fn)  ent_dlsym(h, "fsql_ledger_reset_hard");
    g_ent_ledger_truth_count  = (ent_ledger_count_fn) ent_dlsym(h, "fsql_ledger_truth_count");
    g_ent_ledger_shadow_count = (ent_ledger_count_fn) ent_dlsym(h, "fsql_ledger_shadow_count");
    g_ent_audit_unpack        = (ent_audit_unpack_fn) ent_dlsym(h, "fsql_audit_unpack");

    /* Optional symbols -- see g_ent_portfolio_multimodal's own comment.
     * Not part of the required-8 check below. */
    g_ent_portfolio_multimodal = (ent_portfolio_multimodal_fn)
        ent_dlsym(h, "fsql_optimize_portfolio_multimodal");
    g_ent_portfolio_multimodal_ex = (ent_portfolio_multimodal_ex_fn)
        ent_dlsym(h, "fsql_optimize_portfolio_multimodal_ex");
    g_ent_portfolio_multimodal_pareto = (ent_portfolio_multimodal_pareto_fn)
        ent_dlsym(h, "fsql_optimize_portfolio_multimodal_pareto");

    return g_ent_ledger_flush && g_ent_ledger_load && g_ent_ledger_compact &&
           g_ent_ledger_reset_soft && g_ent_ledger_reset_hard &&
           g_ent_ledger_truth_count && g_ent_ledger_shadow_count &&
           g_ent_audit_unpack;
}

/* Loads FRACTALSQL_ENTERPRISE_LIB (if set) and resolves the 8 required
 * symbols, exactly once per process. Thread-safe: every read and write
 * of the load-state flags happens under the process-wide lock
 * (g_ent_loaded is a plain bool, so there is deliberately no
 * unsynchronized fast path -- a stale read would be exactly the race
 * this lock exists to prevent, and the lock is uncontended after the
 * first load anyway). MariaDB is one shared multithreaded process, so
 * this must guard against two connection threads racing their first
 * enterprise call simultaneously. Returns true iff every required
 * symbol resolved.
 *
 * The load is three steps: the signature gate, the load itself, and
 * the symbol resolution. There is deliberately no separate
 * verify-after-load step, and there does not need to be one: the
 * verified path loads the exact bytes the signature was verified over
 * (via a private temp copy), not the on-disk path, so the bytes that
 * were checked and the bytes that get used are the same bytes by
 * construction -- a time-of-check/time-of-use window cannot open
 * between them. Unverified (missing-signature, soft-allowed) loads
 * keep the previous behavior of loading the path directly: there is
 * no verification claim for a swap to violate. */
static bool
ensure_enterprise_lib(void)
{
    const char *path;
    void       *h;
    unsigned char    *verified_bytes = NULL;
    size_t            verified_len   = 0;
    bool              verified        = false;

    ent_lock();
    if (g_ent_loaded) { ent_unlock(); return true; }
    if (g_ent_attempted) { ent_unlock(); return false; }
    g_ent_attempted = true;
    ent_env_capture_locked();

    path = g_ent_lib;
    if (path == NULL || path[0] == '\0') { ent_unlock(); return false; }

    if (!ent_signature_gate(path, &verified_bytes, &verified_len, &verified))
    {
        ent_unlock();
        return false;
    }

    if (verified)
    {
        h = ent_dlopen_verified_copy(path, verified_bytes, verified_len);
        free(verified_bytes);
    }
    else
        h = ent_dlopen(path);
    if (h == NULL)
    {
        if (verified)
            fprintf(stderr,
                   "fractalsql: enterprise library \"%s\" passed signature "
                   "verification but could not be loaded (dlopen failed: %s)\n",
                   path,
#if defined(_WIN32)
                   "see GetLastError()");
#else
                   dlerror());
#endif
        else
            fprintf(stderr,
                   "fractalsql: enterprise library \"%s\" could not be "
                   "loaded (dlopen failed: %s)\n",
                   path,
#if defined(_WIN32)
                   "see GetLastError()");
#else
                   dlerror());
#endif
        ent_unlock();
        return false;
    }

    if (!ent_resolve_symbols(h))
    {
#if defined(_WIN32)
        FreeLibrary((HMODULE) h);
#else
        dlclose(h);
#endif
        ent_unlock();
        return false;
    }

    g_ent_handle = h;
    g_ent_loaded = true;
    ent_unlock();
    return true;
}

/* ------------------------------------------------------------------ */
/* Read side for the configuration surface (fractalsql_config.h).      */
/* ------------------------------------------------------------------ */

/* The effective value of one configuration key this tier owns.
 * Returns 0 and fills `out` when the key is one this tier owns and
 * currently holds a value for, -1 otherwise. The ledger key is a
 * secret: the config surface redacts it before a session ever sees
 * one, so reading it here is safe. */
int
fractalsql_enterprise_config_value(const char *name, char *out, size_t outcap)
{
    int rc = -1;

    if (name == NULL || out == NULL || outcap == 0) return -1;
    out[0] = '\0';

    /* The copy happens INSIDE the lock: the value is a pointer into
     * the tier's own config, and the provider-reload path frees
     * exactly these strings under the same lock. A copy taken after
     * the unlock was a use-after-free read, racing a `fsqlctl reload`
     * on another connection thread. */
    ent_lock();
    ent_env_capture_locked();
    {
        const char *v = NULL;
        if (strcmp(name, "enterprise_lib") == 0)             v = g_ent_lib;
        else if (strcmp(name, "enterprise_ledger_path") == 0) v = g_ent_ledger_path;
        else if (strcmp(name, "enterprise_ledger_key") == 0)  v = g_ent_ledger_key;
        else if (strcmp(name, "enterprise_require_signature") == 0)
            v = g_ent_require_sig ? "1" : "0";
        if (v != NULL && v[0] != '\0') {
            size_t n = strlen(v);
            if (n > outcap - 1) n = outcap - 1;
            memcpy(out, v, n);
            out[n] = '\0';
            rc = 0;
        }
    }
    ent_unlock();
    return rc;
}

/* ------------------------------------------------------------------ */
/* fractalsqld.conf push path (fractalsql_provider.h contract).       */
/* ------------------------------------------------------------------ */

int
fractalsql_enterprise_check_provider(const struct fsq_provider_cfg *c)
{
    int rc = 0;

    ent_lock();
    ent_env_capture_locked();
    /* The one cross-state a reload cannot survive: the loaded library's
     * 8 resolved symbols have no replace path (live code, VFS state and
     * the ledger VFS all reference it), so an enterprise_lib change is
     * refused while loaded -- restart the daemon to change it. An
     * attempted-but-failed load (or no lib at all) is re-armable: no
     * handle, no symbols, no state to leak. Ledger path/key and
     * require_signature changes are always safe: all ledger file I/O
     * re-opens the effective path per operation under this same lock. */
    if (g_ent_loaded && (c->present & FSQL_PROV_ENT_LIB) &&
        g_ent_lib && *g_ent_lib && strcmp(c->enterprise_lib, g_ent_lib) != 0)
    {
        fprintf(stderr,
                "fractalsql: reload refused: enterprise_lib cannot be changed "
                "live while an enterprise library is loaded (currently \"%s\"); "
                "restart the daemon to change it\n", g_ent_lib);
        rc = -1;
    }
    ent_unlock();
    return rc;
}

int
fractalsql_enterprise_apply_provider(const struct fsq_provider_cfg *c)
{
    char *nlib = NULL, *npath = NULL, *nkey = NULL;
    bool  nsig;
    bool  lib_changed = false;
    int   rc = -1;

    /* We take the lock ourselves: the daemon calls this on startup and
     * on FSQ_OP_RELOAD, and the effective values are read under this
     * same lock everywhere else. */
    ent_lock();
    ent_env_capture_locked();

    if (ent_dup_or((c->present & FSQL_PROV_ENT_LIB)
                       ? c->enterprise_lib : g_ent_env_lib, &nlib) != 0)
        goto oom;
    if (ent_dup_or((c->present & FSQL_PROV_ENT_LEDGER_PATH)
                       ? c->enterprise_ledger_path : g_ent_env_ledger_path,
                   &npath) != 0)
        goto oom;
    if (ent_dup_or((c->present & FSQL_PROV_ENT_LEDGER_KEY)
                       ? c->enterprise_ledger_key : g_ent_env_ledger_key,
                   &nkey) != 0)
        goto oom;
    nsig = (c->present & FSQL_PROV_ENT_REQUIRE_SIG)
               ? c->enterprise_require_signature : g_ent_env_require_sig;

    /* Live ledger-path/key swap is safe: every ledger read/write opens
     * the effective path per operation under g_ent_lock (and the CSV
     * mirror path derives from it), so the NEXT operation after this
     * swap lands in the new file -- continuity between the two files is
     * the operator's responsibility, documented in docs/enterprise.md. */
    lib_changed = (nlib == NULL) != (g_ent_lib == NULL) ||
                  (nlib && g_ent_lib && strcmp(nlib, g_ent_lib) != 0);

    /* Re-check the loaded-library guard check_provider already enforced:
     * that call ran under a SEPARATE ent_lock() acquisition, so a UDF
     * call on another connection could have run ensure_enterprise_lib()
     * (which dlopens under this same lock) in the gap between that check
     * and this apply, flipping g_ent_loaded from false to true. Without
     * re-checking here, this would silently repoint g_ent_lib at the new
     * path while g_ent_handle/its resolved symbols stay bound to the old
     * one -- the exact split-brain state check_provider exists to rule
     * out. Refuse the same way the OOM path does: nothing changed. */
    if (lib_changed && g_ent_loaded) {
        fprintf(stderr,
                "fractalsql: reload refused: enterprise_lib cannot be changed "
                "live while an enterprise library is loaded (currently \"%s\"); "
                "restart the daemon to change it\n", g_ent_lib ? g_ent_lib : "");
        free(nlib); free(npath); free(nkey);
        ent_unlock();
        return -1;
    }

    free(g_ent_lib);
    free(g_ent_ledger_path);
    free(g_ent_ledger_key);
    g_ent_lib          = nlib;
    g_ent_ledger_path  = npath;
    g_ent_ledger_key   = nkey;
    g_ent_require_sig  = nsig;

    /* Re-arm a failed load attempt whenever the library is not loaded.
     * A RELOAD is the operator saying "try again": the file at the
     * configured path may have been replaced in place since the last
     * attempt (the common case -- the library is installed, or
     * re-signed, without its path changing), and the old rule only
     * re-armed when the PATH STRING changed, so a failed load was
     * permanent for the life of the process: every later enterprise
     * call returned "not loaded" with no way out but a daemon
     * restart. Nothing is at risk in re-arming: a failed attempt
     * leaves no handle, no resolved symbols and no state behind, and
     * a load that SUCCEEDS latches g_ent_loaded, so this cannot
     * un-load anything. */
    if (!g_ent_loaded)
        g_ent_attempted = false;
    ent_unlock();
    return 0;

oom:
    free(nlib); free(npath); free(nkey);
    ent_unlock();
    return -1;
}

/* ==================================================================== */
/* Ledger file storage VFS                                              */
/* ==================================================================== */

#define LEDGER_MAGIC     "FSQLLDGR"
#define LEDGER_MAGIC_LEN 8
#define LEDGER_VERSION   1
#define LEDGER_HASH_LEN  32

/* The largest blob a ledger record may hold.
 *
 * The on-disk length field is a uint32_t, so a record header can CLAIM
 * up to 4 GiB -- and the READ path has to be able to trust the length
 * it reads, because two things downstream of it are sized from that
 * number:
 *
 *   - the blob itself is malloc'd at the claimed length, and
 *   - the hash-recomputation buffer is sized
 *     LEDGER_HASH_LEN + blob_len + (has_mac ? LEDGER_HASH_LEN : 0).
 *
 * That second expression is the sharper edge: LEDGER_HASH_LEN is an int
 * literal and blob_len is a uint32_t, so the whole sum is evaluated in
 * 32-bit UNSIGNED arithmetic and only then widened to size_t. A claimed
 * length near 2^32 wraps the sum around to a small number, so the
 * allocation comes out 32 bytes while the memcpy right below it copies
 * the claimed length into it -- a heap overflow in the daemon's own
 * address space, on both the O(1) tip check and the full chain walk.
 * (The WRITE path has always guarded its own copy of this arithmetic;
 * it is the two read paths that were missing the guard.)
 *
 * Nothing this extension writes comes close to 64 MiB -- the QTL blobs
 * and the decision-audit records are kilobytes at most -- so a record
 * claiming more is a corrupt record, not a legitimate one. It is
 * refused as such rather than being sized from. */
#define LEDGER_MAX_BLOB_BYTES (64u * 1024u * 1024u)

/* The ledger's kind tags. The engine's own semantic slots are
 * 1=truth, 2=shadow, 3=shadow_vectors, and the decision-audit chain
 * shares kind=2 with the shadow slot -- one file, one chain per kind,
 * so the two never corrupt each other's hash links; they are simply
 * two different records in the same kind's chain. The tags above 3 are
 * headroom, not a semantic promise: a kind outside 1..LEDGER_MAX_KIND
 * is refused (FSQL_ESTORAGE) rather than appended, so a record can
 * never land under a tag nothing walks. */
#define LEDGER_MAX_KIND 16

typedef struct {
    uint32_t kind;
    uint32_t blob_len;
    uint8_t  has_mac;
    uint8_t  sealed;
    uint8_t  mac[LEDGER_HASH_LEN];
    uint8_t  prev_hash[LEDGER_HASH_LEN];
    uint8_t  entry_hash[LEDGER_HASH_LEN];
    int64_t  updated;
    uint8_t *blob;   /* malloc'd; owned by whoever holds the struct */
} ledger_record_t;

static const char *
ledger_path(void)
{
    ent_env_capture_locked();
    return (g_ent_ledger_path && g_ent_ledger_path[0]) ? g_ent_ledger_path
                                                       : "fractalsql_ledger.dat";
}

static const char *
ledger_key(void)
{
    ent_env_capture_locked();
    return (g_ent_ledger_key && g_ent_ledger_key[0]) ? g_ent_ledger_key : NULL;
}

/* Hex-encodes a hash into `out` (LEDGER_HASH_LEN*2+1 bytes). */
static void
ledger_hex_encode(const uint8_t src[LEDGER_HASH_LEN], char out[LEDGER_HASH_LEN * 2 + 1])
{
    static const char hexd[] = "0123456789abcdef";
    for (int i = 0; i < LEDGER_HASH_LEN; i++)
    {
        out[i * 2]     = hexd[(src[i] >> 4) & 0xF];
        out[i * 2 + 1] = hexd[src[i] & 0xF];
    }
    out[LEDGER_HASH_LEN * 2] = '\0';
}

/* ------------------------------------------------------------------ */
/* Owner-only files                                                     */
/*                                                                       */
/* The ledger file, its CSV mirror and the head file hold the audit      */
/* trail itself, so they are created with mode 0600 -- owner read and    */
/* write, nothing for the group or the world -- instead of whatever the  */
/* process umask happens to allow, and a file that already exists with   */
/* looser permissions is tightened to the same. Creating a file through */
/* fopen() takes the umask, so a deployment that ran with a permissive   */
/* umask left the audit trail readable by every account on the host.     */
/* ------------------------------------------------------------------ */
#if defined(_WIN32) || defined(__CYGWIN__)
#  define LEDGER_FILE_MODE (_S_IREAD | _S_IWRITE)
#else
#  define LEDGER_FILE_MODE 0600
#endif

/* Opens `path` for reading or writing with owner-only permissions.
 *
 * `flags` is the open(2) flag set (O_RDONLY, O_RDWR, O_WRONLY|O_APPEND),
 * `fmode` the matching stream mode for fdopen, and `create` says whether
 * the file may be created. A file this call creates gets
 * LEDGER_FILE_MODE; an existing file's mode is tightened to the same,
 * so a file left behind by an older build keeps no wider permissions.
 * Only a regular file is tightened: whatever else the path names is
 * left exactly as it is.
 * Returns NULL when the file cannot be opened. */
static FILE *
ledger_open_private(const char *path, int flags, const char *fmode, int create)
{
#if defined(_WIN32) || defined(__CYGWIN__)
    int fd;
    int oflags = flags | _O_BINARY | (create ? _O_CREAT : 0);
    if (_sopen_s(&fd, path, oflags, _SH_DENYNO, LEDGER_FILE_MODE) != 0)
        return NULL;
    /* _sopen_s applies the mode only to a file it CREATES, so an
     * existing file keeps whatever permissions it had: tighten it. */
    {
        struct _stat st;
        if (_fstat(fd, &st) == 0 && (st.st_mode & _S_IFREG))
            (void) _chmod(path, LEDGER_FILE_MODE);
    }
    FILE *fp = _fdopen(fd, fmode);
    if (fp == NULL) { (void) _close(fd); return NULL; }
    return fp;
#else
    int fd = open(path, flags | (create ? O_CREAT : 0), LEDGER_FILE_MODE);
    if (fd < 0) return NULL;
    /* Only a regular file is tightened. The configured path is not
     * guaranteed to be one: a path that names a directory opens for
     * reading, and taking a directory's permissions down to the
     * ledger's file mode strips its execute bit -- after which no file
     * inside it can be opened, by this daemon or by anyone else. */
    {
        struct stat st;
        if (fstat(fd, &st) == 0)
        {
            if (S_ISREG(st.st_mode))
                (void) fchmod(fd, LEDGER_FILE_MODE);
            else if ((flags & O_ACCMODE) != O_RDONLY)
            {
                /* A ledger that is written must be a real file. /dev/null
                 * accepts every write and keeps none of it, so an append
                 * would be reported as done while the audit record is
                 * gone; /dev/full and a directory fail only by accident of
                 * the platform (fsync(/dev/null) fails on Linux and
                 * succeeds on macOS). Refuse them up front. */
                (void) close(fd);
                errno = EINVAL;
                return NULL;
            }
        }
    }
    FILE *fp = fdopen(fd, fmode);
    if (fp == NULL) { (void) close(fd); return NULL; }
    return fp;
#endif
}

/* ------------------------------------------------------------------ */
/* The head file: how many rows each chain ever had                     */
/*                                                                       */
/* A hash chain cannot show that its NEWEST records were cut off the end */
/* of the file: nothing follows the last record to disagree with it. The */
/* head file holds, per chain kind, the number of rows that were ever   */
/* appended to that kind -- a counter that lives OUTSIDE the chain and   */
/* is therefore not affected by a truncation of the chain itself.       */
/*                                                                       */
/* The file sits next to the ledger ("<ledger>.head") and is a plain     */
/* text file with one record per line:                                  */
/*                                                                       */
/*   kind=1 rows=12 mac=<64 hex digits>                                */
/*   kind=2 rows=3                                                       */
/*                                                                       */
/* The MAC is an HMAC-SHA256 over "kind=<n> rows=<n>", keyed with the   */
/* enterprise ledger key. With a key configured every head record MUST  */
/* carry a MAC: a record without one was written before the key was set */
/* and the verify reports that as a failure. With no key the records    */
/* carry no MAC at all -- there is nothing to authenticate them with -- */
/* and that missing field is how a later run WITH a key recognises a    */
/* record that predates it.                                             */
/*                                                                       */
/* A head record written before the head file carried MACs is still     */
/* read (it is the bare "<kind> <count>" pair), so an upgraded           */
/* deployment keeps its counters; it simply has no MAC until the next   */
/* append to that kind re-writes the record with one.                   */
/*                                                                       */
/* The file is replaced atomically: a temporary file is written next to */
/* it and renamed over it, so a reader never sees a half-written head.  */
/* ------------------------------------------------------------------ */
#define LEDGER_HEAD_SUFFIX ".head"

typedef struct {
    int       kind;
    long long rows;
    int       has_mac;
    uint8_t   mac[LEDGER_HASH_LEN];
} ledger_head_rec_t;

#define LEDGER_HEAD_MAX_RECS (LEDGER_MAX_KIND + 1)

static int
ledger_head_path(char *buf, size_t cap)
{
    int n = snprintf(buf, cap, "%s" LEDGER_HEAD_SUFFIX, ledger_path());
    return n > 0 && (size_t) n < cap;
}

static int
ledger_hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Case-insensitive comparison of two short strings. */
static bool
ledger_str_eq_ci(const char *a, const char *b)
{
    if (a == NULL || b == NULL) return a == b;
    for (; *a && *b; a++, b++)
    {
        int ca = (unsigned char) *a, cb = (unsigned char) *b;
        if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
        if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
        if (ca != cb) return false;
    }
    return *a == '\0' && *b == '\0';
}

/* Parses one head-file record: "kind=<n> rows=<n>" with an optional
 * " mac=<hex>" after it. A bare "<kind> <count>" pair is the form used
 * before the head records carried MACs; it is read as a record with no
 * MAC. Returns false when the line is not a record this build
 * understands. */
static bool
ledger_head_parse(const char *line, ledger_head_rec_t *rec)
{
    const char *p = line;

    rec->kind    = -1;
    rec->rows    = -1;
    rec->has_mac = 0;
    memset(rec->mac, 0, sizeof rec->mac);

    while (*p == ' ' || *p == '\t') p++;

    /* The pre-MAC form: a bare "<kind> <count>" pair. */
    if (*p >= '0' && *p <= '9')
    {
        char *end = NULL;
        long k = strtol(p, &end, 10);
        if (end == p) return false;
        p = end;
        while (*p == ' ' || *p == '\t') p++;
        if (*p < '0' || *p > '9') return false;
        long long c = strtoll(p, &end, 10);
        if (end == p) return false;
        p = end;
        while (*p == ' ' || *p == '\t') p++;
        if (*p != '\0' && *p != '\n' && *p != '\r') return false;
        rec->kind = (int) k;
        rec->rows = c;
        return true;   /* no MAC: this record predates the ledger key */
    }

    while (*p != '\0')
    {
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '\n' || *p == '\r') break;

        if (strncmp(p, "kind=", 5) == 0)
        {
            char *end = NULL;
            p += 5;
            rec->kind = (int) strtol(p, &end, 10);
            if (end == p) return false;
            p = end;
        }
        else if (strncmp(p, "rows=", 5) == 0)
        {
            char *end = NULL;
            p += 5;
            rec->rows = strtoll(p, &end, 10);
            if (end == p) return false;
            p = end;
        }
        else if (strncmp(p, "mac=", 4) == 0)
        {
            p += 4;
            for (int i = 0; i < LEDGER_HASH_LEN; i++)
            {
                int hi = ledger_hex_value(p[i * 2]);
                int lo = ledger_hex_value(p[i * 2 + 1]);
                if (hi < 0 || lo < 0) return false;
                rec->mac[i] = (uint8_t) ((hi << 4) | lo);
            }
            p += LEDGER_HASH_LEN * 2;
            rec->has_mac = 1;
        }
        else return false;   /* an unknown field: not a record of ours */
    }
    return (rec->kind >= 0 && rec->rows >= 0);
}

/* Reads the head file into `recs` (at most `max` records). Returns the
 * number of records read, or -1 when a file exists but does not parse
 * -- a corrupt head and a missing head are different things, because a
 * missing one means "there is no head information" while a corrupt one
 * means the file was damaged. */
static int
ledger_head_read(ledger_head_rec_t *recs, int max)
{
    char p[4096];
    if (!ledger_head_path(p, sizeof p)) return 0;

    FILE *fp = ledger_open_private(p, O_RDONLY, "rb", 0);
    if (fp == NULL) return 0;    /* no head file yet: nothing to compare */

    int  n = 0;
    char line[512];
    while (n < max && fgets(line, sizeof line, fp) != NULL)
    {
        const char *q = line;
        while (*q == ' ' || *q == '\t') q++;
        if (*q == '\0' || *q == '\n' || *q == '\r' || *q == '#') continue;
        if (!ledger_head_parse(line, &recs[n])) { fclose(fp); return -1; }
        n++;
    }
    fclose(fp);
    return n;
}

/* Renames `tmp` over `dst`. POSIX rename() replaces an existing file
 * atomically; the Windows C runtime's rename() refuses to, so the
 * platform's replace-move is used there. */
static bool
ledger_replace_file(const char *tmp, const char *dst)
{
#if defined(_WIN32) || defined(__CYGWIN__)
    return MoveFileExA(tmp, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
    return rename(tmp, dst) == 0;
#endif
}

/* Replaces the head file with `recs`. The write goes to a temporary file
 * next to it which is then renamed over the head, so a reader never
 * sees a partially written file and a crash cannot leave a head that
 * says something the chain does not. */
static bool
ledger_head_write(const ledger_head_rec_t *recs, int n)
{
    char p[4096];
    if (!ledger_head_path(p, sizeof p)) return false;

    char tmp[4200];
    int  tn = snprintf(tmp, sizeof tmp, "%s.tmp", p);
    if (tn < 0 || (size_t) tn >= sizeof tmp) return false;

    FILE *fp = ledger_open_private(tmp, O_WRONLY | O_TRUNC | O_CREAT, "wb", 1);
    if (fp == NULL) return false;

    bool ok = true;
    for (int i = 0; i < n && ok; i++)
    {
        char mac_hex[LEDGER_HASH_LEN * 2 + 1];
        if (recs[i].has_mac)
        {
            ledger_hex_encode(recs[i].mac, mac_hex);
            ok = fprintf(fp, "kind=%d rows=%lld mac=%s\n",
                         recs[i].kind, recs[i].rows, mac_hex) > 0;
        }
        else
        {
            ok = fprintf(fp, "kind=%d rows=%lld\n", recs[i].kind, recs[i].rows) > 0;
        }
    }
    if (ok) ok = (fflush(fp) == 0);
    if (ok)
    {
#if defined(_WIN32) || defined(__CYGWIN__)
        ok = (_commit(_fileno(fp)) == 0);
#else
        ok = (fsync(fileno(fp)) == 0);
#endif
    }
    fclose(fp);
    if (!ok) { (void) remove(tmp); return false; }
    if (!ledger_replace_file(tmp, p)) { (void) remove(tmp); return false; }
    return true;
}

/* The MAC of a head record: an HMAC-SHA256 over the record's own
 * content, keyed with the enterprise ledger key. */
static bool
ledger_head_mac(int kind, long long rows, const char *key,
                uint8_t out[LEDGER_HASH_LEN])
{
    char msg[64];
    int  n = snprintf(msg, sizeof msg, "kind=%d rows=%lld", kind, rows);
    if (n < 0 || (size_t) n >= sizeof msg) return false;
    fsql_hmac_sha256((const uint8_t *) key, strlen(key),
                     (const uint8_t *) msg, (size_t) n, out);
    return true;
}

/* Updates the head file after a successful append to `kind`.
 *
 * `chain_rows` is the number of records of this kind the chain held
 * BEFORE the append, so the record just written is number chain_rows+1.
 * The counter in the head file never goes down: it counts the rows that
 * were EVER appended, so a chain that was truncated cannot pull the
 * counter down with it and hide the truncation.
 *
 * Returns the row count the head file now records for `kind`, or -1
 * when the head file could not be updated (in which case the count it
 * would have recorded is still returned, so the caller can publish it). */
static long long
ledger_head_update(int kind, long long chain_rows)
{
    char p[4096];
    if (!ledger_head_path(p, sizeof p)) return -1;

    ledger_head_rec_t recs[LEDGER_HEAD_MAX_RECS];
    int n = ledger_head_read(recs, LEDGER_HEAD_MAX_RECS);
    if (n < 0)
    {
        /* A head file that does not parse is replaced: the chain is the
         * authoritative store and the head file is derived from it. */
        n = 0;
    }

    int slot = -1;
    for (int i = 0; i < n; i++) if (recs[i].kind == kind) { slot = i; break; }
    if (slot < 0)
    {
        if (n >= LEDGER_HEAD_MAX_RECS) return -1;
        slot = n++;
        recs[slot].kind    = kind;
        recs[slot].rows    = 0;
        recs[slot].has_mac = 0;
        memset(recs[slot].mac, 0, sizeof recs[slot].mac);
    }

    long long rows = recs[slot].rows;
    if (chain_rows + 1 > rows) rows = chain_rows + 1;
    recs[slot].rows = rows;

    const char *key = ledger_key();
    if (key != NULL)
    {
        uint8_t mac[LEDGER_HASH_LEN];
        if (ledger_head_mac(kind, rows, key, mac))
        {
            memcpy(recs[slot].mac, mac, LEDGER_HASH_LEN);
            recs[slot].has_mac = 1;
        }
    }
    else
    {
        /* No key: the record carries no MAC. A later run WITH a key has
         * to be able to tell that this record predates the key, and a
         * missing MAC field is how it says so. */
        recs[slot].has_mac = 0;
        memset(recs[slot].mac, 0, sizeof recs[slot].mac);
    }

    if (!ledger_head_write(recs, n))
        fprintf(stderr, "fractalsql-ledger: could not update the head file %s\n", p);
    return rows;
}

/* Checks the head file against the chain that was just walked.
 *
 * Returns NULL when everything agrees, or the reason the verify fails.
 *
 * A head file that does not exist, or that has no record for this kind,
 * is not a failure: there is no head information to compare against
 * (a ledger written before the head file existed). A record that IS
 * there has to be right: with a key configured its MAC must be present
 * and must match its own contents -- a head record edited by hand does
 * not. The row count it claims is compared with the chain by the
 * caller. */
static const char *
ledger_head_check(int kind)
{
    ledger_head_rec_t recs[LEDGER_HEAD_MAX_RECS];
    int n = ledger_head_read(recs, LEDGER_HEAD_MAX_RECS);
    if (n < 0) return "the head file is corrupt or was edited by hand";

    const ledger_head_rec_t *rec = NULL;
    for (int i = 0; i < n; i++) if (recs[i].kind == kind) { rec = &recs[i]; break; }
    if (rec == NULL) return NULL;

    const char *key = ledger_key();
    if (key != NULL)
    {
        if (!rec->has_mac)
            return "the head record has no MAC (it was written before the ledger key was set)";
        uint8_t mac[LEDGER_HASH_LEN];
        if (!ledger_head_mac(rec->kind, rec->rows, key, mac))
            return "the head record's MAC could not be computed";
        if (CRYPTO_memcmp(mac, rec->mac, LEDGER_HASH_LEN) != 0)
            return "the head record's MAC does not match its contents (the head was edited by hand)";
    }
    return NULL;
}

static void
ledger_head_clear(void)
{
    char p[4096];
    ent_lock();
    if (ledger_head_path(p, sizeof p)) remove(p);
    ent_unlock();
}

/* The recorded high-water row count for one kind (0 when none). Caller holds the ledger lock. */
static long long
ledger_head_get(uint32_t kind)
{
    ledger_head_rec_t recs[LEDGER_HEAD_MAX_RECS];
    int n;
    if (kind < 1 || kind > LEDGER_MAX_KIND) return 0;
    n = ledger_head_read(recs, LEDGER_HEAD_MAX_RECS);
    if (n < 0) return 0;
    for (int i = 0; i < n; i++)
        if (recs[i].kind == (int) kind) return recs[i].rows;
    return 0;
}

/* ------------------------------------------------------------------ */
/* The anchor log                                                       */
/*                                                                       */
/* A chain cannot show that its newest records were cut off the end, so */
/* an operator can have the daemon publish the chain's state to a place  */
/* whose administrator cannot rewrite it. FSQL_LEDGER_ANCHOR_LOG picks  */
/* the sink: off (the default), stderr or syslog. Exactly one JSON line  */
/* is published per append:                                           */
/*                                                                       */
/*   {"event":"ledger_head","kind":2,"rows":7,"hash":"<64 hex digits>"}  */
/*                                                                       */
/* where `kind` is the chain kind, `rows` is the number of rows the    */
/* head file records for that kind, and `hash` is the newest entry hash */
/* of that chain -- the value the chain's next record links to. Nothing */
/* is published while the anchor log is off.                            */
/* ------------------------------------------------------------------ */
#define LEDGER_ANCHOR_OFF    0
#define LEDGER_ANCHOR_STDERR 1
#define LEDGER_ANCHOR_SYSLOG 2

static int
ledger_anchor_mode(void)
{
    /* Read once and cached: the sink is a process-wide decision, and the
     * append path must not call getenv() for every record it writes. */
    static int cached = -1;
    if (cached < 0)
    {
        cached = LEDGER_ANCHOR_OFF;
        const char *e = getenv("FSQL_LEDGER_ANCHOR_LOG");
        if (e != NULL && e[0] != '\0')
        {
            if (ledger_str_eq_ci(e, "stderr"))      cached = LEDGER_ANCHOR_STDERR;
            else if (ledger_str_eq_ci(e, "syslog")) cached = LEDGER_ANCHOR_SYSLOG;
        }
    }
    return cached;
}

static void
ledger_anchor_publish(int kind, long long rows,
                       const uint8_t entry_hash[LEDGER_HASH_LEN])
{
    int mode = ledger_anchor_mode();
    if (mode == LEDGER_ANCHOR_OFF) return;

    char hash_hex[LEDGER_HASH_LEN * 2 + 1];
    ledger_hex_encode(entry_hash, hash_hex);

    char line[256];
    int  n = snprintf(line, sizeof line,
                      "{\"event\":\"ledger_head\",\"kind\":%d,\"rows\":%lld,\"hash\":\"%s\"}",
                      kind, rows, hash_hex);
    if (n < 0 || (size_t) n >= sizeof line) return;

    if (mode == LEDGER_ANCHOR_SYSLOG)
    {
#ifndef _WIN32
        syslog(LOG_INFO, "%s", line);
        return;
#else
        /* No system logger on this platform: the line goes to standard
         * error rather than being dropped. */
#endif
    }
    fprintf(stderr, "%s\n", line);
    fflush(stderr);
}

/* ------------------------------------------------------------------ */
/* CSV mirror -- makes the ledger genuinely SQL-queryable.               */
/*                                                                       */
/* The binary chain file above (ledger_path()) remains the SOLE          */
/* authoritative store: it is what the hash-chain algorithm, entry_hash  */
/* recomputation, and fractal_ledger_verify all read. Every successful   */
/* append to it ALSO appends one row here, in a MariaDB CONNECT-engine-  */
/* readable CSV format (id,kind,blob_b64,mac_hex,prev_hash_hex,          */
/* entry_hash_hex,sealed,updated). Installing                            */
/* sql/install_enterprise_connect.sql creates a READONLY CONNECT         */
/* TABLE_TYPE=CSV table over this file, giving real `SELECT ... FROM     */
/* fractalsql_ledger WHERE kind = 2 ORDER BY id DESC` straight from SQL. */
/* READONLY=1 on that table is load-bearing: it stops a stray SQL client */
/* INSERT/UPDATE/DELETE from corrupting a mirror row without going       */
/* through (and being caught by) the hash-chain in the binary file,      */
/* since the mirror itself carries no hash-chain enforcement of its own, */
/* it's a read surface, not a second source of truth.                    */
/*                                                                       */
/* Base64/hex are used (not raw bytes) so the mirror stays a plain textual */
/* CSV file with no escaping/quoting edge cases (no separator or quote      */
/* character can ever appear in a base64 or hex string). The CSV write is */
/* BEST-EFFORT: if it fails after the binary append already succeeded,     */
/* the flush as a whole still reports success (the authoritative chain is  */
/* intact) and the mirror is simply stale for that one row until the next  */
/* successful write -- documented, not silently different from what a      */
/* caller would expect of a "read convenience" surface. */

static const char *
ledger_csv_path(void)
{
    static char buf[4096];
    const char *base = ledger_path();
    size_t      n    = strlen(base);
    if (n + 4 >= sizeof buf) return NULL;   /* pathologically long path; skip the mirror */
    memcpy(buf, base, n);
    memcpy(buf + n, ".csv", 5);   /* includes the NUL */
    return buf;
}

static const char b64_alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Base64-encodes `len` bytes of `data` into caller-allocated `out`
 * (must be at least ledger_b64_len(len)+1 bytes). NUL-terminates. */
static void
ledger_b64_encode(const uint8_t *data, size_t len, char *out)
{
    size_t i, o = 0;
    for (i = 0; i + 2 < len; i += 3)
    {
        uint32_t v = ((uint32_t) data[i] << 16) | ((uint32_t) data[i + 1] << 8) | data[i + 2];
        out[o++] = b64_alphabet[(v >> 18) & 0x3F];
        out[o++] = b64_alphabet[(v >> 12) & 0x3F];
        out[o++] = b64_alphabet[(v >> 6) & 0x3F];
        out[o++] = b64_alphabet[v & 0x3F];
    }
    size_t rem = len - i;
    if (rem == 1)
    {
        uint32_t v = (uint32_t) data[i] << 16;
        out[o++] = b64_alphabet[(v >> 18) & 0x3F];
        out[o++] = b64_alphabet[(v >> 12) & 0x3F];
        out[o++] = '=';
        out[o++] = '=';
    }
    else if (rem == 2)
    {
        uint32_t v = ((uint32_t) data[i] << 16) | ((uint32_t) data[i + 1] << 8);
        out[o++] = b64_alphabet[(v >> 18) & 0x3F];
        out[o++] = b64_alphabet[(v >> 12) & 0x3F];
        out[o++] = b64_alphabet[(v >> 6) & 0x3F];
        out[o++] = '=';
    }
    out[o] = '\0';
}

static size_t
ledger_b64_len(size_t len)
{
    return ((len + 2) / 3) * 4;
}

/* Counts existing lines in the CSV mirror (0 if it doesn't exist yet).
 * Used as a FLOOR on the row's id: the chain's own record count is the
 * id's source of truth (see ledger_csv_append), but a mirror that is
 * ahead of the chain -- a torn-tail repair discarded a chain record the
 * mirror still has a row for -- must not hand out an id the mirror has
 * already used. A plain line count, not a per-kind count: `id` is a
 * single sequence shared by kind=1 and kind=2 rows, not two independent
 * per-kind sequences. */
static long long
ledger_csv_next_id(const char *path)
{
    FILE *fp = ledger_open_private(path, O_RDONLY, "rb", 0);
    if (fp == NULL) return 1;
    long long n = 0;
    int c;
    while ((c = fgetc(fp)) != EOF) if (c == '\n') n++;
    fclose(fp);
    return n + 1;
}

/* Best-effort: appends one CSV row. Never fails the caller's flush --
 * see this section's header comment.
 *
 * `id` is the row's position in the chain (the authoritative binary
 * store), NOT a line count of this mirror file. The CSV write is
 * best-effort and can fail on its own (a full disk, a path the daemon
 * cannot write) while the binary append has already succeeded, so
 * counting mirror lines would drift from the chain and could repeat an
 * id. The chain's own record count is the source of truth for the id
 * whether or not the mirror kept up. */
static void
ledger_csv_append(uint32_t kind, const void *payload, size_t len,
                  bool has_mac, const uint8_t mac[LEDGER_HASH_LEN],
                  const uint8_t prev_hash[LEDGER_HASH_LEN],
                  const uint8_t entry_hash[LEDGER_HASH_LEN],
                  int64_t updated, long long chain_records)
{
    const char *csv_path = ledger_csv_path();
    if (csv_path == NULL) return;

    char *b64 = (char *) malloc(ledger_b64_len(len) + 1);
    if (b64 == NULL) return;
    ledger_b64_encode((const uint8_t *) payload, len, b64);

    char mac_hex[LEDGER_HASH_LEN * 2 + 1];
    char prev_hex[LEDGER_HASH_LEN * 2 + 1];
    char hash_hex[LEDGER_HASH_LEN * 2 + 1];
    ledger_hex_encode(prev_hash, prev_hex);
    ledger_hex_encode(entry_hash, hash_hex);
    if (has_mac) ledger_hex_encode(mac, mac_hex); else mac_hex[0] = '\0';

    /* The chain's record count is the row's id. It is the position this
     * record occupies in the authoritative store, and it is what the
     * mirror's ORDER BY id is meant to reproduce. The mirror's own line
     * count is a floor on it: a mirror left ahead of the chain (a
     * torn-tail repair discarded a chain record the mirror still has a
     * row for) must not hand out an id it has already used. */
    long long next_id = chain_records + 1;
    {
        long long mirror_next = ledger_csv_next_id(csv_path);
        if (mirror_next > next_id) next_id = mirror_next;
    }

    FILE *fp = ledger_open_private(csv_path, O_WRONLY | O_APPEND, "ab", 1);
    if (fp != NULL)
    {
        fprintf(fp, "%lld,%u,%s,%s,%s,%s,0,%lld\n",
               next_id, kind, b64, mac_hex, prev_hex, hash_hex, (long long) updated);
        fclose(fp);
    }
    free(b64);
}

/* Reads one record's fixed-size header fields (everything up to, but not
 * including, the variable-length blob). Returns 1 on success, 0 on clean
 * EOF (no bytes read at all), -1 on a short/corrupt read. */
static int
ledger_read_record_header(FILE *fp, uint32_t *kind, uint32_t *blen,
                          uint8_t *has_mac, uint8_t *sealed,
                          uint8_t mac[LEDGER_HASH_LEN],
                          uint8_t prev[LEDGER_HASH_LEN],
                          uint8_t hash[LEDGER_HASH_LEN],
                          int64_t *updated)
{
    uint8_t reserved[2];
    size_t  got;

    got = fread(kind, sizeof *kind, 1, fp);
    if (got != 1) return feof(fp) && !ferror(fp) ? 0 : -1;

    if (fread(blen, sizeof *blen, 1, fp) != 1) return -1;
    if (fread(has_mac, 1, 1, fp) != 1) return -1;
    if (fread(sealed, 1, 1, fp) != 1) return -1;
    if (fread(reserved, 1, 2, fp) != 2) return -1;
    if (fread(mac, 1, LEDGER_HASH_LEN, fp) != LEDGER_HASH_LEN) return -1;
    if (fread(prev, 1, LEDGER_HASH_LEN, fp) != LEDGER_HASH_LEN) return -1;
    if (fread(hash, 1, LEDGER_HASH_LEN, fp) != LEDGER_HASH_LEN) return -1;
    if (fread(updated, sizeof *updated, 1, fp) != 1) return -1;
    return 1;
}

static bool
ledger_write_header(FILE *fp)
{
    if (fwrite(LEDGER_MAGIC, 1, LEDGER_MAGIC_LEN, fp) != LEDGER_MAGIC_LEN)
        return false;
    if (fputc(LEDGER_VERSION, fp) == EOF)
        return false;
    return true;
}

/* Opens the ledger file for reading, validating its magic/version.
 * Returns NULL (fp not opened, no error) if the file doesn't exist yet --
 * an empty ledger, not a fault. Returns NULL with *bad_header=true if the
 * file exists but its header is unrecognized (corrupt/incompatible). */
static FILE *
ledger_open_for_read(bool *bad_header)
{
    *bad_header = false;
    FILE *fp = ledger_open_private(ledger_path(), O_RDONLY, "rb", 0);
    if (fp == NULL) return NULL;

    char magic[LEDGER_MAGIC_LEN];
    if (fread(magic, 1, LEDGER_MAGIC_LEN, fp) != LEDGER_MAGIC_LEN ||
        memcmp(magic, LEDGER_MAGIC, LEDGER_MAGIC_LEN) != 0 ||
        fgetc(fp) != LEDGER_VERSION)
    {
        fclose(fp);
        *bad_header = true;
        return NULL;
    }
    return fp;
}

/* Sequential scan (fp positioned right after the header) collecting the
 * latest TWO records matching `want_kind`, equivalent to
 * "SELECT ... WHERE kind = $1 ORDER BY id DESC LIMIT 2" over the chain.
 * Ledger sizes here are test/demo scale, not a high-volume production
 * log, so a full scan
 * per call is the simplest correct implementation; an index isn't worth
 * the complexity yet. Frees discarded candidates itself. Returns 0 on a
 * clean scan (have_latest/have_prior report what was found), -1 on a
 * corrupt/truncated file.
 *
 * *out_records, when not NULL, receives the number of records the scan
 * walked over -- ALL of them, not just the ones of `want_kind`. That is
 * the chain's own record count, i.e. the 1-based position the next
 * appended record will occupy, and it is what the CSV mirror's `id`
 * column is derived from (see ledger_csv_append).
 *
 * *out_kind_records, when not NULL, receives the number of records of
 * `want_kind` alone -- the chain's row count for that kind, which is
 * what the head file records (see ledger_head_update). */
static int
ledger_scan_latest_two(FILE *fp, uint32_t want_kind,
                       ledger_record_t *latest, bool *have_latest,
                       ledger_record_t *prior,  bool *have_prior,
                       long long *out_records,
                       long long *out_kind_records)
{
    *have_latest = false;
    *have_prior  = false;
    /* Zero both outputs: the first match copies *latest into *prior
     * wholesale, and without this that copy starts from indeterminate
     * stack bytes (incl. an indeterminate blob pointer). Every
     * downstream use is gated by the have_* flags, but the copies are
     * real reads of uninitialized memory all the same. */
    memset(latest, 0, sizeof *latest);
    memset(prior,  0, sizeof *prior);
    long long records = 0;
    long long kind_records = 0;

    for (;;)
    {
        uint32_t kind, blen;
        uint8_t  has_mac, sealed, mac[LEDGER_HASH_LEN], prev[LEDGER_HASH_LEN], hash[LEDGER_HASH_LEN];
        int64_t  updated;
        int      hr = ledger_read_record_header(fp, &kind, &blen, &has_mac, &sealed,
                                                mac, prev, hash, &updated);
        if (hr == 0) break;
        if (hr < 0) goto fail;
        records++;   /* a complete record header: the chain grows by one */

        uint8_t *blob = NULL;
        if (blen > 0)
        {
            /* The claimed length is checked BEFORE it sizes anything:
             * see LEDGER_MAX_BLOB_BYTES for why an unchecked length
             * from the file is a heap overflow, not just a big
             * allocation. A record that claims an implausible length
             * is a corrupt record, and the scan says so. */
            if (blen > LEDGER_MAX_BLOB_BYTES) goto fail;
            blob = (uint8_t *) malloc(blen);
            if (blob == NULL) goto fail;
            if (fread(blob, 1, blen, fp) != blen) { free(blob); goto fail; }
        }

        if (kind == want_kind)
        {
            kind_records++;
            if (*have_prior) free(prior->blob);
            *prior      = *latest;
            *have_prior = *have_latest;

            latest->kind       = kind;
            latest->blob_len   = blen;
            latest->has_mac    = has_mac;
            latest->sealed     = sealed;
            memcpy(latest->mac,        mac,  LEDGER_HASH_LEN);
            memcpy(latest->prev_hash,  prev, LEDGER_HASH_LEN);
            memcpy(latest->entry_hash, hash, LEDGER_HASH_LEN);
            latest->updated    = updated;
            latest->blob       = blob;
            *have_latest = true;
        }
        else
        {
            free(blob);
        }
    }
    if (out_records) *out_records = records;
    if (out_kind_records) *out_kind_records = kind_records;
    return 0;

fail:
    /* A scan that gives up must not keep what it read. The two blob
     * buffers belong to the two records this scan was tracking, and
     * every caller returns immediately on rc < 0 -- so without this,
     * each aborted scan leaked up to 2 x LEDGER_MAX_BLOB_BYTES. The
     * paths that reach here are the ordinary ones for a corrupt tail
     * (a crash mid-append) and they are walked again by every later
     * read and verify, in a process that never restarts. */
    free(latest->blob); latest->blob = NULL;
    free(prior->blob);  prior->blob  = NULL;
    *have_latest = false;
    *have_prior  = false;
    return -1;
}

/* Diagnostics for the ledger write path: the UDF layer collapses every
 * storage failure into one SQL error, so an append that starts failing
 * (bad path, bad permissions, a flush that silently drops bytes) is
 * undebuggable from the SQL surface alone. Each FSQL_ESTORAGE exit in
 * ledger_write_entry therefore names itself on stderr -- the daemon's
 * error log destination -- before returning. */
static void
ledger_log_exit(const char *where)
{
    fprintf(stderr, "fractalsql-ledger: write path failed at %s (errno=%d)\n",
            where, errno);
}

/* write_entry: append one new record for `kind`, chained to the latest
 * existing record of the same kind (or the all-zero genesis sentinel),
 * via a file append. */
/* Torn-tail recovery: a crash or power loss mid-append can leave a
 * truncated final record, and since every reader treats a short record
 * as fatal, that would brick the file for every future write. Walk the
 * records; the first one whose header or blob reads short marks the torn
 * tail -- truncate the file there so the chain ends at the last complete
 * record. Only bytes after a validated header ever get discarded, and
 * only on a file that just failed its scan. Returns false when the file
 * cannot be made scan-clean (missing file is not a failure -- there is
 * nothing to repair; a bad header is not a torn tail and is left alone). */
static bool
ledger_repair_torn_tail(void)
{
    bool  bad_header = false;
    FILE *fp = ledger_open_for_read(&bad_header);
    if (fp == NULL) return !bad_header;

    long torn_at = -1L;
    for (;;)
    {
        long rec_start = ftell(fp);
        uint32_t kind, blen;
        uint8_t  has_mac, sealed, mac[LEDGER_HASH_LEN], prev[LEDGER_HASH_LEN], hash[LEDGER_HASH_LEN];
        int64_t  updated;
        int      hr;

        if (rec_start < 0L) { fclose(fp); return false; }
        hr = ledger_read_record_header(fp, &kind, &blen, &has_mac, &sealed,
                                       mac, prev, hash, &updated);
        if (hr == 0) break;                         /* clean EOF: nothing torn */
        if (hr < 0) { torn_at = rec_start; break; } /* torn header */

        if (blen > 0)
        {
            /* An implausible length is treated as a torn tail, the same
             * as a blob that reads short: the record cannot be parsed,
             * so the chain ends before it and the file is truncated
             * there. (The alternative -- refusing the file outright --
             * would leave the ledger permanently unwritable, since the
             * write path only ever repairs a torn tail.) */
            if (blen > LEDGER_MAX_BLOB_BYTES) { torn_at = rec_start; break; }
            uint8_t *blob = (uint8_t *) malloc(blen);
            if (blob == NULL) { fclose(fp); return false; }
            if (fread(blob, 1, blen, fp) != blen) { free(blob); torn_at = rec_start; break; }
            free(blob);
        }
    }

    if (torn_at >= 0L)
    {
        /* ledger_open_for_read handed us a read-only FILE*: truncating
         * through it (ftruncate/_chsize both write) fails on every
         * platform -- on Windows with EACCES -- so a torn tail could
         * never actually be repaired and one bad append bricked the
         * file for good. Reopen read-write for the truncate. */
        fclose(fp);
#if defined(_WIN32) || defined(__CYGWIN__)
        FILE *wr = ledger_open_private(ledger_path(), O_RDWR, "r+b", 0);
        if (wr == NULL) return false;
        int rc = _chsize(_fileno(wr), torn_at);
        int werr = errno;
        fclose(wr);
#else
        FILE *wr = ledger_open_private(ledger_path(), O_RDWR, "r+b", 0);
        if (wr == NULL) return false;
        int rc = ftruncate(fileno(wr), torn_at);
        int werr = errno;
        fclose(wr);
#endif
        if (rc != 0) { errno = werr; return false; }
        /* fp was already closed above (read-only handles can't
         * truncate) -- the trailing fclose(fp) below is for the
         * no-torn-tail path, where fp is still open. Falling through
         * to it here double-closed an already-closed FILE*, a real
         * double-free confirmed live under ASan (no test exercised
         * this repair path until the torn-tail test that found it). */
        return true;
    }
    fclose(fp);
    return true;
}

static int
ledger_write_entry(fsql_storage_user_ctx user, int kind,
                   const void *payload, size_t len)
{
    (void) user;

    /* The kind must be one the ledger knows. The engine's own semantic
     * slots are 1=truth, 2=shadow, 3=shadow_vectors, and the
     * decision-audit chain shares kind=2 with the shadow slot; the
     * bound above those is headroom, not a semantic promise. A kind
     * outside it is REFUSED (FSQL_ESTORAGE) rather than appended: a
     * record under a tag nothing reads is a record the verifier will
     * never walk and the operator will never find, and an unbounded
     * tag range is a way for a caller to grow the per-thread read
     * slots without limit. */
    if (kind < 1 || kind > LEDGER_MAX_KIND)
    {
        ledger_log_exit("kind out of range");
        return FSQL_ESTORAGE;
    }

    /* The record header stores the blob length as uint32_t: a silent
     * truncation here would write a record whose header undersells its
     * own bytes (an instant chain brick for every later reader). No
     * current caller can reach this (packet caps bound len far below
     * 4 GiB), but this is an exported seam -- fail loudly instead.
     *
     * WHY 0xFFFFFFFFu AND NOT 0x7fffffffu: the threshold is the
     * format's own limit -- the on-disk record header's length field
     * is a uint32_t, so a length above 2^32-1 simply cannot be
     * represented in the record this function is about to write. It
     * is NOT an `int`-truncation bound (0x7fffffffu is what a
     * signed-`int` blob length would force, and there is
     * no such call on this path).
     *
     * AND WHY THIS CHECK MUST STAY WHERE IT IS: this bound is
     * evaluated at the ENTRY of ledger_write_entry, strictly BEFORE
     * the `buflen = LEDGER_HASH_LEN + len + (have_mac ? LEDGER_HASH_LEN
     * : 0)` arithmetic further down. That ordering is the whole
     * invariant. The buflen expression is what sizes the malloc that
     * the three memcpy() calls below write into, so a `len` large
     * enough to wrap `buflen` around size_t's range would UNDERSIZE
     * the allocation relative to the bytes actually copied into it --
     * a heap overflow, in the exact place where a ledger record is
     * being hashed. Checking the bound after the arithmetic would
     * check a number that had already wrapped. The 64-bit daemon
     * cannot wrap buflen at len <= 0xFFFFFFFF, but the SIZE_MAX
     * guard below keeps the intent explicit (and true) if the code
     * ever grows a 32-bit build, where it would otherwise be
     * load-bearing. */
    if (len > 0xFFFFFFFFu) { ledger_log_exit("oversize blob"); return FSQL_ESTORAGE; }
    /* The writer must respect the SAME ceiling the readers enforce
     * (LEDGER_MAX_BLOB_BYTES). A record larger than the readers will
     * accept is worse than no record at all: the next append's scan
     * refuses the file, the repair path classifies the oversized
     * record as a torn tail and truncates the ledger AT IT -- so the
     * record just written is silently destroyed while the CSV mirror
     * keeps its row, and the two stores diverge for good. Refusing the
     * write is loud, immediate, and leaves the chain intact.
     * Nothing this extension writes comes close to the ceiling (the
     * QTL blobs and the decision-audit records are kilobytes at most),
     * so this bounds the writer to the same contract the reader has
     * always had. */
    if (len > LEDGER_MAX_BLOB_BYTES)
    {
        ledger_log_exit("oversize blob");
        return FSQL_ESTORAGE;
    }
    /* The second half of the same invariant, stated in the units the
     * buflen arithmetic actually uses: the total buffer size must be
     * representable. On a 64-bit size_t this can never fail given the
     * bound above; on a 32-bit size_t it is the difference between a
     * clean rejection and a wrapped allocation size. */
    if (len > SIZE_MAX - 2 * (size_t) LEDGER_HASH_LEN)
    {
        ledger_log_exit("oversize blob");
        return FSQL_ESTORAGE;
    }

    ent_lock();

    FILE *fp = ledger_open_private(ledger_path(), O_RDWR, "r+b", 0);
    bool  is_new = false;
    if (fp == NULL)
    {
        fp = ledger_open_private(ledger_path(), O_RDWR, "r+b", 1);
        if (fp == NULL) { ledger_log_exit("open new ledger"); ent_unlock(); return FSQL_ESTORAGE; }
        is_new = true;
    }
    else
    {
        /* A ZERO-LENGTH file is not a corrupt ledger: it is a ledger
         * that was created but never got its header (a crash between
         * the create and the first append, an operator's `touch`, a
         * copy that lost the tail). There is no chain in it to lose,
         * so the header is written here and the file becomes a
         * normal, empty ledger. Without this, one zero-byte file
         * bricked the ledger PERMANENTLY: the file existed, so the
         * "r+b" open above succeeded and the read path below saw a
         * file with no magic and refused every append -- and the
         * operator's only way out was to delete the file, and with it
         * the whole chain. A NON-EMPTY file with a bad header is
         * still refused below: it holds data this build cannot read,
         * and overwriting it would destroy it. */
        long sz = -1L;
        if (fseek(fp, 0, SEEK_END) == 0) sz = ftell(fp);
        if (sz == 0) is_new = true;
        /* The ledger is append-only (a hash chain cannot lose a row
         * without breaking), so it is bounded by size instead.
         * FRACTALSQL_LEDGER_MAX_BYTES (default 1 GiB; 0 = unbounded) is the size
         * past which appends are refused; the operator archives the file and
         * starts a new chain. */
        {
            const char *mx = getenv("FRACTALSQL_LEDGER_MAX_BYTES");
            long long cap = 1073741824LL;
            if (mx != NULL && mx[0] != '\0')
            {
                char *endp = NULL;
                long long v = strtoll(mx, &endp, 10);
                if (endp != NULL && *endp == '\0' && v >= 0) cap = v;
            }
            if (cap > 0 && sz >= 0 && (long long) sz >= cap)
            {
                fclose(fp); ledger_log_exit("ledger full (FRACTALSQL_LEDGER_MAX_BYTES)");
                ent_unlock(); return FSQL_ESTORAGE;
            }
        }
        /* Seek back to the start: the header check below reads the
         * magic at the CURRENT position, and fopen left it at 0.
         * Measuring the size moved it to the end, where the magic
         * read finds the file's tail -- so every write to an existing
         * ledger was refused as a "bad ledger header", and the ledger
         * stopped accepting records entirely. */
        if (fseek(fp, 0, SEEK_SET) != 0)
        {
            fclose(fp); ledger_log_exit("seek ledger"); ent_unlock(); return FSQL_ESTORAGE;
        }
    }

    if (is_new)
    {
        if (!ledger_write_header(fp))
            { fclose(fp); ledger_log_exit("write ledger header"); ent_unlock(); return FSQL_ESTORAGE; }
        /* C11 7.21.5.3: on an update-mode stream ("w+b"), a write must
         * be followed by an fflush or a reposition before any read.
         * The scan below reads right after this header write; without
         * the flush the Windows CRT has been observed to write out the
         * stream's whole 4096-byte buffer (header plus zero filler),
         * which the scan then parses as a tail of zero-length records
         * -- a corrupted ledger from the very first append. */
        if (fflush(fp) != 0)
            { fclose(fp); ledger_log_exit("write ledger header"); ent_unlock(); return FSQL_ESTORAGE; }
    }
    else
    {
        char magic[LEDGER_MAGIC_LEN];
        if (fread(magic, 1, LEDGER_MAGIC_LEN, fp) != LEDGER_MAGIC_LEN ||
            memcmp(magic, LEDGER_MAGIC, LEDGER_MAGIC_LEN) != 0 ||
            fgetc(fp) != LEDGER_VERSION)
        {
            fclose(fp); ledger_log_exit("bad ledger header"); ent_unlock(); return FSQL_ESTORAGE;
        }
    }

    ledger_record_t latest, prior;
    bool have_latest = false, have_prior = false;
    long long chain_records = 0;   /* the chain's own record count */
    long long kind_records = 0;    /* the chain's row count for THIS kind */
    if (ledger_scan_latest_two(fp, (uint32_t) kind, &latest, &have_latest,
                               &prior, &have_prior, &chain_records,
                               &kind_records) < 0)
    {
        /* The scan failed: most likely a torn tail from a crash or
         * power loss mid-append. Repair (truncate the partial final
         * record) and rescan once; without this, a single torn append
         * bricks the file for every future write. */
        fclose(fp);
        if (!ledger_repair_torn_tail())
            { ledger_log_exit("torn-tail repair"); ent_unlock(); return FSQL_ESTORAGE; }
        fp = ledger_open_private(ledger_path(), O_RDWR, "r+b", 0);
        if (fp == NULL)
            { ledger_log_exit("reopen after repair"); ent_unlock(); return FSQL_ESTORAGE; }
        /* Re-position past the file header: a fresh fopen starts at
         * offset 0, and the scan below would otherwise parse the magic
         * bytes as a record header whose blob length is garbage
         * (e.g. "LDGR" as a uint32), failing every repair for a reason
         * that has nothing to do with the repair itself. The initial
         * scan above skips these 9 bytes via the write/validate branch;
         * the rescan must skip them the same way. */
        {
            char magic[LEDGER_MAGIC_LEN];
            if (fread(magic, 1, LEDGER_MAGIC_LEN, fp) != LEDGER_MAGIC_LEN ||
                memcmp(magic, LEDGER_MAGIC, LEDGER_MAGIC_LEN) != 0 ||
                fgetc(fp) != LEDGER_VERSION)
            {
                fclose(fp); ledger_log_exit("rescan after repair"); ent_unlock(); return FSQL_ESTORAGE;
            }
        }
        if (ledger_scan_latest_two(fp, (uint32_t) kind, &latest, &have_latest,
                                   &prior, &have_prior, &chain_records,
                                   &kind_records) < 0)
        {
            fclose(fp); ledger_log_exit("rescan after repair"); ent_unlock(); return FSQL_ESTORAGE;
        }
    }
    if (have_prior) free(prior.blob);

    uint8_t prev_hash[LEDGER_HASH_LEN];
    memset(prev_hash, 0, LEDGER_HASH_LEN);
    if (have_latest)
    {
        memcpy(prev_hash, latest.entry_hash, LEDGER_HASH_LEN);
        free(latest.blob);
    }

    const char *key = ledger_key();
    uint8_t     mac_tag[LEDGER_HASH_LEN];
    bool        have_mac = false;
    if (key != NULL)
    {
        fsql_hmac_sha256((const uint8_t *) key, strlen(key),
                         (const uint8_t *) payload, len, mac_tag);
        have_mac = true;
    }

    uint8_t entry_hash[LEDGER_HASH_LEN];
    {
        size_t   buflen = LEDGER_HASH_LEN + len + (have_mac ? LEDGER_HASH_LEN : 0);
        uint8_t *buf    = (uint8_t *) malloc(buflen);
        if (buf == NULL) { fclose(fp); ledger_log_exit("out of memory"); ent_unlock(); return FSQL_ESTORAGE; }
        memcpy(buf, prev_hash, LEDGER_HASH_LEN);
        memcpy(buf + LEDGER_HASH_LEN, payload, len);
        if (have_mac) memcpy(buf + LEDGER_HASH_LEN + len, mac_tag, LEDGER_HASH_LEN);
        fsql_sha256(buf, buflen, entry_hash);
        free(buf);
    }

    /* Reopen in append mode for the record write: every write lands at
     * EOF regardless of where any other process's own appends have
     * moved the end. The seek-then-write this replaces is not O_APPEND
     * -- two daemon processes pointed at the same ledger path would
     * silently overwrite each other's records mid-chain. (The
     * process-internal writers are already serialized by the lock held
     * across this whole function.) */
    fclose(fp);
    fp = ledger_open_private(ledger_path(), O_WRONLY | O_APPEND, "ab", 1);
    if (fp == NULL) { ledger_log_exit("open ledger for append"); ent_unlock(); return FSQL_ESTORAGE; }

    uint32_t kind32     = (uint32_t) kind;
    uint32_t blen32      = (uint32_t) len;
    uint8_t  has_mac_b  = have_mac ? 1 : 0;
    uint8_t  sealed_b   = 0;    /* never sealed today */
    uint8_t  reserved[2] = { 0, 0 };
    uint8_t  mac_field[LEDGER_HASH_LEN];
    memset(mac_field, 0, LEDGER_HASH_LEN);
    if (have_mac) memcpy(mac_field, mac_tag, LEDGER_HASH_LEN);
    int64_t  updated = (int64_t) time(NULL);

    bool ok = true;
    ok = ok && fwrite(&kind32, sizeof kind32, 1, fp) == 1;
    ok = ok && fwrite(&blen32, sizeof blen32, 1, fp) == 1;
    ok = ok && fwrite(&has_mac_b, 1, 1, fp) == 1;
    ok = ok && fwrite(&sealed_b, 1, 1, fp) == 1;
    ok = ok && fwrite(reserved, 1, 2, fp) == 2;
    ok = ok && fwrite(mac_field, 1, LEDGER_HASH_LEN, fp) == LEDGER_HASH_LEN;
    ok = ok && fwrite(prev_hash, 1, LEDGER_HASH_LEN, fp) == LEDGER_HASH_LEN;
    ok = ok && fwrite(entry_hash, 1, LEDGER_HASH_LEN, fp) == LEDGER_HASH_LEN;
    ok = ok && fwrite(&updated, sizeof updated, 1, fp) == 1;
    if (ok && len > 0) ok = fwrite(payload, 1, len, fp) == len;
    if (!ok) ledger_log_exit("record fwrite");

    /* Check the flush: on ENOSPC, an unchecked fflush would report a
     * successful append for bytes that never reached the file (and the
     * CSV mirror below would record a row the binary chain lacks). */
    if (ok) ok = (fflush(fp) == 0);
    if (!ok) ledger_log_exit("fflush");
#if defined(_WIN32) || defined(__CYGWIN__)
    if (ok) ok = (_commit(_fileno(fp)) == 0);
    if (!ok) ledger_log_exit("_commit");
#else
    if (ok) ok = (fsync(fileno(fp)) == 0);
    if (!ok) ledger_log_exit("fsync");
#endif
    fclose(fp);

    if (ok)
    {
        ledger_csv_append(kind32, payload, len, have_mac, mac_field,
                          prev_hash, entry_hash, updated, chain_records);
        /* One more row appended to THIS kind. (kind_records counts this
         * kind alone, so the record just written is number
         * kind_records+1 -- which is what the head file now records and
         * what the anchor log publishes.) */
        long long head_rows = ledger_head_update(kind, kind_records);
        if (head_rows < 0) head_rows = kind_records + 1;
        ledger_anchor_publish(kind, head_rows, entry_hash);
    }

    ent_unlock();
    return ok ? FSQL_OK : FSQL_ESTORAGE;
}

/* read_entry: the storage VFS contract hands back a buffer "the
 * implementation owns; the engine never frees". MariaDB has no automatic
 * memory reclamation for this, so this keeps one outstanding buffer
 * alive per calling thread (freed at the START of that thread's next
 * read_entry call for the SAME kind) rather than leaking one buffer
 * per call -- a bounded, per-thread cache, not a real free, matching
 * the contract's letter (the engine itself never has to free it).
 * Per-thread, not process-global: the consumer decodes the buffer
 * AFTER this function returns and after the lock is dropped, so a
 * shared slot would let a second connection's read free the first
 * connection's buffer mid-decode (heap corruption in the daemon
 * process).
 *
 * One slot PER KIND, not one slot for the thread: the engine loads the
 * ledgers by reading each kind and decoding what it read, and a ledger
 * load touches more than one kind (the truth chain and the shadow
 * chain). With a single slot, reading the second kind freed the first
 * kind's buffer -- and the decode of the first kind then read freed
 * memory. A per-kind slot keeps every kind's buffer alive until that
 * same kind is read again. */
#define LEDGER_READ_SLOTS (LEDGER_MAX_KIND + 1)   /* indexed by kind */
#if defined(_WIN32) || defined(__CYGWIN__)
static __declspec(thread) uint8_t *t_last_read_blob[LEDGER_READ_SLOTS];
#else
static __thread uint8_t *t_last_read_blob[LEDGER_READ_SLOTS];
#endif

static int
ledger_read_entry(fsql_storage_user_ctx user, int kind,
                  const void **payload_out, size_t *len_out)
{
    (void) user;
    *payload_out = NULL;
    *len_out     = 0;

    /* A kind outside the ledger's range has no slot and no chain: the
     * write path refuses it for the same reason, so refusing it here
     * keeps the two ends of the ledger in step. */
    if (kind < 1 || kind > LEDGER_MAX_KIND)
        return FSQL_ESTORAGE;

    ent_lock();

    bool  bad_header = false;
    FILE *fp = ledger_open_for_read(&bad_header);
    if (fp == NULL)
    {
        ent_unlock();
        return bad_header ? FSQL_ESTORAGE : FSQL_ESTORAGE_UNAVAILABLE;
    }

    ledger_record_t latest, prior;
    bool have_latest = false, have_prior = false;
    int  rc = ledger_scan_latest_two(fp, (uint32_t) kind, &latest, &have_latest,
                                     &prior, &have_prior, NULL, NULL);
    fclose(fp);

    if (rc < 0) { ent_unlock(); return FSQL_ESTORAGE; }
    if (have_prior) free(prior.blob);
    if (!have_latest) { ent_unlock(); return FSQL_ESTORAGE_UNAVAILABLE; }

    {
        /* The slot is this kind's: the buffer the previous read of THIS
         * kind handed out is the one that can be released. The kind is
         * bounds-checked above, so the index is always in range, and
         * each kind keeps its own slot so reading one kind never frees
         * another kind's buffer. */
        int slot = kind;
        free(t_last_read_blob[slot]);
        t_last_read_blob[slot] = latest.blob;   /* ownership moves to this thread's slot */

        *payload_out = t_last_read_blob[slot];
    }
    *len_out     = latest.blob_len;
    ent_unlock();
    return FSQL_OK;
}

/* Release this thread's per-kind read buffers.
 *
 * The buffer handed to the core is owned by this thread's slot: the
 * core decodes it AFTER the callback returns, and the engine never
 * frees it, so the slot can only be released once the thread is done
 * with the buffer. Normally that is the next read of the SAME kind,
 * which frees the previous one -- but a thread that reads a kind once
 * and then ends never reaches that read.
 *
 * The daemon runs ONE THREAD PER CONNECTION, so without an explicit
 * release when the connection's thread ends, every connection that
 * read a ledger kind stranded its buffer for the life of the process:
 * an unbounded growth that tracks the number of connections ever
 * served, not the number alive at once.
 *
 * Called by the daemon when a connection's thread is done. */
void
fractal_enterprise_release_thread_read_buffers(void)
{
    int i;
    for (i = 0; i < LEDGER_READ_SLOTS; i++)
    {
        free(t_last_read_blob[i]);
        t_last_read_blob[i] = NULL;
    }
}

static int
ledger_seal_ledger(fsql_storage_user_ctx user)
{
    /* No-op: each flush is an immediate append, nothing pending to seal. */
    (void) user;
    return FSQL_OK;
}

static const fsql_storage_vfs_t g_ledger_vfs = {
    NULL,                /* user_ctx -- callbacks are process-global (file path from env) */
    ledger_write_entry,
    ledger_read_entry,
    ledger_seal_ledger
};

const fsql_storage_vfs_t *
fractal_ledger_storage_vfs(void)
{
    return &g_ledger_vfs;
}

bool
fractal_enterprise_lib_loaded(void)
{
    /* Under the lock: g_ent_loaded is written by ensure_enterprise_lib
     * under it, and reading it without it is a data race (MariaDB is
     * one shared multithreaded process, so two connections can be in
     * this function at once while a third loads the library). The
     * answer is a plain bool, so the only thing the lock buys is that
     * the read is ordered against the write -- and the lock is
     * uncontended after the first load. */
    ent_lock();
    bool loaded = g_ent_loaded;
    ent_unlock();
    return loaded;
}

int
fractal_ledger_write_kind2(const char *json, size_t len)
{
    /* Redaction happens HERE, at the one place every audit record
     * passes through: the audit UDF, the SQL agents' own audit calls
     * and the portfolio optimizers' audit records all write through
     * this function, so a single choke point covers all of them and
     * nothing is redacted twice. The values handed back to the caller
     * are the caller's own buffer and are never touched -- only the
     * copy that is persisted changes. */
    if (json != NULL && fsql_audit_redact_mode() != FSQL_AUDIT_REDACT_NONE)
    {
        char *copy = (char *) malloc(len + 1);
        if (copy != NULL)
        {
            memcpy(copy, json, len);
            copy[len] = '\0';
            char *redacted = fsql_audit_redact_json(copy);
            free(copy);
            if (redacted != NULL)
            {
                int rc = ledger_write_entry(NULL, 2, redacted, strlen(redacted));
                free(redacted);
                return rc;
            }
            /* A payload the redactor cannot walk (it is not valid JSON)
             * is stored as it is: the record is worth more than the
             * redaction, and the chain's own validation decides whether
             * such a record is acceptable. */
        }
    }
    return ledger_write_entry(NULL, 2, json, len);
}

void
fractal_ledger_sha256(const unsigned char *msg, size_t msglen, unsigned char out[32])
{
    fsql_sha256((const uint8_t *) msg, msglen, (uint8_t *) out);
}

/* O(1) load-time check (storage seam): before the enterprise core
 * decodes the persisted blob, verify only the LATEST record for `kind`:
 * its entry_hash recomputes correctly from its own blob/mac (structural
 * integrity, unconditional, no key required), its prev_hash matches the
 * entry_hash of the record immediately before it (or the genesis
 * sentinel, if it's the only one), and its MAC verifies if a ledger key
 * is configured. Deliberately O(1), not a full chain walk -- that's
 * fractal_ledger_verify()'s job, on demand. No record yet => empty
 * start, FSQL_OK (the core's own load then reports
 * FSQL_ESTORAGE_UNAVAILABLE, which fractal_ledger_load below treats as
 * OK). */
static int
ledger_verify_latest_file(uint32_t kind)
{
    /* Readers hold the same lock writers do: scanning a file that a
     * concurrent append is mid-way through would misread the in-flight
     * final record as a truncated blob and report a false integrity
     * failure for a perfectly healthy ledger. */
    ent_lock();

    bool  bad_header = false;
    FILE *fp = ledger_open_for_read(&bad_header);
    if (fp == NULL) { ent_unlock(); return bad_header ? FSQL_ESTORAGE_INTEGRITY : FSQL_OK; }

    ledger_record_t latest, prior;
    bool have_latest = false, have_prior = false;
    int  rc = ledger_scan_latest_two(fp, kind, &latest, &have_latest, &prior, &have_prior, NULL, NULL);
    fclose(fp);
    if (rc < 0) { ent_unlock(); return FSQL_ESTORAGE_INTEGRITY; }
    if (!have_latest) { if (have_prior) { free(prior.blob); } ent_unlock(); return FSQL_OK; }

    const char *key         = ledger_key();
    bool        require_mac = (key != NULL);
    int         result      = FSQL_OK;

    if (require_mac && !latest.has_mac)
    {
        result = FSQL_ESTORAGE_INTEGRITY;
    }
    else
    {
        if (require_mac)
        {
            uint8_t tag[LEDGER_HASH_LEN];
            fsql_hmac_sha256((const uint8_t *) key, strlen(key),
                             latest.blob, latest.blob_len, tag);
            if (CRYPTO_memcmp(tag, latest.mac, LEDGER_HASH_LEN) != 0)
                result = FSQL_ESTORAGE_INTEGRITY;
        }

        if (result == FSQL_OK)
        {
            uint8_t  recomputed[LEDGER_HASH_LEN];
            /* Sized in size_t arithmetic, deliberately: with an int
             * literal and a uint32_t length the sum is computed in
             * 32-bit UNSIGNED arithmetic and wraps (see
             * LEDGER_MAX_BLOB_BYTES). The length itself is already
             * bounded by the scan that produced this record. */
            size_t   buflen = (size_t) LEDGER_HASH_LEN + (size_t) latest.blob_len
                            + (latest.has_mac ? (size_t) LEDGER_HASH_LEN : (size_t) 0);
            uint8_t *buf    = (uint8_t *) malloc(buflen);
            if (buf == NULL)
            {
                result = FSQL_ESTORAGE;
            }
            else
            {
                memcpy(buf, latest.prev_hash, LEDGER_HASH_LEN);
                if (latest.blob_len > 0) memcpy(buf + LEDGER_HASH_LEN, latest.blob, latest.blob_len);
                if (latest.has_mac) memcpy(buf + LEDGER_HASH_LEN + latest.blob_len, latest.mac, LEDGER_HASH_LEN);
                fsql_sha256(buf, buflen, recomputed);
                free(buf);
                if (memcmp(recomputed, latest.entry_hash, LEDGER_HASH_LEN) != 0)
                    result = FSQL_ESTORAGE_INTEGRITY;
            }
        }

        if (result == FSQL_OK)
        {
            if (have_prior)
            {
                if (memcmp(latest.prev_hash, prior.entry_hash, LEDGER_HASH_LEN) != 0)
                    result = FSQL_ESTORAGE_INTEGRITY;
            }
            else
            {
                uint8_t zero[LEDGER_HASH_LEN];
                memset(zero, 0, LEDGER_HASH_LEN);
                if (memcmp(latest.prev_hash, zero, LEDGER_HASH_LEN) != 0)
                    result = FSQL_ESTORAGE_INTEGRITY;
            }
        }
    }

    free(latest.blob);
    if (have_prior) free(prior.blob);
    ent_unlock();
    return result;
}

/* ------------------------------------------------------------------ */
/* fractal_ledger_flush/_compact/_reset_soft/_reset_hard                */
/*   (session_id) -> INT (0)                                           */
/* ------------------------------------------------------------------ */
#define ENT_LEDGER_VOID_UDF(name, fnptr, post_ok)                                              \
FRACTAL_EXPORT bool                                                                    \
name##_init(UDF_INIT *initid, UDF_ARGS *args, char *message)                           \
{                                                                                       \
    if (args->arg_count != 1) {                                                        \
        SFS_INIT_ERROR(message, #name "(session_id): expected 1 argument, got %u",     \
                       args->arg_count);                                               \
        return true;                                                                   \
    }                                                                                   \
    args->arg_type[0] = INT_RESULT;                                                    \
    initid->maybe_null = 1;                                                            \
    return false;                                                                       \
}                                                                                        \
FRACTAL_EXPORT void name##_deinit(UDF_INIT *initid) { (void) initid; }                 \
FRACTAL_EXPORT long long                                                                \
name(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)                     \
{                                                                                        \
    (void) initid;                                                                      \
    if (args->args[0] == NULL) { *is_null = 1; return 0; }                             \
    /* Latched by fractal_lock_destructive(session_id): refuse before the */           \
    /* enterprise core is even resolved, so Community and Enterprise      */           \
    /* builds refuse identically.                                          */          \
    if (fractal_session_destructive_locked(                                            \
            (unsigned long long) *(long long *) args->args[0])) { *error = 1; return 0; } \
    if (!ensure_enterprise_lib()) { *error = 1; return 0; }                            \
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];        \
    fsql_ctx *ctx = fractal_session_acquire(sid);                                      \
    if (ctx == NULL) { *error = 1; return 0; }                                         \
    int rc = fnptr(ctx);                                                                \
    fractal_session_release(sid);                                                      \
    if (rc != FSQL_OK) { *error = 1; return 0; }                                       \
    post_ok;                                                                            \
    *is_null = 0;                                                                       \
    return 0;                                                                           \
}

ENT_LEDGER_VOID_UDF(fractal_ledger_flush,      g_ent_ledger_flush,      (void) 0)
ENT_LEDGER_VOID_UDF(fractal_ledger_compact,    g_ent_ledger_compact,    (void) 0)
ENT_LEDGER_VOID_UDF(fractal_ledger_reset_soft, g_ent_ledger_reset_soft, ledger_head_clear())
ENT_LEDGER_VOID_UDF(fractal_ledger_reset_hard, g_ent_ledger_reset_hard, ledger_head_clear())

/* fractal_lock_destructive(session_id) -> INT (1). One-way: latches the
 * destructive ledger UDFs (flush / compact / reset_soft / reset_hard) for that
 * session id for the life of the process; there is no unlock. The MCP server
 * calls it with its own connection id when FSQL_MCP_READ_ONLY=true. It works
 * with no enterprise core loaded. The latch is keyed by the session id the
 * caller passes, so it does not stop a caller that passes a DIFFERENT id. */
FRACTAL_EXPORT bool
fractal_lock_destructive_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message, "fractal_lock_destructive(session_id): expected 1 argument, got %u",
                       args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_lock_destructive_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_lock_destructive(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid; (void) error;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    fractal_session_lock_destructive((unsigned long long) *(long long *) args->args[0]);
    *is_null = 0;
    return 1;
}

/* fractal_ledger_load(session_id) -> INT (0). Written by hand (not via
 * ENT_LEDGER_VOID_UDF above) so it can run ledger_verify_latest_file()'s
 * O(1) tip check before g_ent_ledger_load. FSQL_ESTORAGE_UNAVAILABLE
 * from the core's own load (no persisted ledger yet) is not an error,
 * the ledger just starts empty. */
FRACTAL_EXPORT bool
fractal_ledger_load_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message, "fractal_ledger_load(session_id): expected 1 argument, got %u",
                       args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}
FRACTAL_EXPORT void fractal_ledger_load_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_ledger_load(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    /* Overwrites the live in-memory ledger state, so it honours the same
     * destructive latch as flush/compact/reset (a latched session must not
     * be able to roll the ledger back). */
    if (fractal_session_destructive_locked(
            (unsigned long long) *(long long *) args->args[0])) { *error = 1; return 0; }
    if (!ensure_enterprise_lib()) { *error = 1; return 0; }

    if (ledger_verify_latest_file(1) != FSQL_OK) { *error = 1; return 0; }

    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0; }
    int rc = g_ent_ledger_load(ctx);
    fractal_session_release(sid);
    if (rc != FSQL_OK && rc != FSQL_ESTORAGE_UNAVAILABLE) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* fractal_ledger_truth_count / _shadow_count(session_id) -> BIGINT    */
/* ------------------------------------------------------------------ */
#define ENT_LEDGER_COUNT_UDF(name, fnptr)                                              \
FRACTAL_EXPORT bool                                                                     \
name##_init(UDF_INIT *initid, UDF_ARGS *args, char *message)                            \
{                                                                                        \
    if (args->arg_count != 1) {                                                         \
        SFS_INIT_ERROR(message, #name "(session_id): expected 1 argument, got %u",      \
                       args->arg_count);                                                \
        return true;                                                                    \
    }                                                                                    \
    args->arg_type[0] = INT_RESULT;                                                     \
    initid->maybe_null = 1;                                                             \
    return false;                                                                        \
}                                                                                         \
FRACTAL_EXPORT void name##_deinit(UDF_INIT *initid) { (void) initid; }                  \
FRACTAL_EXPORT long long                                                                 \
name(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)                      \
{                                                                                         \
    (void) initid;                                                                       \
    if (args->args[0] == NULL) { *is_null = 1; return 0; }                              \
    if (!ensure_enterprise_lib()) { *error = 1; return 0; }                             \
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];         \
    fsql_ctx *ctx = fractal_session_acquire(sid);                                       \
    if (ctx == NULL) { *error = 1; return 0; }                                          \
    size_t n = 0;                                                                        \
    int rc = fnptr(ctx, &n);                                                             \
    fractal_session_release(sid);                                                       \
    if (rc != FSQL_OK) { *error = 1; return 0; }                                        \
    *is_null = 0;                                                                        \
    return (long long) n;                                                                \
}

ENT_LEDGER_COUNT_UDF(fractal_ledger_truth_count,  g_ent_ledger_truth_count)
ENT_LEDGER_COUNT_UDF(fractal_ledger_shadow_count, g_ent_ledger_shadow_count)

/* ------------------------------------------------------------------ */
/* fractal_ledger_verify(session_id [, kind]) -> TEXT (JSON)           */
/*                                                                      */
/* Full O(n) walk of the append-only ledger file for `kind` (default    */
/* 1, the QTL Truth/Shadow chain): recomputes every entry_hash/prev_hash */
/* link (and MAC, if a ledger key is configured) and returns a JSON     */
/* report, {"ok":true,"rows_verified":N} or                             */
/* {"ok":false,"first_failure_id":N,"reason":"..."}, rather than         */
/* raising, since this is a forensic query, not a gate. Pure storage-    */
/* layer check: does NOT require the enterprise library to be loaded.   */
/* session_id is accepted only for signature symmetry with the other    */
/* fractal_ledger_* UDFs (MariaDB UDF overloading by arg count needs    */
/* every arg position to exist across all arities the main function     */
/* branches on); the ledger file itself is process-global, not          */
/* per-session, so it's otherwise unused.                                */
/* ------------------------------------------------------------------ */
FRACTAL_EXPORT bool
fractal_ledger_verify_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count < 1 || args->arg_count > 2) {
        SFS_INIT_ERROR(message,
                       "fractal_ledger_verify(session_id [, kind]): expected 1 or 2 arguments, got %u",
                       args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    if (args->arg_count == 2) args->arg_type[1] = INT_RESULT;
    initid->maybe_null = 0;
    initid->max_length = 512;
    initid->ptr         = NULL;
    return false;
}

FRACTAL_EXPORT void
fractal_ledger_verify_deinit(UDF_INIT *initid)
{
    free(initid->ptr);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_ledger_verify(UDF_INIT *initid, UDF_ARGS *args, char *result,
                      unsigned long *length, char *is_null, char *error)
{
    (void) result;
    free(initid->ptr);
    initid->ptr = NULL;

    uint32_t kind = 1;
    if (args->arg_count == 2 && args->args[1] != NULL)
        kind = (uint32_t) *(long long *) args->args[1];

    /* Same reader-vs-writer serialization as ledger_verify_latest_file:
     * an unlocked scan of a file mid-append reports false integrity
     * failures. */
    ent_lock();

    bool  bad_header = false;
    FILE *fp = ledger_open_for_read(&bad_header);
    char *out;

    if (fp == NULL && !bad_header)
    {
        const long long recorded = ledger_head_get(kind);
        ent_unlock();
        if (recorded > 0)
            out = strdup("{\"ok\":false,\"first_failure_id\":0,\"reason\":\"ledger file is missing but rows were recorded (wiped or replaced)\"}");
        else
            out = strdup("{\"ok\":true,\"rows_verified\":0}");
    }
    else if (fp == NULL)   /* bad_header */
    {
        ent_unlock();
        out = strdup("{\"ok\":false,\"first_failure_id\":0,\"reason\":\"bad ledger file header\"}");
    }
    else
    {
        const char *key         = ledger_key();
        bool        require_mac = (key != NULL);
        uint8_t     prev_expected[LEDGER_HASH_LEN];
        memset(prev_expected, 0, LEDGER_HASH_LEN);
        long long   n = 0, fail_id = 0;
        /* The record number in the FILE, counting every kind. `n` counts
         * only the records of the kind being verified, so with a file
         * that carries several kinds the two diverge -- and the id an
         * operator is given has to be the one they can find in the
         * file. */
        long long   rec = 0;
        const char *reason = NULL;

        for (;;)
        {
            uint32_t rkind, blen;
            uint8_t  has_mac, sealed, mac[LEDGER_HASH_LEN], prev[LEDGER_HASH_LEN], hash[LEDGER_HASH_LEN];
            int64_t  updated;
            int      hr = ledger_read_record_header(fp, &rkind, &blen, &has_mac, &sealed,
                                                    mac, prev, hash, &updated);
            if (hr == 0) break;
            if (hr < 0) { reason = "truncated or corrupt record"; fail_id = rec + 1; break; }
            rec++;

            uint8_t *blob = NULL;
            if (blen > 0)
            {
                /* The claimed length is checked before it sizes the
                 * allocation: an unchecked length from the file is a
                 * heap overflow in the hash recomputation below, not
                 * just a big allocation (see LEDGER_MAX_BLOB_BYTES). */
                if (blen > LEDGER_MAX_BLOB_BYTES)
                {
                    reason = "record blob length out of range";
                    fail_id = rec;
                    break;
                }
                blob = (uint8_t *) malloc(blen);
                if (blob == NULL || fread(blob, 1, blen, fp) != blen)
                {
                    free(blob);
                    reason = "truncated blob";
                    fail_id = rec;
                    break;
                }
            }
            if (rkind != kind) { free(blob); continue; }

            n++;
            bool ok = true;
            if (require_mac && !has_mac) { ok = false; reason = "row has no MAC but a ledger key is configured"; }
            if (ok && has_mac && require_mac)
            {
                uint8_t tag[LEDGER_HASH_LEN];
                fsql_hmac_sha256((const uint8_t *) key, strlen(key), blob, blen, tag);
                if (CRYPTO_memcmp(tag, mac, LEDGER_HASH_LEN) != 0) { ok = false; reason = "HMAC mismatch"; }
            }
            if (ok)
            {
                uint8_t  recomputed[LEDGER_HASH_LEN];
                /* size_t arithmetic on purpose: an int literal plus a
                 * uint32_t length computes in 32-bit unsigned
                 * arithmetic and wraps (see LEDGER_MAX_BLOB_BYTES). */
                size_t   buflen = (size_t) LEDGER_HASH_LEN + (size_t) blen
                                + (has_mac ? (size_t) LEDGER_HASH_LEN : (size_t) 0);
                uint8_t *buf    = (uint8_t *) malloc(buflen);
                if (buf == NULL) { ok = false; reason = "out of memory"; }
                else
                {
                    memcpy(buf, prev, LEDGER_HASH_LEN);
                    if (blen > 0) memcpy(buf + LEDGER_HASH_LEN, blob, blen);
                    if (has_mac) memcpy(buf + LEDGER_HASH_LEN + blen, mac, LEDGER_HASH_LEN);
                    fsql_sha256(buf, buflen, recomputed);
                    free(buf);
                    if (memcmp(recomputed, hash, LEDGER_HASH_LEN) != 0)
                        { ok = false; reason = "entry_hash mismatch (structural tamper)"; }
                }
            }
            if (ok && memcmp(prev, prev_expected, LEDGER_HASH_LEN) != 0)
                { ok = false; reason = "chain-link break (prev_hash does not match predecessor -- row rewritten, reordered, or deleted)"; }

            free(blob);
            if (!ok) { fail_id = rec; break; }
            memcpy(prev_expected, hash, LEDGER_HASH_LEN);
        }
        fclose(fp);
        const long long recorded = ledger_head_get(kind);
        /* The head file is the counter that lives OUTSIDE the chain, so
         * it is the only thing that can tell a truncated chain from a
         * short one. Its own MAC says the same thing about the counter:
         * a head record edited by hand does not match its MAC. */
        const char *head_reason = ledger_head_check((int) kind);
        ent_unlock();

        if (reason == NULL && head_reason != NULL)
        {
            reason  = head_reason;
            fail_id = 0;
        }
        /* Fewer rows than the chain has ever held: rows were removed or the file was replaced. */
        else if (reason == NULL && n < recorded)
        {
            reason  = "chain holds fewer rows than were recorded (rows removed, or the ledger was replaced)";
            fail_id = n + 1;
        }

        char *buf = (char *) malloc(320);
        if (buf == NULL) { *error = 1; *is_null = 1; return NULL; }
        if (reason != NULL)
            snprintf(buf, 320, "{\"ok\":false,\"first_failure_id\":%lld,\"reason\":\"%s\"}", fail_id, reason);
        else
            snprintf(buf, 320, "{\"ok\":true,\"rows_verified\":%lld}", n);
        out = buf;
    }

    if (out == NULL) { *error = 1; *is_null = 1; return NULL; }
    initid->ptr = out;
    *length  = (unsigned long) strlen(out);
    *is_null = 0;
    return out;
}

/* JSON string escaping (for the entry_type field): backslash and double
 * quote get escaped, control characters get \u00XX. Writes at most 6
 * bytes per input byte; returns the escaped length, or (size_t)-1 if
 * the buffer is too small. */
static size_t
ent_json_escape(const char *s, size_t len, char *out, size_t cap)
{
    size_t o = 0, i;
    for (i = 0; i < len; i++)
    {
        unsigned char c = (unsigned char) s[i];
        char tmp[8];
        size_t n;
        switch (c)
        {
        case '"':  tmp[0] = '\\'; tmp[1] = '"';  n = 2; break;
        case '\\': tmp[0] = '\\'; tmp[1] = '\\'; n = 2; break;
        case '\b': tmp[0] = '\\'; tmp[1] = 'b';  n = 2; break;
        case '\f': tmp[0] = '\\'; tmp[1] = 'f';  n = 2; break;
        case '\n': tmp[0] = '\\'; tmp[1] = 'n';  n = 2; break;
        case '\r': tmp[0] = '\\'; tmp[1] = 'r';  n = 2; break;
        case '\t': tmp[0] = '\\'; tmp[1] = 't';  n = 2; break;
        default:
            if (c < 0x20) { n = (size_t) snprintf(tmp, sizeof tmp, "\\u%04x", c); }
            else { tmp[0] = (char) c; n = 1; }
            break;
        }
        if (o + n > cap) return (size_t) -1;
        memcpy(out + o, tmp, n);
        o += n;
    }
    return o;
}

/* A portable substring search over a bounded buffer. memmem() is a GNU
 * extension that the MSVC CRT does not have, and the Windows build of the
 * daemon links against that CRT -- so the searches below go through this
 * one instead. Both sides are length-bounded here (the haystack is a UDF
 * argument with a ceiling, the needle is a short literal), so the scan is
 * linear and never reads past either end. */
static const char *
ent_memmem(const void *hay, size_t hay_len, const void *needle, size_t needle_len)
{
    const unsigned char *h = (const unsigned char *) hay;
    const unsigned char *n = (const unsigned char *) needle;
    size_t i;

    if (needle_len == 0) return (const char *) h;
    if (hay_len < needle_len) return NULL;
    for (i = 0; i + needle_len <= hay_len; i++) {
        if (h[i] == n[0] && memcmp(h + i, n, needle_len) == 0) return (const char *) (h + i);
    }
    return NULL;
}

/* Minimal structural JSON validation (for payload_json): enough to keep
 * malformed or deliberately spliced text out of the chain record -- one
 * well-bracketed JSON value over exactly the whole length, with no raw
 * control characters inside strings and no two values without a
 * separator. Not a full RFC 8259 parser: number shape is checked,
 * key/colon placement is not, duplicate keys are not rejected. */
static bool
ent_json_well_formed(const char *s, size_t len)
{
    char stack[64];
    unsigned char st[65];
    int  sp = 0;
    bool in_str = false, esc = false;
    bool seen_any = false;
    size_t i;

    /* Per-container state. ST_EMPTY: nothing in this container yet.
     * ST_VALUE: a value has been completed here. ST_SEP: a separator
     * was consumed and a value is expected next.
     *
     * WHY NOT ONE FLAG: the old single "after_value" flag could not
     * tell an EMPTY container from a container left dangling after a
     * separator. A closing bracket wants a completed value -- except
     * when the container is empty -- and the same flag served for both,
     * so "{}" and "[]" were rejected: fractal_audit_log(type,
     * JSON_OBJECT()) wrote nothing to the chain and returned a bare
     * NULL, and the file's own comment claimed JSON_OBJECT() output
     * "clears this easily". The state is per depth, so a nested
     * container's contents no longer overwrite its parent's. */
    enum { ST_EMPTY = 0, ST_VALUE = 1, ST_SEP = 2 };

    st[0] = ST_EMPTY;   /* the document itself is the outermost container */

    for (i = 0; i < len; i++)
    {
        char c = s[i];
        if (in_str)
        {
            if (esc) esc = false;
            else if (c == '\\') esc = true;
            else if (c == '"') in_str = false;
            else if ((unsigned char) c < 0x20) return false;
            continue;
        }
        if (c == '"')
        {
            if (st[sp] == ST_VALUE) return false;   /* two values, no separator */
            in_str = true;
            st[sp] = ST_VALUE;
            seen_any = true;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        if (c == '[' || c == '{')
        {
            if (st[sp] == ST_VALUE) return false;
            if (sp >= (int) sizeof stack) return false;
            stack[sp++] = c;
            st[sp] = ST_EMPTY;
            seen_any = true;
            continue;
        }
        if (c == ']' || c == '}')
        {
            if (sp == 0) return false;
            /* A separator wants a value: "[1,]" and {"a":1,} are not
             * JSON. An empty container is fine. */
            if (st[sp] == ST_SEP) return false;
            char open = stack[sp - 1];
            if ((c == ']' && open != '[') || (c == '}' && open != '{')) return false;
            sp--;
            st[sp] = ST_VALUE;   /* the closed container is a value in its parent */
            continue;
        }
        if (c == ',')
        {
            if (sp == 0 || st[sp] != ST_VALUE) return false;
            st[sp] = ST_SEP;
            continue;
        }
        if (c == ':')
        {
            /* A colon is a separator exactly where a comma is: after a
             * completed value, inside a container, always followed by
             * another value. Which strings were keys is not tracked
             * (see the block comment above) -- this checks separation,
             * not placement. Without this branch a colon fell through
             * to the generic "two values without a separator" rejection
             * below, because after_value is always still set from the
             * key string -- every valid object was rejected, so
             * fractal_audit_log(type, JSON_OBJECT(...)) refused every
             * payload and silently wrote nothing. */
            if (sp == 0 || st[sp] != ST_VALUE) return false;
            st[sp] = ST_SEP;
            continue;
        }
        if (st[sp] == ST_VALUE) return false;
        if (c == 't' || c == 'f' || c == 'n')
        {
            const char *lit;
            if (c == 't')      lit = "true";
            else if (c == 'f') lit = "false";
            else               lit = "null";
            size_t ll = strlen(lit);
            if (len - i < ll || memcmp(s + i, lit, ll) != 0) return false;
            i += ll - 1;
            st[sp] = ST_VALUE;
            seen_any = true;
            continue;
        }
        /* number: -? digits [. digits] [eE [+-] digits] */
        {
            size_t j = i;
            if (j < len && s[j] == '-') j++;
            size_t ds = j;
            while (j < len && s[j] >= '0' && s[j] <= '9') j++;
            if (j == ds) return false;
            if (j < len && s[j] == '.')
            {
                j++;
                size_t fd = j;
                while (j < len && s[j] >= '0' && s[j] <= '9') j++;
                if (j == fd) return false;
            }
            if (j < len && (s[j] == 'e' || s[j] == 'E'))
            {
                j++;
                if (j < len && (s[j] == '+' || s[j] == '-')) j++;
                size_t ed = j;
                while (j < len && s[j] >= '0' && s[j] <= '9') j++;
                if (j == ed) return false;
            }
            i = j - 1;
            st[sp] = ST_VALUE;
            seen_any = true;
        }
    }
    return seen_any && !in_str && sp == 0 && st[0] == ST_VALUE;
}

/* ------------------------------------------------------------------ */
/* fractal_audit_log(entry_type, payload_json) -> INT (0)               */
/*                                                                        */
/* Append a provenance record to the general decision-audit chain         */
/* (kind=2 in the ledger, a second, independent append-only chain         */
/* alongside kind=1's QTL Truth/Shadow blobs, same hash-chain              */
/* guarantees, verifiable via fractal_ledger_verify(session_id, 2) and     */
/* queryable via the CONNECT mirror at kind=2). Stores                     */
/* {"type": entry_type, "entry": payload_json}. Gated behind               */
/* ensure_enterprise_lib() even though the write itself goes through the   */
/* community-side storage layer, not the dlsym'd core library: this is     */
/* a deliberate product-tier gate, not a technical necessity. Dormant,     */
/* the UDF returns NULL like the rest of the ledger surface, so callers    */
/* may invoke it best-effort (stored procedures that log their own         */
/* decisions): on a Community deployment the call harmlessly writes        */
/* nothing and never breaks the caller. No session_id argument: unlike     */
/* flush/load/etc., this never touches a session's in-memory ctx.          */
/* entry_type is embedded as a properly escaped JSON string and           */
/* payload_json must parse as well-formed JSON (ent_json_well_formed       */
/* above): the chain authenticates bytes, not authors, and this UDF is    */
/* world-callable, so an unshaped free-text field would let any session   */
/* land spliced or malformed records indistinguishable from a built-in    */
/* flow's. ---------------------------------------------------------------- */
FRACTAL_EXPORT bool
fractal_audit_log_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count < 2 || args->arg_count > 4) {
        SFS_INIT_ERROR(message,
                       "fractal_audit_log(entry_type, payload_json[, session_id[, actor]]): expected 2 to 4 arguments, got %u",
                       args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    if (args->arg_count >= 3) args->arg_type[2] = INT_RESULT;
    if (args->arg_count >= 4) args->arg_type[3] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}
FRACTAL_EXPORT void fractal_audit_log_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_audit_log(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    if (!ensure_enterprise_lib()) { *is_null = 1; return 0; }

    const char *type_s   = args->args[0];
    size_t      type_len = args->lengths[0];
    const char *payload  = (args->args[1] != NULL) ? args->args[1] : "null";
    size_t      payload_len = (args->args[1] != NULL) ? args->lengths[1] : 4;

    /* The optional third argument is the caller's session id (the
     * engine procedures and the MCP tool pass CONNECTION_ID()). When given, the
     * destructive latch applies to this append exactly as it does to the ledger
     * mutators, and the optional fourth argument names the actor. A UDF cannot read
     * the authenticated user itself, so callers that want attribution supply it;
     * FRACTALSQL_AUDIT_REQUIRE_ACTOR=1 makes a bare two-argument call an error. */
    const bool have_sid   = args->arg_count >= 3 && args->args[2] != NULL;
    const bool have_actor = args->arg_count >= 4 && args->args[3] != NULL;
    long long  sid        = have_sid ? *(long long *) args->args[2] : 0;
    if (have_sid && fractal_session_destructive_locked((unsigned long long) sid)) { *error = 1; return 0; }
    if (!have_sid && ent_env_flag("FRACTALSQL_AUDIT_REQUIRE_ACTOR")) { *error = 1; return 0; }

    /* Shape-gate both fields before they reach the chain record (see
     * the comment block above). Built-in flows pass fixed short
     * literals and JSON_OBJECT() output, which both clear this easily;
     * a session trying to splice in forged fields now fails cleanly
     * here instead of landing in the chain. */
    if (type_len > 256) { *error = 1; return 0; }
    /* The payload is the one unbounded argument on this path, and it
     * becomes the record's blob. Two reasons to bound it here rather
     * than only in the writer: the "%.*s" below narrows the length to
     * an int (a length above INT_MAX would become a negative
     * precision, which C reads as "no precision" -- the format would
     * then run to the next NUL instead of stopping at the length it
     * was given), and a record this big is refused by the writer's own
     * ceiling anyway -- so the boundary belongs at the UDF, where the
     * caller gets a clean error instead of a late storage failure. */
    if (payload_len > LEDGER_MAX_BLOB_BYTES) { *error = 1; return 0; }
    if (!ent_json_well_formed(payload, payload_len)) { *error = 1; return 0; }
    /* "_actor" is reserved for the attribution block added below. */
    if (ent_memmem(payload, payload_len, "\"_actor\"", 8) != NULL) { *error = 1; return 0; }

    char   esc_stack[512];
    char  *esc = esc_stack;
    size_t esc_cap = type_len * 6 + 1;
    if (esc_cap > sizeof esc_stack) { esc = (char *) malloc(esc_cap); if (esc == NULL) { *error = 1; return 0; } }
    size_t esc_len = ent_json_escape(type_s, type_len, esc, esc_cap);
    if (esc_len == (size_t) -1) { if (esc != esc_stack) { free(esc); } *error = 1; return 0; }

    /* Attribution block: {"session":<id>,"attested":<bool>[,"actor":"..."]}. */
    char   actor_esc_stack[512];
    char  *actor_esc = actor_esc_stack;
    size_t actor_esc_len = 0;
    if (have_actor) {
        size_t al = args->lengths[3];
        if (al > 256) { if (esc != esc_stack) free(esc); *error = 1; return 0; }
        size_t acap = al * 6 + 1;
        if (acap > sizeof actor_esc_stack) {
            actor_esc = (char *) malloc(acap);
            if (actor_esc == NULL) { if (esc != esc_stack) free(esc); *error = 1; return 0; }
        }
        actor_esc_len = ent_json_escape(args->args[3], al, actor_esc, acap);
        if (actor_esc_len == (size_t) -1) {
            if (actor_esc != actor_esc_stack) free(actor_esc);
            if (esc != esc_stack) free(esc);
            *error = 1; return 0;
        }
    }
    char   actor_blk[1024];
    int    ab = snprintf(actor_blk, sizeof actor_blk, "{\"session\":%lld,\"attested\":%s%s%.*s%s}",
                         have_sid ? sid : 0LL, have_sid ? "true" : "false",
                         have_actor ? ",\"actor\":\"" : "", (int) actor_esc_len, have_actor ? actor_esc : "",
                         have_actor ? "\"" : "");
    if (actor_esc != actor_esc_stack) free(actor_esc);
    if (ab < 0 || (size_t) ab >= sizeof actor_blk) { if (esc != esc_stack) free(esc); *error = 1; return 0; }

    /* Splice the block into the entry value: before the closing brace of an object
     * payload, or by wrapping a scalar/array payload as {"value":...,"_actor":...}.
     * The chain document's outer {"type","entry"} shape is unchanged. */
    const char *pb = payload, *pe = payload + payload_len;
    while (pb < pe && (*pb == ' ' || *pb == '\t' || *pb == '\n' || *pb == '\r')) pb++;
    while (pe > pb && (pe[-1] == ' ' || pe[-1] == '\t' || pe[-1] == '\n' || pe[-1] == '\r')) pe--;
    const bool is_obj = (pb < pe && *pb == '{' && pe[-1] == '}');
    bool obj_empty = false;
    if (is_obj) {
        const char *q = pb + 1;
        while (q < pe - 1 && (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r')) q++;
        obj_empty = (q == pe - 1);
    }

    size_t buflen = esc_len + payload_len + (size_t) ab + 64;
    char  *buf = (char *) malloc(buflen);
    if (buf == NULL) { if (esc != esc_stack) { free(esc); } *error = 1; return 0; }

    int n;
    if (is_obj && !obj_empty)
        n = snprintf(buf, buflen, "{\"type\":\"%.*s\",\"entry\":%.*s,\"_actor\":%s}}",
                     (int) esc_len, esc, (int) ((pe - 1) - pb), pb, actor_blk);
    else if (is_obj)
        n = snprintf(buf, buflen, "{\"type\":\"%.*s\",\"entry\":{\"_actor\":%s}}",
                     (int) esc_len, esc, actor_blk);
    else
        n = snprintf(buf, buflen, "{\"type\":\"%.*s\",\"entry\":{\"value\":%.*s,\"_actor\":%s}}",
                     (int) esc_len, esc, (int) (pe - pb), pb, actor_blk);
    if (esc != esc_stack) free(esc);
    if (n < 0 || (size_t) n >= buflen) { free(buf); *error = 1; return 0; }

    int rc = fractal_ledger_write_kind2(buf, (size_t) n);
    free(buf);
    if (rc != FSQL_OK) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* fractal_audit_unpack(blob) -> TEXT (JSON)                           */
/* Pure decode. Touches neither the session ctx nor any storage. Grows  */
/* its output buffer on FSQL_ETRUNCATED and retries.                    */
/* ------------------------------------------------------------------ */
typedef struct { char *buf; size_t cap; } str_out_ctx;

FRACTAL_EXPORT bool
fractal_audit_unpack_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    str_out_ctx *so;
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message, "fractal_audit_unpack(blob): expected 1 argument, got %u",
                       args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    so = calloc(1, sizeof(*so));
    if (so == NULL) {
        SFS_INIT_ERROR(message, "fractal_audit_unpack: out of memory");
        return true;
    }
    initid->ptr        = (char *) so;
    initid->maybe_null = 1;
    initid->max_length = 16u * 1024u * 1024u;   /* 16 MiB, same ceiling as the reasoning-tier responses */
    return false;
}

FRACTAL_EXPORT void
fractal_audit_unpack_deinit(UDF_INIT *initid)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    if (so == NULL) return;
    free(so->buf);
    free(so);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_audit_unpack(UDF_INIT *initid, UDF_ARGS *args, char *result,
                     unsigned long *length, char *is_null, char *error)
{
    str_out_ctx *so = (str_out_ctx *) initid->ptr;
    size_t cap;
    int    rc;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (!ensure_enterprise_lib()) { *error = 1; return NULL; }

    /* Allocate one byte beyond the logical capacity so a NUL terminator
     * always has a home: the result is returned as a C string and the
     * core-reported length is untrusted (see the guard below). */
    cap = 8192;
    for (;;) {
        char  *nb;
        size_t need = cap;

        nb = realloc(so->buf, cap + 1);
        if (nb == NULL) { *error = 1; return NULL; }
        so->buf = nb; so->cap = cap;

        rc = g_ent_audit_unpack(args->args[0], args->lengths[0], so->buf, &need);
        if (rc == FSQL_OK) {
            /* Core-reported length is untrusted: refuse a "success"
             * that claims more space than the buffer holds rather than
             * letting strnlen() read past the allocation. */
            if (need > cap) { *error = 1; return NULL; }
            so->buf[need] = '\0';
            *length  = (unsigned long) strnlen(so->buf, need);
            *is_null = 0;
            return so->buf;
        }
        if (rc == FSQL_ETRUNCATED && need > cap) {
            /* The core's "need" is as untrusted as its "success" length:
             * taken verbatim it would size the next allocation, and
             * `cap + 1` in the realloc above could wrap to 0 for a
             * need near SIZE_MAX -- realloc(ptr, 0) FREES the buffer
             * and returns NULL, leaving so->buf NULL with a huge so->cap
             * for the next call to hand to the core. The growth is
             * clamped to the ceiling this UDF declared in its init
             * (16 MiB): a blob that needs more than the UDF's own
             * max_length cannot be returned anyway, so it is a clean
             * error rather than a giant allocation. */
            if (need > (16u * 1024u * 1024u)) { *error = 1; return NULL; }
            cap = need;
            continue;
        }
        *error = 1;
        return NULL;
    }
}

/* ------------------------------------------------------------------ */
/* fractal_optimize_portfolio_multimodal(mu_csv, cov_csv, k, n_restarts, */
/*   overlap_threshold, quality_frac, seed) -> TEXT (JSON)               */
/*                                                                        */
/* Enterprise-gated sibling of the Community fractal_optimize_portfolio: */
/* calls fsql_optimize_portfolio's search n_restarts times with          */
/* different derived seeds, then greedy diverse-selects the results by   */
/* asset-overlap and quality threshold (see fsql_optimize_portfolio_     */
/* multimodal's own doc comment in fractalsql_sql.h). Returns            */
/* {"n_found":N,"candidates":[{"sharpe":..,"weights":[..]},...]}, Sharpe */
/* descending, or a clean NULL when the enterprise library isn't loaded  */
/* or the symbol isn't present in it (see g_ent_portfolio_multimodal).   */
/*                                                                        */
/* All 7 arguments are positional and required: unlike the Community     */
/* UDF's trailing params JSON blob (bundling optional seed/use_obl/      */
/* diffusion_mode knobs), this file has no JSON-parsing helpers of its   */
/* own (fractalsql.c's json_get_* are private to that translation unit), */
/* so this mirrors fsql_optimize_portfolio_multimodal's own C parameter  */
/* list directly rather than duplicating a small JSON parser here.       */
/* ------------------------------------------------------------------ */

/* This file's own 256 MiB corpus-size ceiling, same value and rationale
 * as fractalsql.c's MAX_CORPUS_BYTES (private to that translation unit,
 * so duplicated here rather than shared, matching how SFS_INIT_ERROR is
 * already duplicated per-file in this codebase). */
#define ENT_MAX_CORPUS_BYTES ((unsigned long) 256u * 1024u * 1024u)

/* Minimal dynamic string builder, local to this one UDF's JSON output.
 * Grows geometrically via vsnprintf's own "how much would this have
 * needed" return value, no dependency on fractalsql.c's json_out_generic
 * (private to that translation unit). */
typedef struct { char *buf; size_t len; size_t cap; } ent_jsonbuf_t;

static bool
ent_jsonbuf_init(ent_jsonbuf_t *jb)
{
    jb->cap = 4096;
    jb->len = 0;
    jb->buf = (char *) malloc(jb->cap);
    if (jb->buf == NULL) return false;
    jb->buf[0] = '\0';
    return true;
}

static bool
ent_jsonbuf_append(ent_jsonbuf_t *jb, const char *fmt, ...)
{
    for (;;) {
        va_list ap;
        int     need;

        va_start(ap, fmt);
        need = vsnprintf(jb->buf + jb->len, jb->cap - jb->len, fmt, ap);
        va_end(ap);
        if (need < 0) return false;

        if ((size_t) need < jb->cap - jb->len) {
            jb->len += (size_t) need;
            return true;
        }

        size_t want = jb->len + (size_t) need + 1;
        size_t newcap = jb->cap ? jb->cap : 256;
        while (newcap < want)
        {
            /* The doubling must be able to terminate: past SIZE_MAX/2 a
             * further doubling wraps to 0, and "0 < want" stays true
             * for ever -- an infinite loop inside a statement, with the
             * connection held. Sizing straight to the requirement is
             * the honest answer: if even that cannot be allocated, the
             * realloc below says so. */
            if (newcap > SIZE_MAX / 2) { newcap = want; break; }
            newcap *= 2;
        }
        char *nb = (char *) realloc(jb->buf, newcap);
        if (nb == NULL) return false;
        jb->buf = nb;
        jb->cap = newcap;
    }
}

/* Best-effort audit-chain provenance (ledger kind=2) for a multimodal
 * portfolio decision, the enterprise-tier equivalent of fractalsql.c's
 * portfolio_audit_log_best_effort() for the Community fractal_optimize_
 * portfolio. inputs_hash covers mu+cov the same way, so the decision's
 * inputs are verifiable later without duplicating a potentially large
 * covariance matrix into the ledger. result_json is the exact JSON this
 * UDF is about to return to the caller (all n_found candidates), spliced
 * in as-is rather than rebuilt, so the audited record and the returned
 * result can never drift apart. Silent no-op when the enterprise library
 * isn't loaded or the write fails: audit logging must never break the
 * optimization call itself. */
static void
portfolio_multimodal_audit_log_best_effort(const double *mu, const double *cov,
                                           size_t n_assets, size_t k, int n_restarts,
                                           double overlap, double qfrac, long long seed,
                                           const char *result_json, size_t result_len)
{
    if (!fractal_enterprise_lib_loaded())
        return;

    unsigned char hash[32];
    {
        size_t mu_bytes  = n_assets * sizeof(double);
        size_t cov_bytes = n_assets * n_assets * sizeof(double);
        unsigned char *buf = (unsigned char *) malloc(mu_bytes + cov_bytes);
        if (buf == NULL) return;
        memcpy(buf, mu, mu_bytes);
        memcpy(buf + mu_bytes, cov, cov_bytes);
        fractal_ledger_sha256(buf, mu_bytes + cov_bytes, hash);
        free(buf);
    }
    char hash_hex[65];
    for (int i = 0; i < 32; i++)
        snprintf(hash_hex + i * 2, 3, "%02x", hash[i]);

    /* The record's head: everything up to the result document. 1024
     * bytes covers it -- the widest fields are the two "%.10g"
     * doubles and the 64-character hash. */
    char head[1024];
    int  hn = snprintf(head, sizeof head,
        "{\"type\":\"portfolio_optimize_multimodal\",\"entry\":{"
        "\"seed\":%lld,\"n_assets\":%zu,\"k\":%zu,\"n_restarts\":%d,"
        "\"overlap_threshold\":%.10g,\"quality_frac\":%.10g,"
        "\"inputs_hash\":\"%s\",\"result\":",
        seed, n_assets, k, n_restarts, overlap, qfrac, hash_hex);
    if (hn < 0 || (size_t) hn >= sizeof head) return;

    /* The exact record length, computed rather than ESTIMATED. The
     * old budget was a fixed 300 bytes plus the result, but the head
     * alone can be longer than that (the two "%.10g" doubles, the
     * counts, the 64-character hash), so the snprintf truncated and
     * the audit record was SILENTLY DROPPED -- the decision's
     * provenance went missing for exactly the runs with the most
     * interesting numbers. */
    size_t rlen = (result_json != NULL) ? strnlen(result_json, result_len) : 0;
    size_t cap  = (size_t) hn + rlen + 3;   /* head + result + "}}" + the NUL */

    char *js = (char *) malloc(cap);
    if (js == NULL) return;

    memcpy(js, head, (size_t) hn);
    if (rlen) memcpy(js + hn, result_json, rlen);
    memcpy(js + hn + rlen, "}}", 3);   /* includes the NUL */

    (void) fractal_ledger_write_kind2(js, (size_t) hn + rlen + 2);
    free(js);
}

FRACTAL_EXPORT bool
fractal_optimize_portfolio_multimodal_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 7) {
        SFS_INIT_ERROR(message,
            "fractal_optimize_portfolio_multimodal(mu_csv, cov_csv, k, n_restarts, "
            "overlap_threshold, quality_frac, seed): expected 7 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = INT_RESULT;
    args->arg_type[4] = REAL_RESULT;
    args->arg_type[5] = REAL_RESULT;
    args->arg_type[6] = INT_RESULT;
    initid->maybe_null = 1;
    initid->max_length = 16u * 1024u * 1024u;   /* same ceiling as the other JSON-output UDFs in this file */
    initid->ptr        = NULL;
    return false;
}

FRACTAL_EXPORT void
fractal_optimize_portfolio_multimodal_deinit(UDF_INIT *initid)
{
    free(initid->ptr);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_optimize_portfolio_multimodal(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                      unsigned long *length, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *mu = NULL, *cov = NULL, *weights = NULL, *sharpes = NULL;
    size_t  n_assets = 0, cov_n = 0;
    long long k, n_restarts_arg, seed;
    double  overlap, qfrac;
    int     n_restarts, n_found = 0, rc;
    ent_jsonbuf_t jb;
    bool    ok;
    (void) result;

    free(initid->ptr);
    initid->ptr = NULL;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL ||
        args->args[3] == NULL || args->args[4] == NULL || args->args[5] == NULL ||
        args->args[6] == NULL)
    {
        *is_null = 1;
        return NULL;
    }
    if (!ensure_enterprise_lib() || g_ent_portfolio_multimodal == NULL) {
        *is_null = 1;
        return NULL;
    }
    if (args->lengths[0] > ENT_MAX_CORPUS_BYTES || args->lengths[1] > ENT_MAX_CORPUS_BYTES) {
        *error = 1;
        return NULL;
    }

    k              = *(long long *) args->args[2];
    n_restarts_arg = *(long long *) args->args[3];
    overlap        = *(double *) args->args[4];
    qfrac          = *(double *) args->args[5];
    /* Clamp instead of casting: the core's seed is a uint64_t, so a
     * plain cast turned a negative argument into 18446744073709551615
     * -- a value the caller never asked for. A negative seed is not a
     * seed the core documents, so it falls back to the default. */
    {
        long long s = *(long long *) args->args[6];
        seed = (s < 0) ? 0 : s;
    }

    if (n_restarts_arg < 1 || n_restarts_arg > 64) { *error = 1; return NULL; }
    n_restarts = (int) n_restarts_arg;

    /* Enforce the ranges documented in sql/install_udf.sql and
     * docs/api-agency.md: overlap_threshold is 0.0-1.0, quality_frac is
     * 0.0 exclusive to 1.0 inclusive. */
    if (!(overlap >= 0.0 && overlap <= 1.0)) { *error = 1; return NULL; }
    if (!(qfrac > 0.0 && qfrac <= 1.0)) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &mu, &n_assets, errbuf)) {
        *error = 1;
        return NULL;
    }
    if (!parse_vector_csv(args->args[1], args->lengths[1], &cov, &cov_n, errbuf)) {
        free(mu);
        *error = 1;
        return NULL;
    }
    if (cov_n != n_assets * n_assets || k <= 0 || (size_t) k > n_assets) {
        free(mu);
        free(cov);
        *error = 1;
        return NULL;
    }

    weights = (double *) malloc((size_t) n_restarts * n_assets * sizeof(double));
    sharpes = (double *) malloc((size_t) n_restarts * sizeof(double));
    if (weights == NULL || sharpes == NULL) {
        free(mu); free(cov); free(weights); free(sharpes);
        *error = 1;
        return NULL;
    }

    rc = g_ent_portfolio_multimodal(mu, cov, n_assets, (size_t) k,
                                    n_restarts, overlap, qfrac, (uint64_t) seed,
                                    weights, sharpes, &n_found);
    if (rc != FSQL_OK) {
        free(mu); free(cov); free(weights); free(sharpes);
        *error = 1;
        return NULL;
    }
    /* Core-reported result count is untrusted: clamp it to the buffer
     * bounds validated above so the emit loop below can never index
     * past the weights/sharpes allocations, whatever the library
     * reports. */
    if (n_found > n_restarts) n_found = n_restarts;
    if (n_found < 0) n_found = 0;

    if (!ent_jsonbuf_init(&jb)) {
        free(mu); free(cov); free(weights); free(sharpes);
        *error = 1;
        return NULL;
    }

    ok = ent_jsonbuf_append(&jb, "{\"n_found\":%d,\"candidates\":[", n_found);
    for (int c = 0; ok && c < n_found; c++) {
        ok = ent_jsonbuf_append(&jb, "%s{\"sharpe\":%.10g,\"weights\":[", c ? "," : "", sharpes[c]);
        for (size_t i = 0; ok && i < n_assets; i++)
            ok = ent_jsonbuf_append(&jb, "%s%.10g", i ? "," : "",
                                    weights[(size_t) c * n_assets + i]);
        if (ok) ok = ent_jsonbuf_append(&jb, "]}");
    }
    if (ok) ok = ent_jsonbuf_append(&jb, "]}");

    free(weights);
    free(sharpes);

    if (!ok) {
        free(mu); free(cov);
        free(jb.buf);
        *error = 1;
        return NULL;
    }

    /* mu/cov kept alive until here so the audit entry's inputs_hash can
     * cover the same bytes the community-tier portfolio_audit_log_best_
     * effort() hashes for fractal_optimize_portfolio. */
    portfolio_multimodal_audit_log_best_effort(mu, cov, n_assets, (size_t) k, n_restarts,
                                               overlap, qfrac, seed, jb.buf, jb.len);
    free(mu);
    free(cov);

    initid->ptr = jb.buf;
    *length     = (unsigned long) jb.len;
    *is_null    = 0;
    return jb.buf;
}

/* diffusion_mode text -> the FSQL_SFS_DIFFUSE_* int the core expects
 * (fsql_optimize_portfolio_ex / _multimodal_ex / _multimodal_pareto's
 * shared convention, see fractalsql_sql.h). Returns -1 for anything
 * else; the caller turns that into a UDF error. */
static int
parse_diffusion_mode(const char *s, size_t len)
{
    if (len == 8 && memcmp(s, "gaussian", 8) == 0) return 0; /* FSQL_SFS_DIFFUSE_GAUSSIAN */
    if (len == 4 && memcmp(s, "levy", 4) == 0)      return 1; /* FSQL_SFS_DIFFUSE_LEVY */
    return -1;
}

/* ------------------------------------------------------------------ */
/* fractal_optimize_portfolio_multimodal_ex(mu_csv, cov_csv, k,         */
/*   n_restarts, overlap_threshold, quality_frac, seed, use_obl,        */
/*   diffusion_mode) -> TEXT (JSON)                                     */
/*                                                                        */
/* OBL/Levy-flight-capable sibling of the multimodal wrapper above:     */
/* same n_restarts search and diverse selection, with the two extra     */
/* knobs (see fsql_optimize_portfolio_ex's doc comment in               */
/* fractalsql_sql.h) applied uniformly to every restart's search.       */
/* use_obl is 0/1 (MariaDB's UDF ABI has no BOOLEAN argument type),     */
/* diffusion_mode is 'gaussian' or 'levy'. Falls back to the base       */
/* fsql_optimize_portfolio_multimodal symbol -- byte-identical behavior */
/* for the default knobs -- when the enterprise .so predates the _ex    */
/* symbol; NULL when the knobs were requested but the .so lacks them.   */
/* Same audit-chain entry as the base multimodal wrapper.               */
/* ------------------------------------------------------------------ */
FRACTAL_EXPORT bool
fractal_optimize_portfolio_multimodal_ex_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 9) {
        SFS_INIT_ERROR(message,
            "fractal_optimize_portfolio_multimodal_ex(mu_csv, cov_csv, k, n_restarts, "
            "overlap_threshold, quality_frac, seed, use_obl, diffusion_mode): "
            "expected 9 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = INT_RESULT;
    args->arg_type[4] = REAL_RESULT;
    args->arg_type[5] = REAL_RESULT;
    args->arg_type[6] = INT_RESULT;
    args->arg_type[7] = INT_RESULT;
    args->arg_type[8] = STRING_RESULT;
    initid->maybe_null = 1;
    initid->max_length = 16u * 1024u * 1024u;   /* same ceiling as the other JSON-output UDFs in this file */
    initid->ptr        = NULL;
    return false;
}

FRACTAL_EXPORT void
fractal_optimize_portfolio_multimodal_ex_deinit(UDF_INIT *initid)
{
    free(initid->ptr);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_optimize_portfolio_multimodal_ex(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                         unsigned long *length, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *mu = NULL, *cov = NULL, *weights = NULL, *sharpes = NULL;
    size_t  n_assets = 0, cov_n = 0;
    long long k, n_restarts_arg, seed;
    double  overlap, qfrac;
    long long use_obl_arg;
    int     n_restarts, n_found = 0, rc, diffusion_mode, use_obl;
    ent_jsonbuf_t jb;
    bool    ok;
    (void) result;

    free(initid->ptr);
    initid->ptr = NULL;

    for (int a = 0; a < 8; a++) {           /* diffusion_mode NULL-checks below */
        if (args->args[a] == NULL) { *is_null = 1; return NULL; }
    }
    /* Either symbol satisfies this wrapper: the _ex symbol is preferred
     * when the loaded enterprise .so has it, and the base symbol is the
     * fallback for an older .so. Requiring the BASE symbol unconditionally
     * refused an enterprise .so that ships only the newer one. */
    if (!ensure_enterprise_lib() ||
        (g_ent_portfolio_multimodal == NULL && g_ent_portfolio_multimodal_ex == NULL)) {
        *is_null = 1;
        return NULL;
    }
    if (args->lengths[0] > ENT_MAX_CORPUS_BYTES || args->lengths[1] > ENT_MAX_CORPUS_BYTES) {
        *error = 1;
        return NULL;
    }

    k              = *(long long *) args->args[2];
    n_restarts_arg = *(long long *) args->args[3];
    overlap        = *(double *) args->args[4];
    qfrac          = *(double *) args->args[5];
    /* Clamp instead of casting -- see the sibling optimizer above. */
    {
        long long s = *(long long *) args->args[6];
        seed = (s < 0) ? 0 : s;
    }
    use_obl_arg    = *(long long *) args->args[7];
    use_obl        = (use_obl_arg != 0) ? 1 : 0;
    diffusion_mode = 0;                     /* gaussian */

    /* diffusion_mode may itself be NULL (an absent argument), unlike the
     * seven required positional ones. */
    if (args->args[8] != NULL) {
        diffusion_mode = parse_diffusion_mode(args->args[8], args->lengths[8]);
        if (diffusion_mode < 0) { *error = 1; return NULL; }
    }

    if (n_restarts_arg < 1 || n_restarts_arg > 64) { *error = 1; return NULL; }
    n_restarts = (int) n_restarts_arg;

    /* Same ranges as the base multimodal wrapper above. */
    if (!(overlap >= 0.0 && overlap <= 1.0)) { *error = 1; return NULL; }
    if (!(qfrac > 0.0 && qfrac <= 1.0)) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &mu, &n_assets, errbuf)) {
        *error = 1;
        return NULL;
    }
    if (!parse_vector_csv(args->args[1], args->lengths[1], &cov, &cov_n, errbuf)) {
        free(mu);
        *error = 1;
        return NULL;
    }
    if (cov_n != n_assets * n_assets || k <= 0 || (size_t) k > n_assets) {
        free(mu);
        free(cov);
        *error = 1;
        return NULL;
    }

    /* The _ex symbol is optional in an older enterprise .so. Without it,
     * the base symbol runs the identical search as long as no OBL/Levy
     * knob was requested; requesting either knob on such a .so is a
     * capability the caller asked for and didn't get, so refuse. */
    if (g_ent_portfolio_multimodal_ex == NULL && (use_obl != 0 || diffusion_mode != 0)) {
        free(mu);
        free(cov);
        *is_null = 1;
        return NULL;
    }

    weights = (double *) malloc((size_t) n_restarts * n_assets * sizeof(double));
    sharpes = (double *) malloc((size_t) n_restarts * sizeof(double));
    if (weights == NULL || sharpes == NULL) {
        free(mu); free(cov); free(weights); free(sharpes);
        *error = 1;
        return NULL;
    }

    if (g_ent_portfolio_multimodal_ex != NULL) {
        rc = g_ent_portfolio_multimodal_ex(mu, cov, n_assets, (size_t) k,
                                           n_restarts, overlap, qfrac, (uint64_t) seed,
                                           use_obl, diffusion_mode,
                                           weights, sharpes, &n_found);
    } else {
        rc = g_ent_portfolio_multimodal(mu, cov, n_assets, (size_t) k,
                                        n_restarts, overlap, qfrac, (uint64_t) seed,
                                        weights, sharpes, &n_found);
    }
    if (rc != FSQL_OK) {
        free(mu); free(cov); free(weights); free(sharpes);
        *error = 1;
        return NULL;
    }
    /* Core-reported result count is untrusted: clamp it to the buffer
     * bounds validated above so the emit loop below can never index
     * past the weights/sharpes allocations, whatever the library
     * reports. */
    if (n_found > n_restarts) n_found = n_restarts;
    if (n_found < 0) n_found = 0;

    if (!ent_jsonbuf_init(&jb)) {
        free(mu); free(cov); free(weights); free(sharpes);
        *error = 1;
        return NULL;
    }

    ok = ent_jsonbuf_append(&jb, "{\"n_found\":%d,\"candidates\":[", n_found);
    for (int c = 0; ok && c < n_found; c++) {
        ok = ent_jsonbuf_append(&jb, "%s{\"sharpe\":%.10g,\"weights\":[", c ? "," : "", sharpes[c]);
        for (size_t i = 0; ok && i < n_assets; i++)
            ok = ent_jsonbuf_append(&jb, "%s%.10g", i ? "," : "",
                                    weights[(size_t) c * n_assets + i]);
        if (ok) ok = ent_jsonbuf_append(&jb, "]}");
    }
    if (ok) ok = ent_jsonbuf_append(&jb, "]}");

    free(weights);
    free(sharpes);

    if (!ok) {
        free(mu); free(cov);
        free(jb.buf);
        *error = 1;
        return NULL;
    }

    portfolio_multimodal_audit_log_best_effort(mu, cov, n_assets, (size_t) k, n_restarts,
                                               overlap, qfrac, seed, jb.buf, jb.len);
    free(mu);
    free(cov);

    initid->ptr = jb.buf;
    *length     = (unsigned long) jb.len;
    *is_null    = 0;
    return jb.buf;
}

/* Best-effort audit-chain provenance (ledger kind=2) for a Pareto-front
 * portfolio decision, same pattern as portfolio_multimodal_audit_log_
 * best_effort above but scored by decomposed (return, risk) and capped
 * by max_front instead of the sharpe-threshold selection, so the two
 * knobs it logs differ accordingly. */
static void
portfolio_multimodal_pareto_audit_log_best_effort(const double *mu, const double *cov,
                                                  size_t n_assets, size_t k, int n_restarts,
                                                  int max_front, long long seed,
                                                  const char *result_json, size_t result_len)
{
    if (!fractal_enterprise_lib_loaded())
        return;

    unsigned char hash[32];
    {
        size_t mu_bytes  = n_assets * sizeof(double);
        size_t cov_bytes = n_assets * n_assets * sizeof(double);
        unsigned char *buf = (unsigned char *) malloc(mu_bytes + cov_bytes);
        if (buf == NULL) return;
        memcpy(buf, mu, mu_bytes);
        memcpy(buf + mu_bytes, cov, cov_bytes);
        fractal_ledger_sha256(buf, mu_bytes + cov_bytes, hash);
        free(buf);
    }
    char hash_hex[65];
    for (int i = 0; i < 32; i++)
        snprintf(hash_hex + i * 2, 3, "%02x", hash[i]);

    /* The record's head: everything up to the result document. 1024
     * bytes covers it -- the widest fields are the counts and the
     * 64-character hash. */
    char head[1024];
    int  hn = snprintf(head, sizeof head,
        "{\"type\":\"portfolio_optimize_multimodal_pareto\",\"entry\":{"
        "\"seed\":%lld,\"n_assets\":%zu,\"k\":%zu,\"n_restarts\":%d,"
        "\"max_front\":%d,"
        "\"inputs_hash\":\"%s\",\"result\":",
        seed, n_assets, k, n_restarts, max_front, hash_hex);
    if (hn < 0 || (size_t) hn >= sizeof head) return;

    /* The exact record length, computed rather than ESTIMATED, like
     * the two sibling auditors above. This one still budgeted a fixed
     * 300 bytes plus the result; the head alone can exceed 300, so the
     * snprintf truncated and the whole audit record was SILENTLY
     * DROPPED for the widest inputs. */
    size_t rlen = (result_json != NULL) ? strnlen(result_json, result_len) : 0;
    size_t cap  = (size_t) hn + rlen + 3;   /* head + result + "}}" + the NUL */

    char *js = (char *) malloc(cap);
    if (js == NULL) return;

    memcpy(js, head, (size_t) hn);
    if (rlen) memcpy(js + hn, result_json, rlen);
    memcpy(js + hn + rlen, "}}", 3);   /* includes the NUL */

    (void) fractal_ledger_write_kind2(js, (size_t) hn + rlen + 2);
    free(js);
}

/* ------------------------------------------------------------------ */
/* fractal_optimize_portfolio_multimodal_pareto(mu_csv, cov_csv, k,     */
/*   n_restarts, max_front, seed, use_obl, diffusion_mode)              */
/*   -> TEXT (JSON)                                                     */
/*                                                                        */
/* Pareto-front sibling of the multimodal wrapper above: same           */
/* n_restarts independent searches, but each candidate is scored by     */
/* decomposed (return, risk) instead of scalar Sharpe and the results   */
/* are reduced to a genuine non-dominated Pareto front (NSGA-II         */
/* crowding-distance truncation past max_front) instead of the          */
/* sharpe-threshold + asset-overlap selection. Purely additive: does    */
/* not change that sibling's semantics or output shape. Requires the    */
/* fsql_optimize_portfolio_multimodal_pareto symbol in the enterprise   */
/* .so (there is no non-OBL fallback to fall back to, unlike the _ex    */
/* wrapper above). Returns                                              */
/* {"n_found":N,"candidates":[{"return":..,"risk":..,"sharpe":..,       */
/* "weights":[..]},...]}, Sharpe descending, or a clean NULL when the   */
/* enterprise library isn't loaded or the symbol isn't present in it.   */
/* ------------------------------------------------------------------ */
FRACTAL_EXPORT bool
fractal_optimize_portfolio_multimodal_pareto_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 8) {
        SFS_INIT_ERROR(message,
            "fractal_optimize_portfolio_multimodal_pareto(mu_csv, cov_csv, k, n_restarts, "
            "max_front, seed, use_obl, diffusion_mode): expected 8 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = INT_RESULT;
    args->arg_type[4] = INT_RESULT;
    args->arg_type[5] = INT_RESULT;
    args->arg_type[6] = INT_RESULT;
    args->arg_type[7] = STRING_RESULT;
    initid->maybe_null = 1;
    initid->max_length = 16u * 1024u * 1024u;   /* same ceiling as the other JSON-output UDFs in this file */
    initid->ptr        = NULL;
    return false;
}

FRACTAL_EXPORT void
fractal_optimize_portfolio_multimodal_pareto_deinit(UDF_INIT *initid)
{
    free(initid->ptr);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_optimize_portfolio_multimodal_pareto(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                             unsigned long *length, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *mu = NULL, *cov = NULL, *weights = NULL;
    double *returns = NULL, *risks = NULL;
    size_t  n_assets = 0, cov_n = 0;
    long long k, n_restarts_arg, max_front_arg, seed;
    double  sharpe_c;
    long long use_obl_arg;
    int     n_restarts, max_front, n_found = 0, rc, diffusion_mode, use_obl;
    ent_jsonbuf_t jb;
    bool    ok;
    (void) result;

    free(initid->ptr);
    initid->ptr = NULL;

    for (int a = 0; a < 7; a++) {           /* diffusion_mode NULL-checks below */
        if (args->args[a] == NULL) { *is_null = 1; return NULL; }
    }
    if (!ensure_enterprise_lib() || g_ent_portfolio_multimodal_pareto == NULL) {
        *is_null = 1;
        return NULL;
    }
    if (args->lengths[0] > ENT_MAX_CORPUS_BYTES || args->lengths[1] > ENT_MAX_CORPUS_BYTES) {
        *error = 1;
        return NULL;
    }

    k              = *(long long *) args->args[2];
    n_restarts_arg = *(long long *) args->args[3];
    max_front_arg  = *(long long *) args->args[4];
    /* Clamp instead of casting -- see the sibling optimizer above. */
    {
        long long s = *(long long *) args->args[5];
        seed = (s < 0) ? 0 : s;
    }
    use_obl_arg    = *(long long *) args->args[6];
    use_obl        = (use_obl_arg != 0) ? 1 : 0;
    diffusion_mode = 0;                     /* gaussian */

    if (args->args[7] != NULL) {
        diffusion_mode = parse_diffusion_mode(args->args[7], args->lengths[7]);
        if (diffusion_mode < 0) { *error = 1; return NULL; }
    }

    if (n_restarts_arg < 1 || n_restarts_arg > 64) { *error = 1; return NULL; }
    n_restarts = (int) n_restarts_arg;
    if (max_front_arg < 1 || max_front_arg > n_restarts) { *error = 1; return NULL; }
    max_front = (int) max_front_arg;

    if (!parse_vector_csv(args->args[0], args->lengths[0], &mu, &n_assets, errbuf)) {
        *error = 1;
        return NULL;
    }
    if (!parse_vector_csv(args->args[1], args->lengths[1], &cov, &cov_n, errbuf)) {
        free(mu);
        *error = 1;
        return NULL;
    }
    if (cov_n != n_assets * n_assets || k <= 0 || (size_t) k > n_assets) {
        free(mu);
        free(cov);
        *error = 1;
        return NULL;
    }

    weights = (double *) malloc((size_t) max_front * n_assets * sizeof(double));
    returns = (double *) malloc((size_t) max_front * sizeof(double));
    risks   = (double *) malloc((size_t) max_front * sizeof(double));
    if (weights == NULL || returns == NULL || risks == NULL) {
        free(mu); free(cov); free(weights); free(returns); free(risks);
        *error = 1;
        return NULL;
    }

    rc = g_ent_portfolio_multimodal_pareto(mu, cov, n_assets, (size_t) k,
                                           n_restarts, max_front, (uint64_t) seed,
                                           use_obl, diffusion_mode,
                                           weights, returns, risks, &n_found);
    if (rc != FSQL_OK) {
        free(mu); free(cov); free(weights); free(returns); free(risks);
        *error = 1;
        return NULL;
    }
    /* Core-reported result count is untrusted: clamp it to the buffer
     * bounds validated above so the emit loop below can never index
     * past the weights/returns/risks allocations, whatever the library
     * reports. */
    if (n_found > max_front) n_found = max_front;
    if (n_found < 0) n_found = 0;

    if (!ent_jsonbuf_init(&jb)) {
        free(mu); free(cov); free(weights); free(returns); free(risks);
        *error = 1;
        return NULL;
    }

    ok = ent_jsonbuf_append(&jb, "{\"n_found\":%d,\"candidates\":[", n_found);
    for (int c = 0; ok && c < n_found; c++) {
        sharpe_c = (risks[c] != 0.0) ? returns[c] / risks[c] : 0.0;
        ok = ent_jsonbuf_append(&jb, "%s{\"return\":%.10g,\"risk\":%.10g,\"sharpe\":%.10g,\"weights\":[",
                                c ? "," : "", returns[c], risks[c], sharpe_c);
        for (size_t i = 0; ok && i < n_assets; i++)
            ok = ent_jsonbuf_append(&jb, "%s%.10g", i ? "," : "",
                                    weights[(size_t) c * n_assets + i]);
        if (ok) ok = ent_jsonbuf_append(&jb, "]}");
    }
    if (ok) ok = ent_jsonbuf_append(&jb, "]}");

    free(weights);
    free(returns);
    free(risks);

    if (!ok) {
        free(mu); free(cov);
        free(jb.buf);
        *error = 1;
        return NULL;
    }

    portfolio_multimodal_pareto_audit_log_best_effort(mu, cov, n_assets, (size_t) k,
                                                      n_restarts, max_front, seed,
                                                      jb.buf, jb.len);
    free(mu);
    free(cov);

    initid->ptr = jb.buf;
    *length     = (unsigned long) jb.len;
    *is_null    = 0;
    return jb.buf;
}
