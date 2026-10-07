/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Cooperative-cancel seam checks: no daemon, no MariaDB. Links only
 * ../src/fractalsql_parse.c and ../src/fractalsql_interrupt.c, installs an
 * interrupt hook, and confirms the parser poll points stop the parse with
 * the "fractalsql: interrupted" message when the hook fires -- and parse
 * unchanged when it doesn't.
 *
 * Mirrors the frame_test conventions (PASS/FAIL lines, exit 1 on failure).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql_parse.h"
#include "fractalsql_interrupt.h"

/* Fake hook: counts polls, starts reporting "interrupted" once g_calls
 * reaches g_fire_at (g_fire_at = -1 disables firing, though polls still
 * count). A real host's hook reads a cancel flag; this one makes the poll
 * count deterministic. */
static int g_calls = 0;
static int g_fire_at = -1;
static int counting_hook(void) {
    g_calls++;
    return g_fire_at > 0 && g_calls >= g_fire_at;
}

static int g_fails = 0;
static void check(int cond, const char *what) {
    if (cond) printf("  [PASS] %s\n", what);
    else { printf("  [FAIL] %s\n", what); g_fails++; }
}

int main(void) {
    char msg[512];
    double *v = NULL;
    size_t n = 0;

    /* No hook installed: the poll is a no-op, even though the parser is
     * about to call it at every element boundary. */
    check(fractalsql_interrupt_poll() == 0, "poll with no hook installed returns 0");

    fractalsql_interrupt_hook_set(counting_hook);

    /* The hook fires at the 3rd poll, so a 5-element CSV parse must stop
     * partway with the interrupted message and free its partial values. */
    g_calls = 0; g_fire_at = 3;
    check(!parse_vector_csv("1,2,3,4,5", 9, &v, &n, msg) && v == NULL && n == 0
              && strstr(msg, "interrupted") != NULL,
          "parse_vector_csv aborts with \"fractalsql: interrupted\" when the hook fires");
    check(g_calls == 3, "the CSV parser polls exactly once per element");

    /* Same input with a hook that never fires: the parse completes. */
    g_calls = 0; g_fire_at = -1;
    v = NULL;
    check(parse_vector_csv("[1,2,3,4,5]", 11, &v, &n, msg) && n == 5 && g_calls >= 5,
          "the CSV parser still parses when the hook never fires");
    free(v); v = NULL; n = 0;

    /* A hook that reports "not interrupted" every time is equivalent to no
     * hook: disabling it must not change any parse outcome. */
    fractalsql_interrupt_hook_set(NULL);
    g_calls = 0;
    check(parse_vector_csv("1,2,3", 5, &v, &n, msg) && n == 3 && g_calls == 0,
          "a disabled hook is not polled; the parse is unaffected");
    free(v); v = NULL; n = 0;

    /* parse_corpus delegates each row to parse_vector_csv, so its poll
     * budget counts BOTH the per-element polls of every row and its own
     * per-separator polls. With a never-firing budget it parses both rows;
     * a budget of one stops it before any row completes. */
    fractalsql_interrupt_hook_set(counting_hook);
    g_calls = 0; g_fire_at = -1;
    {
        size_t rows = 0, dim = 0;
        bool ok = parse_corpus("[1,2;3,4]", 9, 0, &v, &rows, &dim, msg);
        check(ok && rows == 2 && dim == 2 && g_calls >= 2,
              "parse_corpus with a never-firing budget parses both rows (and polls at the row separators)");
        free(v); v = NULL; rows = 0; dim = 0;
    }
    g_calls = 0; g_fire_at = 1;
    {
        size_t rows = 9, dim = 9;
        check(!parse_corpus("[1,2;3,4]", 9, 0, &v, &rows, &dim, msg)
                  && v == NULL && strstr(msg, "interrupted") != NULL,
              "parse_corpus aborts with \"fractalsql: interrupted\" when the budget fires");
    }

    printf("  interrupt seam: hook poll semantics and both parser seams checked\n");
    fractalsql_interrupt_hook_set(NULL);

    printf("%s: %d failed\n", "interrupt_test", g_fails);
    return g_fails ? 1 : 0;
}