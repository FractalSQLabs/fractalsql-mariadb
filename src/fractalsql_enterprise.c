/* src/fractalsql_enterprise.c
 * Enterprise tier: activation gating for the QTL ledger and CISO audit
 * primitives, plus a real, file-backed persistence layer for the ledger
 * itself.
 *
 * This file implements two layers:
 *
 * 1. ACTIVATION GATING: a FRACTALSQL_ENTERPRISE_LIB environment variable
 *    names a separately built enterprise core shared library, which is
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
 *    file, path from FRACTALSQL_ENTERPRISE_LEDGER_PATH (default:
 *    fractalsql_ledger.dat, relative to mysqld's cwd, which for a
 *    standard install IS the datadir, since mysqld chdir()s there at
 *    startup), following the same "everything is a process environment
 *    variable" convention as the rest of this extension's config surface.
 *
 *    The ledger is an APPEND-ONLY chain of records per `kind`, each
 *    linking to its predecessor via entry_hash = SHA256(prev_hash ||
 *    blob || mac) (see fractalsql_hmac.h, a header-only, public-domain
 *    SHA-256 + HMAC-SHA256 implementation, so this carries no OpenSSL
 *    dependency for the chain itself). A rewritten record breaks the
 *    very next record's prev_hash link; a deleted record leaves the same
 *    visible break, no separate id-sequence bookkeeping needed to detect
 *    it. Optional HMAC-SHA256 tamper authentication activates when
 *    FRACTALSQL_ENTERPRISE_LEDGER_KEY is set. fractal_ledger_load's O(1)
 *    tip-only check before decode (ledger_verify_latest_file) and
 *    fractal_ledger_verify(session_id[, kind])'s O(n) full chain walk
 *    both scan the file sequentially rather than issuing SQL SELECTs.
 *
 *    Concurrency: MariaDB has no transaction-scoped lock reachable from
 *    a UDF, so this file holds the same process-wide mutex the
 *    dlopen/dlsym gating below already uses (ent_lock/ent_unlock) around
 *    the read-modify-append sequence in ledger_write_entry, for the
 *    duration of that one call. MariaDB is one shared process for every
 *    connection, so this still fully serializes concurrent writers
 *    against each other, even without a longer-lived transaction
 *    boundary (mysqld's classic UDF protocol has no multi-statement
 *    transaction boundary a plugin can observe).
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
 * CONFIG:
 *   FRACTALSQL_ENTERPRISE_LIB (required to activate): the enterprise
 *     core .so's absolute path, read once at mysqld startup.
 *   FRACTALSQL_ENTERPRISE_LEDGER_PATH (optional): the ledger file's
 *     path, default "fractalsql_ledger.dat" relative to mysqld's cwd.
 *   FRACTALSQL_ENTERPRISE_LEDGER_KEY (optional): HMAC-SHA256 key for
 *     MAC-authenticated tamper evidence; unset means structural-only
 *     (entry_hash chain) validation.
 *   FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE (optional): when set to a
 *     non-empty, non-"0" value, refuses to load an enterprise .so with
 *     no sibling <path>.sig file (an INVALID signature is always fatal
 *     regardless of this setting). Default off: an unsigned .so still
 *     loads (logged to stderr).
 *   MariaDB runs one shared process for every connection, so the dlopen
 *   attempt/result is cached process-wide, not per session.
 */

#include <mysql.h>

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#  include <windows.h>
#  include <io.h>                /* _commit: flush the ledger write through to disk */
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  include <dlfcn.h>
#  include <pthread.h>
#  include <unistd.h>            /* fsync: flush the ledger write through to disk */
#  define FRACTAL_EXPORT
#endif

#include "fractalsql.h"          /* FSQL_OK, fsql_last_error */
#include "fractalsql_sql.h"      /* fsql_ctx, fsql_ledger_*, fsql_audit_unpack */
#include "fractalsql_session.h"  /* fractal_session_acquire/_release */
#include "fractalsql_enterprise.h"
#include "fractalsql_hmac.h"     /* fsql_sha256/fsql_hmac_sha256: vendored, public-domain SHA-256 + HMAC-SHA256 */
#include "fractalsql_parse.h"    /* parse_vector_csv, shared with fractalsql.c/fractalsql_vector.c */

