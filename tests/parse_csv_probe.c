/* tests/parse_csv_probe.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Standalone unit test for src/fractalsql_parse.c's three parsers:
 * parse_vector_csv(), parse_corpus(), and parse_index_csv().
 *
 * Why this probe exists: parse_vector_csv runs on fractal_embed()'s raw,
 * unvalidated HTTP response body -- whatever text the configured
 * embeddings endpoint returned -- which is the one genuinely
 * externally-adversarial input in this codebase. parse_corpus and
 * parse_index_csv see SQL-caller-supplied text (fractal_search's corpus
 * argument, the Analytics-tier edge/face index arguments). All three
 * have error branches (a malformed number, a non-finite element, a
 * negative index, a row whose dimension disagrees with its siblings) that
 * a plain end-to-end gate never reaches, because every realistic caller
 * feeds them well-formed text.
 *
 * Same standalone-probe treatment as this repo's other fixture
 * compiles (tests/think_reasoning_plugin.c, tests/slow_reasoning_plugin.c):
 * built from the repo root so the recorded source path for
 * src/fractalsql_parse.c matches the main build's own, merging into its
 * coverage rather than duplicating.
 *
 * The parsers live in a TU with no <mysql.h> dependency on purpose (see
 * src/fractalsql_parse.c's own header comment), so this probe links it
 * with no MariaDB dev package at all.
 */
#include "../src/fractalsql_parse.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failed = 0;

static void check(const char *label, int cond) {
    if (cond) {
        printf("OK: %s\n", label);
    } else {
        failed = 1;
        printf("FAIL: %s\n", label);
    }
}

#define ERRLEN 512

static void test_vector_csv(void) {
    double *v = NULL;
    size_t  n = 0;
    char    err[ERRLEN];

    /* --- the happy paths --- */
    err[0] = '\0';
    check("vector_csv: plain CSV parses 3 values",
          parse_vector_csv("1,2,3", 5, &v, &n, err) && n == 3
          && v[0] == 1.0 && v[1] == 2.0 && v[2] == 3.0);
    free(v); v = NULL;

    err[0] = '\0';
    check("vector_csv: bracketed JSON parses 3 values",
          parse_vector_csv("[1.0,2.0,3.0]", 13, &v, &n, err) && n == 3
          && v[0] == 1.0 && v[1] == 2.0 && v[2] == 3.0);
    free(v); v = NULL;

    err[0] = '\0';
    check("vector_csv: surrounding whitespace and newlines are ignored",
          parse_vector_csv("  1.5 , 2.5 \n 3.5  ", 20, &v, &n, err) && n == 3
          && v[0] == 1.5 && v[1] == 2.5 && v[2] == 3.5);
    free(v); v = NULL;

    err[0] = '\0';
    check("vector_csv: a negative and an exponent value both parse",
          parse_vector_csv("-1.5,1e3", 9, &v, &n, err) && n == 2
          && v[0] == -1.5 && v[1] == 1000.0);
    free(v); v = NULL;

    /* --- the rejections ---
     * NOTE: on a failure these parsers write the message and return
     * false; they do NOT promise to zero *n_out (the out-count is only
     * meaningful on success, and the callers all treat a false return as
     * "ignore the outputs entirely"). So the assertions below check the
     * message and the false return, never the count. */
    err[0] = '\0';
    v = NULL;
    check("vector_csv: an empty vector is rejected",
          !parse_vector_csv("", 0, &v, &n, err)
          && strstr(err, "at least one element") != NULL);

    err[0] = '\0';
    v = NULL;
    check("vector_csv: whitespace-only input is rejected",
          !parse_vector_csv("   \n\t ", 6, &v, &n, err)
          && strstr(err, "at least one element") != NULL);

    err[0] = '\0';
    v = NULL;
    check("vector_csv: a non-numeric element is rejected with a message "
          "naming the offending text",
          !parse_vector_csv("1.0,not-a-number,3.0", 18, &v, &n, err)
          && strstr(err, "invalid number") != NULL
          && strstr(err, "not-a-number") != NULL);

    err[0] = '\0';
    v = NULL;
    check("vector_csv: 'inf' is rejected (strtod accepts it without ERANGE, "
          "but it would flow out as [inf,...])",
          !parse_vector_csv("1.0,inf", 8, &v, &n, err)
          && strstr(err, "non-finite") != NULL);

    err[0] = '\0';
    v = NULL;
    check("vector_csv: 'nan' is rejected",
          !parse_vector_csv("nan", 3, &v, &n, err)
          && strstr(err, "non-finite") != NULL);

    err[0] = '\0';
    v = NULL;
    check("vector_csv: a value out of double range is rejected",
          !parse_vector_csv("1e400", 5, &v, &n, err)
          && strstr(err, "out of range") != NULL);

    err[0] = '\0';
    v = NULL;
    check("vector_csv: a trailing garbage element is rejected",
          !parse_vector_csv("1.0,2.0,x", 9, &v, &n, err)
          && strstr(err, "invalid number") != NULL);
}

