/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * service/tests/ledger_concurrency_runner.c
 *
 * The concurrent-ledger-write driver behind build_test.sh's gate 46
 * (a --tsan-only gate; see the plan doc's gate table).
 *
 * WHY A STANDALONE RUNNER AND NOT "N CLIENTS AGAINST THE DAEMON":
 *
 * The ledger in this product is a FILE, not a database table. Every
 * kind=2 append goes through
 *
 *     fractal_ledger_write_kind2()          (src/fractalsql_enterprise.c)
 *       -> ledger_write_entry()
 *            -> ent_lock()                  (g_ent_lock)
 *            -> read the chain head, link the new record to it,
 *               hash, append, fsync
 *            -> ent_unlock()
 *
 * g_ent_lock is a single process-wide mutex (a Win32 CRITICAL_SECTION,
 * a pthread_mutex_t on POSIX), so the interesting race is INTRA-PROCESS:
 * N client connections become N worker threads inside ONE fractalsqld
 * process, and every one of them appends to the same chain. That is
 * exactly what this runner reproduces -- N threads, one process, one
 * ledger file -- and it is also the only shape that can be run under
 * ThreadSanitizer at all: TSan instruments a process, so a
 * client-against-daemon test would put the races in the DAEMON's
 * address space, which is a different (and much heavier) test than the
 * one the ledger lock needs.
 *
 * WHAT IS UNDER TEST:
 *
 * The runner links the SAME adapter objects the daemon links
 * (service/Makefile's ADAPTER_OBJS -- there is no separate "ledger
 * library" in this project), so the code being hammered is the shipped
 * code, not a copy of it. It is compiled with the same
 * $(FSQ_SAN_FLAGS) as the daemon, which is what makes the --tsan build
 * meaningful.
 *
 * WHAT IT PROVES:
 *
 *   1. No data race on the ledger's shared state. TSan reports a race
 *      as a WARNING and (with halt_on_error=1) kills the process; the
 *      gate greps for that. This is the primary assertion.
 *   2. The chain is still a chain: every record's prev_hash equals its
 *      predecessor's entry_hash, and every entry_hash recomputes from
 *      (prev_hash || payload || mac).
 *   3. Every record's MAC recomputes from the ledger key.
 *   4. Nothing was lost and nothing was duplicated: the file holds
 *      exactly threads*iters records, one per (thread, iteration)
 *      pair. A lost append means a torn chain; a duplicated one means
 *      the link was computed against a stale head.
 *   5. The CSV mirror gained exactly one row per append. The mirror is
 *      best-effort by design, but a row-count mismatch under a
 *      writable path means the mirror and the chain have diverged --
 *      which is the failure mode the mirror exists to make visible.
 *
 * USAGE:
 *
 *   ledger_concurrency_runner <ledger_path> [threads] [iterations]
 *
 * The runner sets FRACTALSQL_ENTERPRISE_LEDGER_PATH to <ledger_path>
 * and FRACTALSQL_ENTERPRISE_LEDGER_KEY to a fixed test key, so the
 * keyed (HMAC) path is exercised rather than the unkeyed one. The
 * enterprise tier's own library is NOT loaded and is not needed: the
 * append itself goes through the community-side storage layer, and
 * fractal_ledger_write_kind2() is not gated behind the tier (the
 * product-tier gate lives on the SQL UDF fractal_audit_log, which
 * needs a live MariaDB session -- see src/fractalsql_enterprise.c).
 *
 * EXIT CODES: 0 = every check passed, 1 = a check failed, 2 = usage
 * or I/O error.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <time.h>

#include "fractalsql_enterprise.h"   /* fractal_ledger_write_kind2() */
#include "fractalsql_hmac.h"          /* fsql_sha256 / fsql_hmac_sha256 */

/* On-disk format, mirrored from src/fractalsql_enterprise.c:
 *
 *   file header : "FSQLLDGR" (8 bytes) + version byte (1 byte)
 *   record      : kind u32 | blen u32 | has_mac u8 | sealed u8
 *                 | reserved[2] | mac[32] | prev_hash[32]
 *                 | entry_hash[32] | updated i64 | payload[blen]
 *
 * The multi-byte fields are written with fwrite() of the host's own
 * uint32_t/int64_t, so the reader below memcpy()s them back into the
 * same types -- endianness-agnostic by construction, no byte-order
 * guesswork baked into a test.
 */
#define LEDGER_MAGIC     "FSQLLDGR"
#define LEDGER_MAGIC_LEN 8
#define LEDGER_VERSION   1
#define LEDGER_HASH_LEN  32
#define LEDGER_HDR_LEN   (LEDGER_MAGIC_LEN + 1)
#define LEDGER_REC_FIXED 116

/* The key the runner installs. Any non-empty string works; a fixed one
 * keeps the MAC recomputation in the verifier reproducible. */
#define RUNNER_LEDGER_KEY "fractalsql-gate46-ledger-key"

static int g_failures = 0;

static void
check(int ok, const char *what)
{
    if (ok)
    {
        printf("  ok   %s\n", what);
    }
    else
    {
        printf("  FAIL %s\n", what);
        g_failures++;
    }
}

static void
set_env(const char *key, const char *val)
{
#if defined(_WIN32)
    _putenv_s(key, val);
#else
    setenv(key, val, 1);
#endif
}

/* ------------------------------------------------------------------ */
/* the writer side                                                     */
/* ------------------------------------------------------------------ */

typedef struct {
    int      thread_id;
    int      iters;
    int      writes;
    int      errors;
} worker_arg;

/* The payload is a fixed-shape JSON object, deliberately simple: the
 * verifier parses it back with sscanf() to prove that every (thread,
 * iteration) pair landed in the file exactly once. */
static void *
worker_main(void *p)
{
    worker_arg *a = (worker_arg *) p;
    char        buf[256];
    int         i;

    for (i = 0; i < a->iters; i++)
    {
        int n = snprintf(buf, sizeof buf,
                         "{\"type\":\"tsan-ledger-canary\",\"entry\":{\"thread\":%d,\"iter\":%d}}",
                         a->thread_id, i);
        if (n < 0 || (size_t) n >= sizeof buf)
        {
            a->errors++;
            continue;
        }
        if (fractal_ledger_write_kind2(buf, (size_t) n) != FSQL_OK)
            a->errors++;
        else
            a->writes++;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* the reader side                                                     */
/* ------------------------------------------------------------------ */

static uint8_t *
read_whole_file(const char *path, size_t *out_len)
{
    FILE   *f;
    long    sz;
    uint8_t *buf;
    size_t  got;

    f = fopen(path, "rb");
    if (f == NULL) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    buf = (uint8_t *) malloc((size_t) sz + 1);
    if (buf == NULL) { fclose(f); return NULL; }
    got = fread(buf, 1, (size_t) sz, f);
    fclose(f);
    *out_len = got;
    return buf;
}

/* Counts the newline-terminated rows in the CSV mirror. The mirror has
 * no header row: ledger_csv_next_id() seeds the first row's id at 1,
 * so the row count is the record count. */
static long
count_csv_rows(const char *path)
{
    FILE *f;
    long  n = 0;
    int   c;

    f = fopen(path, "rb");
    if (f == NULL) return -1;
    while ((c = fgetc(f)) != EOF) if (c == '\n') n++;
    fclose(f);
    return n;
}

static uint32_t
le32(const uint8_t *p)
{
    uint32_t v;
    memcpy(&v, p, sizeof v);
    return v;
}

/* The (thread, iteration) pairs seen so far, as a growable pair of
 * arrays. A bitmap would be faster, but its size would have to be
 * fixed up front from the thread/iteration counts -- which the
 * --verify-only mode does not know (it is checking a ledger written
 * elsewhere). A growable array works for both modes and, at the
 * record counts involved (hundreds to a few thousand), a linear
 * duplicate scan costs nothing.
 *
 * Returns 1 = added, 0 = duplicate, -1 = out of memory. */
static int
seen_add(int **ts, int **its, long *n, long *cap, int t, int it)
{
    long i;

    for (i = 0; i < *n; i++)
        if ((*ts)[i] == t && (*its)[i] == it) return 0;

    if (*n == *cap)
    {
        long ncap = (*cap == 0) ? 64 : (*cap * 2);
        int *nt = (int *) realloc(*ts, (size_t) ncap * sizeof **ts);
        if (nt == NULL) return -1;
        *ts = nt;
        int *ni = (int *) realloc(*its, (size_t) ncap * sizeof **its);
        if (ni == NULL) return -1;
        *its = ni;
        *cap = ncap;
    }
    (*ts)[*n] = t;
    (*its)[*n] = it;
    (*n)++;
    return 1;
}

static int64_t
le64(const uint8_t *p)
{
    int64_t v;
    memcpy(&v, p, sizeof v);
    return v;
}

int
main(int argc, char **argv)
{
    const char   *ledger_path;
    int           threads = 8;
    int           iters   = 25;
    int           verify_only = 0;
    pthread_t    *tids;
    worker_arg   *args;
    uint8_t      *buf;
    size_t        len = 0;
    size_t        off;
    uint8_t       expect_prev[LEDGER_HASH_LEN];
    int          *seen_t, *seen_it;
    long          seen_n = 0, seen_cap = 0;
    long          records = 0;
    int           i;
    int           total_writes = 0;
    int           total_errors = 0;
    int           chain_ok, entry_hash_ok, mac_ok, kind_ok, ts_ok, payload_ok, dup_ok, torn;
    long          keyed = 0;
    char          csv_path[4096];

    /* --verify-only <ledger_path> : walk and check an EXISTING ledger
     * and write nothing. The write phase is the concurrency stress;
     * this mode is the pure verifier, useful for checking a ledger
     * produced elsewhere (and for testing the verifier itself against
     * a deliberately corrupted file). */
    if (argc >= 2 && strcmp(argv[1], "--verify-only") == 0)
    {
        if (argc != 3)
        {
            fprintf(stderr, "usage: %s --verify-only <ledger_path>\n", argv[0]);
            return 2;
        }
        verify_only = 1;
        ledger_path = argv[2];
    }
    else
    {
        if (argc < 2 || argc > 4)
        {
            fprintf(stderr, "usage: %s <ledger_path> [threads] [iterations]\n", argv[0]);
            fprintf(stderr, "       %s --verify-only <ledger_path>\n", argv[0]);
            return 2;
        }
        ledger_path = argv[1];
        if (argc >= 3) threads = atoi(argv[2]);
        if (argc >= 4) iters   = atoi(argv[3]);
        if (threads < 1 || threads > 256) { fprintf(stderr, "threads out of range\n"); return 2; }
        if (iters < 1 || iters > 100000)  { fprintf(stderr, "iterations out of range\n"); return 2; }
    }

    set_env("FRACTALSQL_ENTERPRISE_LEDGER_PATH", ledger_path);
    set_env("FRACTALSQL_ENTERPRISE_LEDGER_KEY", RUNNER_LEDGER_KEY);

    if (verify_only)
    {
        printf("ledger_concurrency_runner: verifying %s\n", ledger_path);
    }
    else
    {
        printf("ledger_concurrency_runner: %d threads x %d iterations -> %s\n",
               threads, iters, ledger_path);
    }

    tids = (pthread_t *) calloc((size_t) threads, sizeof *tids);
    args = (worker_arg *) calloc((size_t) threads, sizeof *args);
    if (tids == NULL || args == NULL) { fprintf(stderr, "out of memory\n"); return 2; }

    for (i = 0; i < threads && !verify_only; i++)
    {
        args[i].thread_id = i;
        args[i].iters     = iters;
        if (pthread_create(&tids[i], NULL, worker_main, &args[i]) != 0)
        {
            fprintf(stderr, "ledger_concurrency_runner: pthread_create failed for thread %d\n", i);
            return 2;
        }
    }
    for (i = 0; i < threads && !verify_only; i++)
    {
        pthread_join(tids[i], NULL);
        total_writes += args[i].writes;
        total_errors += args[i].errors;
    }
    free(tids);

    if (!verify_only)
    {
        check(total_errors == 0, "every append returned FSQL_OK");
        check(total_writes == threads * iters,
              "every append reported a successful write");
    }

    /* --- walk the chain ------------------------------------------- */
    buf = read_whole_file(ledger_path, &len);
    if (buf == NULL)
    {
        fprintf(stderr, "ledger_concurrency_runner: cannot read %s\n", ledger_path);
        free(args);
        return 2;
    }
    check(len >= LEDGER_HDR_LEN, "the ledger file has a header");
    if (len < LEDGER_HDR_LEN)
    {
        free(buf); free(args);
        return 1;
    }
    check(memcmp(buf, LEDGER_MAGIC, LEDGER_MAGIC_LEN) == 0, "the ledger magic is FSQLLDGR");
    check(buf[LEDGER_MAGIC_LEN] == LEDGER_VERSION, "the ledger version byte is 1");

    memset(expect_prev, 0, sizeof expect_prev);
    seen_t = NULL; seen_it = NULL; seen_n = 0; seen_cap = 0;

    /* One aggregated verdict per property, counted across every record:
     * a chain that breaks in the middle should report ONE failure, not
     * one per downstream record (the first break is the real defect --
     * everything after it is a consequence). */
    chain_ok = 1; entry_hash_ok = 1; mac_ok = 1; kind_ok = 1; ts_ok = 1;
    payload_ok = 1; dup_ok = 1; torn = 0; keyed = 0;

    off = LEDGER_HDR_LEN;
    while (off + LEDGER_REC_FIXED <= len)
    {
        const uint8_t *rec = buf + off;
        uint32_t       kind   = le32(rec + 0);
        uint32_t       blen   = le32(rec + 4);
        uint8_t        has_mac = rec[8];
        const uint8_t *mac    = rec + 12;
        const uint8_t *prev   = rec + 44;
        const uint8_t *entry  = rec + 76;
        int64_t        updated = le64(rec + 108);
        const uint8_t *blob;
        uint8_t        want[LEDGER_HASH_LEN];
        size_t         buflen;
        uint8_t       *hbuf;
        int            t = -1, it = -1;

        if (off + LEDGER_REC_FIXED + blen > len)
        {
            torn = 1;
            break;
        }
        blob = rec + LEDGER_REC_FIXED;

        if (memcmp(prev, expect_prev, LEDGER_HASH_LEN) != 0) chain_ok = 0;

        /* entry_hash = SHA256(prev_hash || payload || mac) */
        buflen = (size_t) LEDGER_HASH_LEN + blen + (has_mac ? LEDGER_HASH_LEN : 0);
        hbuf = (uint8_t *) malloc(buflen);
        if (hbuf == NULL) { fprintf(stderr, "out of memory\n"); free(buf); free(args); return 2; }
        memcpy(hbuf, prev, LEDGER_HASH_LEN);
        memcpy(hbuf + LEDGER_HASH_LEN, blob, blen);
        if (has_mac) memcpy(hbuf + LEDGER_HASH_LEN + blen, mac, LEDGER_HASH_LEN);
        fsql_sha256(hbuf, buflen, want);
        free(hbuf);
        if (memcmp(want, entry, LEDGER_HASH_LEN) != 0) entry_hash_ok = 0;

        /* mac = HMAC-SHA256(key, payload) */
        if (has_mac)
        {
            keyed++;
            fsql_hmac_sha256((const uint8_t *) RUNNER_LEDGER_KEY,
                             strlen(RUNNER_LEDGER_KEY), blob, blen, want);
            if (memcmp(want, mac, LEDGER_HASH_LEN) != 0) mac_ok = 0;
        }

        if (kind != 2) kind_ok = 0;
        if (updated <= 0) ts_ok = 0;

        /* The (thread, iteration) identity of this record. */
        {
            char tmp[300];
            size_t n = blen < sizeof tmp - 1 ? blen : sizeof tmp - 1;
            memcpy(tmp, blob, n);
            tmp[n] = '\0';
            if (sscanf(tmp, "{\"type\":\"tsan-ledger-canary\",\"entry\":{\"thread\":%d,\"iter\":%d}}",
                       &t, &it) != 2)
            {
                payload_ok = 0;
            }
            else if (t < 0 || it < 0)
            {
                payload_ok = 0;
            }
            else if (verify_only)
            {
                /* An externally written ledger: any (thread, iteration)
                 * is fine, as long as no pair shows up twice. */
                int rc = seen_add(&seen_t, &seen_it, &seen_n, &seen_cap, t, it);
                if (rc == 0) dup_ok = 0;
                else if (rc < 0) { fprintf(stderr, "out of memory\n"); free(buf); free(args); return 2; }
            }
            else
            {
                if (t >= threads || it >= iters) payload_ok = 0;
                {
                    int rc = seen_add(&seen_t, &seen_it, &seen_n, &seen_cap, t, it);
                    if (rc == 0) dup_ok = 0;
                    else if (rc < 0) { fprintf(stderr, "out of memory\n"); free(buf); free(args); return 2; }
                }
            }
        }

        memcpy(expect_prev, entry, LEDGER_HASH_LEN);
        records++;
        off += LEDGER_REC_FIXED + blen;
    }

    check(!torn, "every record fits inside the file");
    check(keyed > 0, "the keyed (HMAC) path was actually exercised -- the records carry a MAC");
    check(chain_ok, "each record links to its predecessor's entry_hash");
    check(entry_hash_ok, "every entry_hash recomputes from (prev_hash || payload || mac)");
    check(mac_ok, "every record MAC recomputes from the ledger key");
    check(kind_ok, "every record is a kind=2 (decision-audit) entry");
    check(ts_ok, "every record carries a plausible timestamp");
    check(payload_ok, "every record carries a readable canary payload");
    check(dup_ok, "no (thread, iteration) pair is appended twice");
    check(off == len, "the file ends exactly on a record boundary (no torn tail)");
    if (!verify_only)
    {
        check(records == (long) threads * (long) iters,
              "the chain holds exactly threads x iterations records");

        /* Every (thread, iteration) slot must be filled exactly once. */
        {
            long filled = 0;
            long total  = (long) threads * (long) iters;
            long a, b;
            for (a = 0; a < threads; a++)
                for (b = 0; b < iters; b++)
                {
                    long k;
                    for (k = 0; k < seen_n; k++)
                        if (seen_t[k] == (int) a && seen_it[k] == (int) b) { filled++; break; }
                }
            check(filled == total, "no append was lost and none was duplicated");
        }
    }

    /* --- the CSV mirror ------------------------------------------- */
    {
        /* Built by hand rather than with snprintf: the ledger path is
         * unbounded, and a truncating format would be exactly the
         * kind of silent mis-read a test must not make. */
        size_t bl = strlen(ledger_path);
        if (bl + 5 > sizeof csv_path)
        {
            check(0, "the CSV mirror path is short enough to open");
        }
        else
        {
            long rows;
            memcpy(csv_path, ledger_path, bl);
            memcpy(csv_path + bl, ".csv", 5);   /* includes the NUL */
            rows = count_csv_rows(csv_path);
            if (rows < 0)
                check(0, "the CSV mirror exists next to the ledger");
            else
                check(rows == records, "the CSV mirror gained exactly one row per append");
        }
    }

    free(seen_t);
    free(seen_it);
    free(buf);
    free(args);

    if (g_failures != 0)
    {
        printf("ledger_concurrency_runner: %d check(s) FAILED\n", g_failures);
        return 1;
    }
    printf("ledger_concurrency_runner: all checks passed (%ld records)\n", records);
    return 0;
}
