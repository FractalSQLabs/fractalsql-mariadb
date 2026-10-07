/* tests/oom_preload.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * LD_PRELOAD fault-injection shim for gate 37 (OOM injection against
 * fractalsqld). Wraps malloc/calloc/realloc/strdup: the Nth allocation
 * call across the process's whole lifetime (counting from 1) fails
 * (returns NULL; for realloc, the original block is left untouched,
 * per realloc(3)'s own failure contract) instead of succeeding. Every
 * other allocation passes through to the real allocator unchanged.
 *
 * N is read ONCE from FSQL_OOM_FAIL_AT, at load time (a constructor),
 * not armed via an in-process function call the way a shim driven by
 * a test binary linked into the SAME process would be. This shim runs
 * inside fractalsqld, a separate OS process gate 37's driver restarts
 * fresh per trial specifically so each (UDF, N) pair gets a clean
 * allocation count to fail at -- there is no arm()/disarm() call
 * reaching across that process boundary. FSQL_OOM_FAIL_AT unset,
 * empty, or <= 0 disables injection entirely (pure passthrough; this
 * is NOT the shim gate 37 uses for its own non-fault control-group
 * baseline runs, see that gate's own comment for why those don't use
 * this shim at all).
 *
 * Every LD_PRELOAD allocator shim needs the same two things this one
 * has: real_malloc/etc. resolved LAZILY (a constructor can't safely
 * call dlsym for them, because dlsym/the dynamic linker's own startup
 * work may itself need to allocate before our constructor has even
 * run, let alone before dlsym(RTLD_NEXT, "malloc") has returned --
 * calling our own malloc() from inside that resolution would recurse
 * into dlsym again, forever); and a small preinit scratch buffer to
 * satisfy any allocation that lands before the real allocator has been
 * resolved, so that *first* call has somewhere else to get memory from.
 *
 * Build: cc -O2 -fPIC -shared -o oom_preload.so tests/oom_preload.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static void *(*real_malloc)(size_t)          = NULL;
static void *(*real_calloc)(size_t, size_t)  = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;

#define PREINIT_CAP (64u * 1024u)
static unsigned char preinit_buf[PREINIT_CAP];
static size_t        preinit_off = 0;

static void *
preinit_alloc(size_t n)
{
    size_t aligned = (preinit_off + 15u) & ~(size_t) 15u;
    if (aligned + n > PREINIT_CAP) return NULL;
    void *p = preinit_buf + aligned;
    preinit_off = aligned + n;
    return p;
}

static int
is_preinit_ptr(const void *p)
{
    return (const unsigned char *) p >= preinit_buf &&
           (const unsigned char *) p <  preinit_buf + PREINIT_CAP;
}

static long g_fail_at = 0;   /* 0 = injection disabled (pure passthrough) */
static long g_count   = 0;

__attribute__((constructor))
static void
oom_preload_init(void)
{
    const char *v = getenv("FSQL_OOM_FAIL_AT");
    if (v && *v) {
        long n = strtol(v, NULL, 10);
        if (n > 0) g_fail_at = n;
    }
}

/* Counts this call; true on exactly the Nth one (N = FSQL_OOM_FAIL_AT).
 * Every call that reaches here -- including ones that will go on to
 * pass through -- still counts, so the Nth allocation ACROSS THE WHOLE
 * PROCESS is what fails, not the Nth call to any one specific wrapper. */
static int
should_fail(void)
{
    if (g_fail_at <= 0) return 0;
    long c = __atomic_add_fetch(&g_count, 1, __ATOMIC_SEQ_CST);
    return c == g_fail_at;
}

void *
malloc(size_t size)
{
    if (real_malloc == NULL) {
        real_malloc = (void *(*)(size_t)) dlsym(RTLD_NEXT, "malloc");
        if (real_malloc == NULL) return preinit_alloc(size);
    }
    if (should_fail()) return NULL;
    return real_malloc(size);
}

void *
calloc(size_t nmemb, size_t size)
{
    if (real_calloc == NULL) {
        real_calloc = (void *(*)(size_t, size_t)) dlsym(RTLD_NEXT, "calloc");
        if (real_calloc == NULL) {
            void *p = preinit_alloc(nmemb * size);
            if (p) memset(p, 0, nmemb * size);
            return p;
        }
    }
    if (should_fail()) return NULL;
    return real_calloc(nmemb, size);
}

void *
realloc(void *ptr, size_t size)
{
    if (real_realloc == NULL) {
        real_realloc = (void *(*)(void *, size_t)) dlsym(RTLD_NEXT, "realloc");
        if (real_realloc == NULL) return preinit_alloc(size);
    }
    if (is_preinit_ptr(ptr)) {
        /* A pointer our own preinit_alloc handed out before the real
         * allocator resolved: the real realloc() has never heard of
         * it, so grow by copy instead of passing it through. Only the
         * handful of allocations made before our own resolution
         * completes ever take this path. */
        void *p = real_realloc(NULL, size);
        if (p && ptr) memcpy(p, ptr, size);
        return p;
    }
    if (should_fail()) return NULL;   /* `ptr` is left valid, per realloc(3) */
    return real_realloc(ptr, size);
}

char *
strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    /* Through our own malloc(), not real_malloc() directly: one
     * counted allocation, same as every other wrapper here, so a
     * strdup lands in the same N-th-allocation-wide numbering the
     * test driver sweeps rather than a separate, uncounted one. */
    char *p = (char *) malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}