static void test_corpus(void) {
    double *store = NULL;
    size_t  n_rows = 0, dim = 0;
    char    err[ERRLEN];

    /* --- the happy paths --- */
    err[0] = '\0';
    check("corpus: semicolon-separated rows parse with the inferred dim",
          parse_corpus("1,2;3,4", 7, 0, &store, &n_rows, &dim, err)
          && n_rows == 2 && dim == 2
          && store[0] == 1.0 && store[1] == 2.0
          && store[2] == 3.0 && store[3] == 4.0);
    free(store); store = NULL;

    err[0] = '\0';
    check("corpus: bracketed-JSON rows parse",
          parse_corpus("[[1,2],[3,4]]", 12, 0, &store, &n_rows, &dim, err)
          && n_rows == 2 && dim == 2
          && store[0] == 1.0 && store[1] == 2.0
          && store[2] == 3.0 && store[3] == 4.0);
    free(store); store = NULL;

    err[0] = '\0';
    check("corpus: a nonzero expected_dim is enforced, not inferred",
          parse_corpus("1,2,3", 5, 3, &store, &n_rows, &dim, err)
          && n_rows == 1 && dim == 3 && store[0] == 1.0);
    free(store); store = NULL;

    err[0] = '\0';
    check("corpus: an empty corpus is accepted as zero rows, not an error",
          parse_corpus("   ", 3, 0, &store, &n_rows, &dim, err)
          && n_rows == 0 && store == NULL);

    err[0] = '\0';
    check("corpus: a bracketed-but-empty corpus is accepted as zero rows",
          parse_corpus("[]", 2, 0, &store, &n_rows, &dim, err)
          && n_rows == 0);

    /* --- the rejections --- */
    err[0] = '\0';
    store = NULL;
    check("corpus: a row whose dimension disagrees with the first is "
          "rejected, naming the row and both dims",
          !parse_corpus("1,2;3,4,5", 9, 0, &store, &n_rows, &dim, err)
          && strstr(err, "row 1") != NULL
          && strstr(err, "dim 3") != NULL
          && strstr(err, "expected 2") != NULL);

    err[0] = '\0';
    store = NULL;
    check("corpus: a row that disagrees with a nonzero expected_dim is "
          "rejected",
          !parse_corpus("1,2,3", 5, 2, &store, &n_rows, &dim, err)
          && strstr(err, "expected 2") != NULL);

    err[0] = '\0';
    store = NULL;
    check("corpus: a malformed element inside one row rejects the whole "
          "corpus",
          !parse_corpus("1,2;oops,4", 9, 0, &store, &n_rows, &dim, err)
          && strstr(err, "invalid number") != NULL);
}

static void test_index_csv(void) {
    size_t *v = NULL;
    size_t  n = 0;
    char    err[ERRLEN];

    /* --- the happy paths --- */
    err[0] = '\0';
    check("index_csv: plain CSV parses 3 indices",
          parse_index_csv("0,1,2", 5, &v, &n, err) && n == 3
          && v[0] == 0 && v[1] == 1 && v[2] == 2);
    free(v); v = NULL;

    err[0] = '\0';
    check("index_csv: bracketed JSON parses 3 indices",
          parse_index_csv("[10,20,30]", 10, &v, &n, err) && n == 3
          && v[0] == 10 && v[1] == 20 && v[2] == 30);
    free(v); v = NULL;

    err[0] = '\0';
    check("index_csv: an empty index array is accepted as zero indices",
          parse_index_csv("", 0, &v, &n, err) && n == 0);

    /* --- the rejections --- */
    err[0] = '\0';
    v = NULL;
    check("index_csv: a negative index is rejected outright (a negative "
          "index would read out of bounds downstream)",
          !parse_index_csv("-1,2", 4, &v, &n, err)
          && strstr(err, "non-negative") != NULL);

    err[0] = '\0';
    v = NULL;
    check("index_csv: a non-integer element is rejected",
          !parse_index_csv("1,x,3", 5, &v, &n, err)
          && strstr(err, "invalid index") != NULL);

    err[0] = '\0';
    v = NULL;
    check("index_csv: a fractional value is rejected, not truncated",
          !parse_index_csv("1,2.5", 5, &v, &n, err)
          && strstr(err, "invalid index") != NULL);

    err[0] = '\0';
    v = NULL;
    check("index_csv: a value beyond the size_t range is rejected",
          !parse_index_csv("99999999999999999999999999", 26, &v, &n, err)
          && strstr(err, "out of range") != NULL);
}

int main(void) {
    test_vector_csv();
    test_corpus();
    test_index_csv();
    return failed ? 1 : 0;
}