#include <openssl/evp.h>         /* Ed25519 signature verification, see ent_verify_signature() */
#include <openssl/crypto.h>      /* CRYPTO_memcmp: constant-time ledger MAC comparison */

#define SFS_INIT_ERROR(msg, ...) \
    (snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__))

#define ENT_NOT_LOADED_MSG \
    "enterprise tier not loaded: set FRACTALSQL_ENTERPRISE_LIB to the " \
    "enterprise core .so's absolute path and restart, or install FractalSQL " \
    "Enterprise if this is a Community deployment"

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
static INIT_ONCE        g_ent_once  = INIT_ONCE_STATIC_INIT;
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
 * library, so the copy persists: it is pid-named (pids recycle), owned
 * by the mysqld service user, and a later mysqld with the same pid
 * overwrites it rather than accumulating copies. */
static void *
ent_dlopen_verified_copy(const char *orig_path,
                         const unsigned char *bytes, size_t len)
{
    char        tmp_path[4096];
    const char *slash    = strrchr(orig_path, '/');
    const char *backlash = strrchr(orig_path, '\\');
    const char *sep      = (backlash > slash) ? backlash : slash;
    size_t      dir_len  = (sep != NULL) ? (size_t) (sep - orig_path + 1) : 0;
    FILE       *f;

    if (dir_len >= sizeof tmp_path) return NULL;
    memcpy(tmp_path, orig_path, dir_len);
#if defined(_WIN32)
    snprintf(tmp_path + dir_len, sizeof tmp_path - dir_len,
             ".fractalsql-ent-%lu.tmp", (unsigned long) GetCurrentProcessId());
    f = fopen(tmp_path, "wb");   /* pid-recycled overwrite, see above */
#else
    snprintf(tmp_path + dir_len, sizeof tmp_path - dir_len,
             ".fractalsql-ent-XXXXXX");
    {
        int fd = mkstemp(tmp_path);   /* exclusive create, mode 0600 */
        if (fd < 0) return NULL;
        f = fdopen(fd, "wb");
        if (f == NULL) { close(fd); remove(tmp_path); return NULL; }
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
/* FractalSQLabs's long-lived Ed25519 signing public key. The matching  */
/* private key is held offline in the enterprise release process, never */
/* in this repo. */
static const unsigned char FSQL_ENTERPRISE_PUBKEY[32] = {
    0xd5, 0xf6, 0x08, 0xa5, 0x8b, 0x1e, 0xb7, 0xe5, 0x9a, 0xcb, 0x8f, 0xab,
    0x80, 0x35, 0x9d, 0x58, 0x3f, 0x4e, 0xd1, 0xd1, 0xa2, 0x9c, 0x33, 0x6b,
    0xcb, 0x4b, 0x43, 0xcf, 0xf1, 0x07, 0x7f, 0xcb
};

typedef enum {
    ENT_SIG_OK,        /* .sig present and verifies against the pubkey */
    ENT_SIG_MISSING,   /* no .sig file found -- soft unless require=on */
    ENT_SIG_INVALID,   /* .sig present but wrong -- always fatal */
    ENT_SIG_IOERROR    /* could not read the .so or .sig file at all */
} ent_sig_result_t;

/* NOTE: the Windows UCRT stdio implementation has a documented
 * STATUS_STACK_BUFFER_OVERRUN crash inside fread/fread_s's own internal
 * validation under certain in-process hosting conditions. This function
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
    if (fseek(f, 0, SEEK_END) != 0 || (so_len = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0)
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
                                       FSQL_ENTERPRISE_PUBKEY, sizeof FSQL_ENTERPRISE_PUBKEY);
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

/* FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1 makes a MISSING .sig fatal
 * (an INVALID .sig is always fatal regardless). Default off: backward
 * compatible with an enterprise .so shipped without a .sig. */
static bool
ent_require_signature(void)
{
    const char *v = getenv("FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE");
    return v != NULL && v[0] != '\0' && v[0] != '0';
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
 * symbol resolved. */
static bool
ensure_enterprise_lib(void)
{
    const char *path;
    void       *h;
    unsigned char    *verified_bytes = NULL;
    size_t            verified_len   = 0;
    ent_sig_result_t  sig;

    ent_lock();
    if (g_ent_loaded) { ent_unlock(); return true; }
    if (g_ent_attempted) { ent_unlock(); return false; }
    g_ent_attempted = true;

    path = getenv("FRACTALSQL_ENTERPRISE_LIB");
    if (path == NULL || path[0] == '\0') { ent_unlock(); return false; }

    /* Signature check before loading: an INVALID .sig always refuses (a
     * tampered/corrupt file, regardless of require_signature). A
     * MISSING .sig refuses only when FRACTALSQL_ENTERPRISE_REQUIRE_
     * SIGNATURE is set; otherwise this loads unverified (logged to
     * stderr, mysqld's error log destination: there is no SQL-visible
     * WARNING channel reachable from here, since this runs lazily from
     * whichever UDF call happens to be first, not from a context with a
     * message buffer). */
    sig = ent_verify_signature(path, &verified_bytes, &verified_len);
    if (sig == ENT_SIG_INVALID)
    {
        fprintf(stderr,
               "fractalsql: enterprise library \"%s\" failed signature "
               "verification -- refusing to load (the .so or its .sig "
               "does not match the expected FractalSQLabs signing key; "
               "the file may be corrupt or tampered)\n", path);
        ent_unlock();
        return false;
    }
    if (sig == ENT_SIG_MISSING && ent_require_signature())
    {
        fprintf(stderr,
               "fractalsql: no signature found for enterprise library "
               "\"%s\" (expected \"%s.sig\") and "
               "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE is set\n", path, path);
        ent_unlock();
        return false;
    }
    if (sig == ENT_SIG_MISSING)
        fprintf(stderr,
               "fractalsql: no signature found for enterprise library "
               "\"%s\" -- loading unverified (set "
               "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1 to refuse "
               "unsigned enterprise libraries)\n", path);

    /* Load the exact bytes the signature was verified over (via a
     * private temp copy), not the on-disk path, which could have been
     * swapped between the verification read and the load. Unverified
     * (missing-signature, soft-allowed) loads keep the previous
     * behavior of loading the path directly: there is no verification
     * claim for a swap to violate. */
    if (sig == ENT_SIG_OK)
    {
        h = ent_dlopen_verified_copy(path, verified_bytes, verified_len);
        free(verified_bytes);
    }
    else
        h = ent_dlopen(path);
    if (h == NULL) { ent_unlock(); return false; }

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

    if (!g_ent_ledger_flush || !g_ent_ledger_load || !g_ent_ledger_compact ||
        !g_ent_ledger_reset_soft || !g_ent_ledger_reset_hard ||
        !g_ent_ledger_truth_count || !g_ent_ledger_shadow_count ||
        !g_ent_audit_unpack)
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

/* ==================================================================== */
/* Ledger file storage VFS                                              */
/* ==================================================================== */

#define LEDGER_MAGIC     "FSQLLDGR"
#define LEDGER_MAGIC_LEN 8
#define LEDGER_VERSION   1
#define LEDGER_HASH_LEN  32

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
    const char *p = getenv("FRACTALSQL_ENTERPRISE_LEDGER_PATH");
    return (p && p[0]) ? p : "fractalsql_ledger.dat";
}

static const char *
ledger_key(void)
{
    const char *k = getenv("FRACTALSQL_ENTERPRISE_LEDGER_KEY");
    return (k && k[0]) ? k : NULL;
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

/* Counts existing lines in the CSV mirror (0 if it doesn't exist yet),
 * used to assign the next row's `id`. A plain line count, not a
 * per-kind count: `id` is a single sequence shared by kind=1 and kind=2
 * rows, not two independent per-kind sequences. */
static long long
ledger_csv_next_id(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (fp == NULL) return 1;
    long long n = 0;
    int c;
    while ((c = fgetc(fp)) != EOF) if (c == '\n') n++;
    fclose(fp);
    return n + 1;
}

/* Best-effort: appends one CSV row. Never fails the caller's flush --
 * see this section's header comment. */
static void
ledger_csv_append(uint32_t kind, const void *payload, size_t len,
                  bool has_mac, const uint8_t mac[LEDGER_HASH_LEN],
                  const uint8_t prev_hash[LEDGER_HASH_LEN],
                  const uint8_t entry_hash[LEDGER_HASH_LEN],
                  int64_t updated)
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

    long long next_id = ledger_csv_next_id(csv_path);

    FILE *fp = fopen(csv_path, "ab");
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
    FILE *fp = fopen(ledger_path(), "rb");
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
 * corrupt/truncated file. */
static int
ledger_scan_latest_two(FILE *fp, uint32_t want_kind,
                       ledger_record_t *latest, bool *have_latest,
                       ledger_record_t *prior,  bool *have_prior)
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

    for (;;)
    {
        uint32_t kind, blen;
        uint8_t  has_mac, sealed, mac[LEDGER_HASH_LEN], prev[LEDGER_HASH_LEN], hash[LEDGER_HASH_LEN];
        int64_t  updated;
        int      hr = ledger_read_record_header(fp, &kind, &blen, &has_mac, &sealed,
                                                mac, prev, hash, &updated);
        if (hr == 0) break;
        if (hr < 0) return -1;

        uint8_t *blob = NULL;
        if (blen > 0)
        {
            blob = (uint8_t *) malloc(blen);
            if (blob == NULL) return -1;
            if (fread(blob, 1, blen, fp) != blen) { free(blob); return -1; }
        }

        if (kind == want_kind)
        {
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
    return 0;
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
            uint8_t *blob = (uint8_t *) malloc(blen);
            if (blob == NULL) { fclose(fp); return false; }
            if (fread(blob, 1, blen, fp) != blen) { free(blob); torn_at = rec_start; break; }
            free(blob);
        }
    }

    if (torn_at >= 0L)
    {
#if defined(_WIN32) || defined(__CYGWIN__)
        int rc = _chsize(_fileno(fp), torn_at);
#else
        int rc = ftruncate(fileno(fp), torn_at);
#endif
        if (rc != 0) { fclose(fp); return false; }
    }
    fclose(fp);
    return true;
}

static int
ledger_write_entry(fsql_storage_user_ctx user, int kind,
                   const void *payload, size_t len)
{
    (void) user;
    /* The record header stores the blob length as uint32_t: a silent
     * truncation here would write a record whose header undersells its
     * own bytes (an instant chain brick for every later reader). No
     * current caller can reach this (packet caps bound len far below
     * 4 GiB), but this is an exported seam -- fail loudly instead. */
    if (len > 0xFFFFFFFFu) return FSQL_ESTORAGE;

    ent_lock();

    FILE *fp = fopen(ledger_path(), "r+b");
    bool  is_new = false;
    if (fp == NULL)
    {
        fp = fopen(ledger_path(), "w+b");
        if (fp == NULL) { ent_unlock(); return FSQL_ESTORAGE; }
        is_new = true;
    }

    if (is_new)
    {
        if (!ledger_write_header(fp)) { fclose(fp); ent_unlock(); return FSQL_ESTORAGE; }
    }
    else
    {
        char magic[LEDGER_MAGIC_LEN];
        if (fread(magic, 1, LEDGER_MAGIC_LEN, fp) != LEDGER_MAGIC_LEN ||
            memcmp(magic, LEDGER_MAGIC, LEDGER_MAGIC_LEN) != 0 ||
            fgetc(fp) != LEDGER_VERSION)
        {
            fclose(fp); ent_unlock(); return FSQL_ESTORAGE;
        }
    }

    ledger_record_t latest, prior;
    bool have_latest = false, have_prior = false;
    if (ledger_scan_latest_two(fp, (uint32_t) kind, &latest, &have_latest,
                               &prior, &have_prior) < 0)
    {
        /* The scan failed: most likely a torn tail from a crash or
         * power loss mid-append. Repair (truncate the partial final
         * record) and rescan once; without this, a single torn append
         * bricks the file for every future write. */
        fclose(fp);
        if (!ledger_repair_torn_tail()) { ent_unlock(); return FSQL_ESTORAGE; }
        fp = fopen(ledger_path(), "r+b");
        if (fp == NULL) { ent_unlock(); return FSQL_ESTORAGE; }
        if (ledger_scan_latest_two(fp, (uint32_t) kind, &latest, &have_latest,
                                   &prior, &have_prior) < 0)
        {
            fclose(fp); ent_unlock(); return FSQL_ESTORAGE;
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
        if (buf == NULL) { fclose(fp); ent_unlock(); return FSQL_ESTORAGE; }
        memcpy(buf, prev_hash, LEDGER_HASH_LEN);
        memcpy(buf + LEDGER_HASH_LEN, payload, len);
        if (have_mac) memcpy(buf + LEDGER_HASH_LEN + len, mac_tag, LEDGER_HASH_LEN);
        fsql_sha256(buf, buflen, entry_hash);
        free(buf);
    }

    /* Reopen in append mode for the record write: every write lands at
     * EOF regardless of where any other process's own appends have
     * moved the end. The seek-then-write this replaces is not O_APPEND
     * -- two server processes pointed at the same ledger path would
     * silently overwrite each other's records mid-chain. (The
     * process-internal writers are already serialized by the lock held
     * across this whole function.) */
    fclose(fp);
    fp = fopen(ledger_path(), "ab");
    if (fp == NULL) { ent_unlock(); return FSQL_ESTORAGE; }

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

    /* Check the flush: on ENOSPC, an unchecked fflush would report a
     * successful append for bytes that never reached the file (and the
     * CSV mirror below would record a row the binary chain lacks). */
    if (ok) ok = (fflush(fp) == 0);
#if defined(_WIN32) || defined(__CYGWIN__)
    if (ok) ok = (_commit(_fileno(fp)) == 0);
#else
    if (ok) ok = (fsync(fileno(fp)) == 0);
#endif
    fclose(fp);

    if (ok)
        ledger_csv_append(kind32, payload, len, have_mac, mac_field,
                          prev_hash, entry_hash, updated);

    ent_unlock();
    return ok ? FSQL_OK : FSQL_ESTORAGE;
}

/* read_entry: the storage VFS contract hands back a buffer "the
 * implementation owns; the engine never frees". MariaDB has no automatic
 * memory reclamation for this, so this keeps one outstanding buffer
 * alive per calling thread (freed at the START of that thread's next
 * read_entry call, or at thread exit) rather than leaking one buffer
 * per call -- a bounded, per-thread single-slot cache, not a real free,
 * matching the contract's letter (the engine itself never has to free
 * it). Per-thread, not process-global: the consumer decodes the buffer
 * AFTER this function returns and after the lock is dropped, so a
 * shared slot would let a second connection's read free the first
 * connection's buffer mid-decode (heap corruption inside the server). */
#if defined(_WIN32) || defined(__CYGWIN__)
static __declspec(thread) uint8_t *t_last_read_blob = NULL;
#else
static __thread uint8_t *t_last_read_blob = NULL;
#endif

static int
ledger_read_entry(fsql_storage_user_ctx user, int kind,
                  const void **payload_out, size_t *len_out)
{
    (void) user;
    *payload_out = NULL;
    *len_out     = 0;

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
                                     &prior, &have_prior);
    fclose(fp);

    if (rc < 0) { ent_unlock(); return FSQL_ESTORAGE; }
    if (have_prior) free(prior.blob);
    if (!have_latest) { ent_unlock(); return FSQL_ESTORAGE_UNAVAILABLE; }

    free(t_last_read_blob);
    t_last_read_blob = latest.blob;   /* transfer ownership to this thread's slot */

    *payload_out = t_last_read_blob;
    *len_out     = latest.blob_len;
    ent_unlock();
    return FSQL_OK;
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
    return g_ent_loaded;
}

int
fractal_ledger_write_kind2(const char *json, size_t len)
{
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
    int  rc = ledger_scan_latest_two(fp, kind, &latest, &have_latest, &prior, &have_prior);
    fclose(fp);
    if (rc < 0) { ent_unlock(); return FSQL_ESTORAGE_INTEGRITY; }
    if (!have_latest) { if (have_prior) free(prior.blob); ent_unlock(); return FSQL_OK; }

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
            size_t   buflen = LEDGER_HASH_LEN + latest.blob_len + (latest.has_mac ? LEDGER_HASH_LEN : 0);
            uint8_t *buf    = (uint8_t *) malloc(buflen);
            if (buf == NULL)
            {
                result = FSQL_ESTORAGE;
            }
            else
            {
                memcpy(buf, latest.prev_hash, LEDGER_HASH_LEN);
                memcpy(buf + LEDGER_HASH_LEN, latest.blob, latest.blob_len);
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
#define ENT_LEDGER_VOID_UDF(name, fnptr)                                              \
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
    if (!ensure_enterprise_lib()) { *error = 1; return 0; }                            \
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];        \
    fsql_ctx *ctx = fractal_session_acquire(sid);                                      \
    if (ctx == NULL) { *error = 1; return 0; }                                         \
    int rc = fnptr(ctx);                                                                \
    fractal_session_release(sid);                                                      \
    if (rc != FSQL_OK) { *error = 1; return 0; }                                       \
    *is_null = 0;                                                                       \
    return 0;                                                                           \
}

ENT_LEDGER_VOID_UDF(fractal_ledger_flush,      g_ent_ledger_flush)
ENT_LEDGER_VOID_UDF(fractal_ledger_compact,    g_ent_ledger_compact)
ENT_LEDGER_VOID_UDF(fractal_ledger_reset_soft, g_ent_ledger_reset_soft)
ENT_LEDGER_VOID_UDF(fractal_ledger_reset_hard, g_ent_ledger_reset_hard)

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
        ent_unlock();
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
        const char *reason = NULL;

        for (;;)
        {
            uint32_t rkind, blen;
            uint8_t  has_mac, sealed, mac[LEDGER_HASH_LEN], prev[LEDGER_HASH_LEN], hash[LEDGER_HASH_LEN];
            int64_t  updated;
            int      hr = ledger_read_record_header(fp, &rkind, &blen, &has_mac, &sealed,
                                                    mac, prev, hash, &updated);
            if (hr == 0) break;
            if (hr < 0) { reason = "truncated or corrupt record"; fail_id = n + 1; break; }

            uint8_t *blob = NULL;
            if (blen > 0)
            {
                blob = (uint8_t *) malloc(blen);
                if (blob == NULL || fread(blob, 1, blen, fp) != blen)
                {
                    free(blob);
                    reason = "truncated blob";
                    fail_id = n + 1;
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
                size_t   buflen = LEDGER_HASH_LEN + blen + (has_mac ? LEDGER_HASH_LEN : 0);
                uint8_t *buf    = (uint8_t *) malloc(buflen);
                if (buf == NULL) { ok = false; reason = "out of memory"; }
                else
                {
                    memcpy(buf, prev, LEDGER_HASH_LEN);
                    memcpy(buf + LEDGER_HASH_LEN, blob, blen);
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
            if (!ok) { fail_id = n; break; }
            memcpy(prev_expected, hash, LEDGER_HASH_LEN);
        }
        fclose(fp);
        ent_unlock();

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
    int  sp = 0;
    bool in_str = false, esc = false;
    bool after_value = false, seen_any = false;
    size_t i;

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
            if (after_value) return false;
            in_str = true;
            after_value = true;
            seen_any = true;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        if (c == '[' || c == '{')
        {
            if (after_value) return false;
            if (sp >= (int) sizeof stack) return false;
            stack[sp++] = c;
            seen_any = true;
            continue;
        }
        if (c == ']' || c == '}')
        {
            if (sp == 0 || !after_value) return false;
            sp--;
            char open = stack[sp];
            if ((c == ']' && open != '[') || (c == '}' && open != '{')) return false;
            continue;
        }
        if (c == ',')
        {
            if (sp == 0 || !after_value) return false;
            after_value = false;
            continue;
        }
        if (after_value) return false;
        if (c == 't' || c == 'f' || c == 'n')
        {
            const char *lit = (c == 't') ? "true" : (c == 'f') ? "false" : "null";
            size_t ll = strlen(lit);
            if (len - i < ll || memcmp(s + i, lit, ll) != 0) return false;
            i += ll - 1;
            after_value = true;
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
            after_value = true;
            seen_any = true;
        }
    }
    return seen_any && !in_str && sp == 0 && after_value;
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
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
                       "fractal_audit_log(entry_type, payload_json): expected 2 arguments, got %u",
                       args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
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

    /* Shape-gate both fields before they reach the chain record (see
     * the comment block above). Built-in flows pass fixed short
     * literals and JSON_OBJECT() output, which both clear this easily;
     * a session trying to splice in forged fields now fails cleanly
     * here instead of landing in the chain. */
    if (type_len > 256) { *error = 1; return 0; }
    if (!ent_json_well_formed(payload, payload_len)) { *error = 1; return 0; }

    char   esc_stack[512];
    char  *esc = esc_stack;
    size_t esc_cap = type_len * 6 + 1;
    if (esc_cap > sizeof esc_stack) { esc = (char *) malloc(esc_cap); if (esc == NULL) { *error = 1; return 0; } }
    size_t esc_len = ent_json_escape(type_s, type_len, esc, esc_cap);
    if (esc_len == (size_t) -1) { if (esc != esc_stack) free(esc); *error = 1; return 0; }

    size_t buflen = esc_len + payload_len + 32;
    char  *buf = (char *) malloc(buflen);
    if (buf == NULL) { if (esc != esc_stack) free(esc); *error = 1; return 0; }

    int n = snprintf(buf, buflen, "{\"type\":\"%.*s\",\"entry\":%.*s}",
                     (int) esc_len, esc, (int) payload_len, payload);
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

    cap = 8192;
    for (;;) {
        char  *nb;
        size_t need = cap;

        nb = realloc(so->buf, cap);
        if (nb == NULL) { *error = 1; return NULL; }
        so->buf = nb; so->cap = cap;

        rc = g_ent_audit_unpack(args->args[0], args->lengths[0], so->buf, &need);
        if (rc == FSQL_OK) {
            *length  = (unsigned long) strnlen(so->buf, need);
            *is_null = 0;
            return so->buf;
        }
        if (rc == FSQL_ETRUNCATED && need > cap && cap < (16u * 1024u * 1024u)) {
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

        size_t newcap = jb->cap * 2;
        while (newcap < jb->len + (size_t) need + 1) newcap *= 2;
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

    size_t cap = 300 + result_len;
    char  *js  = (char *) malloc(cap);
    if (js == NULL) return;

    int pos = snprintf(js, cap,
        "{\"type\":\"portfolio_optimize_multimodal\",\"entry\":{"
        "\"seed\":%lld,\"n_assets\":%zu,\"k\":%zu,\"n_restarts\":%d,"
        "\"overlap_threshold\":%.10g,\"quality_frac\":%.10g,"
        "\"inputs_hash\":\"%s\",\"result\":%.*s}}",
        seed, n_assets, k, n_restarts, overlap, qfrac, hash_hex,
        (int) result_len, result_json);
    if (pos < 0 || (size_t) pos >= cap) { free(js); return; }

    (void) fractal_ledger_write_kind2(js, (size_t) pos);
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
    seed           = *(long long *) args->args[6];

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
    seed           = *(long long *) args->args[6];
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

    size_t cap = 300 + result_len;
    char  *js  = (char *) malloc(cap);
    if (js == NULL) return;

    int pos = snprintf(js, cap,
        "{\"type\":\"portfolio_optimize_multimodal_pareto\",\"entry\":{"
        "\"seed\":%lld,\"n_assets\":%zu,\"k\":%zu,\"n_restarts\":%d,"
        "\"max_front\":%d,"
        "\"inputs_hash\":\"%s\",\"result\":%.*s}}",
        seed, n_assets, k, n_restarts, max_front, hash_hex,
        (int) result_len, result_json);
    if (pos < 0 || (size_t) pos >= cap) { free(js); return; }

    (void) fractal_ledger_write_kind2(js, (size_t) pos);
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
    seed           = *(long long *) args->args[5];
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
