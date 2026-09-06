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
 *    fixed FractalSQLabs public key before dlopen. Not implemented:
 *    fsql_optimize_portfolio_multimodal(_ex/_pareto), a natural follow-up
 *    once that primitive is revisited.
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

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#  include <windows.h>
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  include <dlfcn.h>
#  include <pthread.h>
#  define FRACTAL_EXPORT
#endif

#include "fractalsql.h"          /* FSQL_OK, fsql_last_error */
#include "fractalsql_sql.h"      /* fsql_ctx, fsql_ledger_*, fsql_audit_unpack */
#include "fractalsql_session.h"  /* fractal_session_acquire/_release */
#include "fractalsql_enterprise.h"
#include "fractalsql_hmac.h"     /* fsql_sha256/fsql_hmac_sha256: vendored, public-domain SHA-256 + HMAC-SHA256 */

#include <openssl/evp.h>         /* Ed25519 signature verification, see ent_verify_signature() */

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
static ent_sig_result_t
ent_verify_signature(const char *so_path)
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
        result = ENT_SIG_OK;
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
 * symbols, exactly once per process. Thread-safe (double-checked
 * locking): MariaDB is one shared multithreaded process, so this must
 * guard against two connection threads racing their first enterprise
 * call simultaneously. Returns true iff every required symbol resolved. */
static bool
ensure_enterprise_lib(void)
{
    const char *path;
    void       *h;

    if (g_ent_loaded) return true;

    ent_lock();
    if (g_ent_loaded) { ent_unlock(); return true; }
    if (g_ent_attempted) { ent_unlock(); return false; }
    g_ent_attempted = true;

    path = getenv("FRACTALSQL_ENTERPRISE_LIB");
    if (path == NULL || path[0] == '\0') { ent_unlock(); return false; }

    /* Signature check before dlopen: an INVALID .sig always refuses (a
     * tampered/corrupt file, regardless of require_signature). A
     * MISSING .sig refuses only when FRACTALSQL_ENTERPRISE_REQUIRE_
     * SIGNATURE is set; otherwise this loads unverified (logged to
     * stderr, mysqld's error log destination: there is no SQL-visible
     * WARNING channel reachable from here, since this runs lazily from
     * whichever UDF call happens to be first, not from a context with a
     * message buffer). */
    {
        ent_sig_result_t sig = ent_verify_signature(path);
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
    }

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
static int
ledger_write_entry(fsql_storage_user_ctx user, int kind,
                   const void *payload, size_t len)
{
    (void) user;
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
        fclose(fp); ent_unlock(); return FSQL_ESTORAGE;
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

    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); ent_unlock(); return FSQL_ESTORAGE; }

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

    if (ok) fflush(fp);
    fclose(fp);

    if (ok)
        ledger_csv_append(kind32, payload, len, have_mac, mac_field,
                          prev_hash, entry_hash, updated);

    ent_unlock();
    return ok ? FSQL_OK : FSQL_ESTORAGE;
}

/* read_entry: the storage VFS contract hands back a buffer "the
 * implementation owns; the engine never frees". MariaDB has no automatic
 * memory reclamation for this, so this keeps exactly one outstanding
 * buffer alive at a time (freed at the START of the next read_entry
 * call, or at process exit) rather than leaking one buffer per call, a
 * bounded, single-slot cache, not a real free, matching the contract's
 * letter (the engine itself never has to free it). */
static uint8_t *g_last_read_blob = NULL;

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

    free(g_last_read_blob);
    g_last_read_blob = latest.blob;   /* transfer ownership to the single-slot cache */

    *payload_out = g_last_read_blob;
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
    bool  bad_header = false;
    FILE *fp = ledger_open_for_read(&bad_header);
    if (fp == NULL) return bad_header ? FSQL_ESTORAGE_INTEGRITY : FSQL_OK;

    ledger_record_t latest, prior;
    bool have_latest = false, have_prior = false;
    int  rc = ledger_scan_latest_two(fp, kind, &latest, &have_latest, &prior, &have_prior);
    fclose(fp);
    if (rc < 0) return FSQL_ESTORAGE_INTEGRITY;
    if (!have_latest) { if (have_prior) free(prior.blob); return FSQL_OK; }

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
            if (memcmp(tag, latest.mac, LEDGER_HASH_LEN) != 0)
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

    bool  bad_header = false;
    FILE *fp = ledger_open_for_read(&bad_header);
    char *out;

    if (fp == NULL && !bad_header)
    {
        out = strdup("{\"ok\":true,\"rows_verified\":0}");
    }
    else if (fp == NULL)   /* bad_header */
    {
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
                if (memcmp(tag, mac, LEDGER_HASH_LEN) != 0) { ok = false; reason = "HMAC mismatch"; }
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
/* a deliberate product-tier gate, not a technical necessity. No           */
/* session_id argument: unlike flush/load/etc., this never touches a       */
/* session's in-memory ctx. payload_json is accepted as opaque text (not   */
/* validated as JSON), consistent with how the rest of this file treats    */
/* caller-supplied JSON.                                                   */
/* ------------------------------------------------------------------ */
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
    if (!ensure_enterprise_lib()) { *error = 1; return 0; }

    const char *type_s   = args->args[0];
    size_t      type_len = args->lengths[0];
    const char *payload  = (args->args[1] != NULL) ? args->args[1] : "null";
    size_t      payload_len = (args->args[1] != NULL) ? args->lengths[1] : 4;

    size_t buflen = type_len + payload_len + 32;
    char  *buf = (char *) malloc(buflen);
    if (buf == NULL) { *error = 1; return 0; }

    /* type_s is embedded as a bare JSON string body -- callers pass a
     * short fixed literal (e.g. "route_task"), not arbitrary untrusted
     * text, so this deliberately does not implement general JSON string
     * escaping (matching this UDF's "payload_json is opaque, unvalidated
     * text" posture above -- adding partial escaping for the type field
     * only would be a false safety signal, not real JSON safety). */
    int n = snprintf(buf, buflen, "{\"type\":\"%.*s\",\"entry\":%.*s}",
                     (int) type_len, type_s, (int) payload_len, payload);
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
