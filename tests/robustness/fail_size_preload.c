/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic allocation failure: LD_PRELOAD this and malloc(FSQL_FAIL_SIZE) from the executable itself returns NULL, every time,
 * and nothing else is touched. The frame-authentication test uses it to fail exactly the buffer mac() allocates for one chosen
 * payload size. Used only by build_test.sh; never shipped.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdint.h>
#include <stdlib.h>

static void *(*real_malloc)(size_t);
static size_t want;
static uintptr_t exe_lo, exe_hi;

static int find_exe(struct dl_phdr_info *i, size_t sz, void *d)
{
    (void) sz; (void) d;
    for (int k = 0; k < i->dlpi_phnum; k++)
        if (i->dlpi_phdr[k].p_type == PT_LOAD && (i->dlpi_phdr[k].p_flags & PF_X)) {
            exe_lo = i->dlpi_addr + i->dlpi_phdr[k].p_vaddr;
            exe_hi = exe_lo + i->dlpi_phdr[k].p_memsz;
        }
    return 1;
}

__attribute__((constructor)) static void init(void)
{
    const char *s = getenv("FSQL_FAIL_SIZE");
    want = s ? (size_t) strtoull(s, NULL, 10) : 0;
    real_malloc = (void *(*)(size_t)) dlsym(RTLD_NEXT, "malloc");
    dl_iterate_phdr(find_exe, NULL);
}

void *malloc(size_t n)
{
    if (!real_malloc) {
        real_malloc = (void *(*)(size_t)) dlsym(RTLD_NEXT, "malloc");
        if (!real_malloc) return NULL;
    }
    if (want && n == want) {
        uintptr_t ra = (uintptr_t) __builtin_return_address(0);
        if (ra >= exe_lo && ra < exe_hi) return NULL;
    }
    return real_malloc(n);
}
