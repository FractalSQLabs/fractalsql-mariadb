/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * tests/fuzz/fuzz_parse_corpus.c - libFuzzer entry point for
 * parse_corpus() (src/fractalsql_parse.c).
 *
 * Lower external-adversary risk than fuzz_parse_vector_csv.c: this
 * parses fractal_search()'s corpus argument, SQL-caller-supplied text,
 * not a third-party HTTP response -- but it builds directly on
 * parse_vector_csv's own buffer-growth logic plus its own bracket/
 * semicolon row-splitting scan, worth the same hardening as
 * defense-in-depth.
 *
 * Build/run: see build_test.sh's fuzz gate ("30 fuzz_smoke") -- do not
 * invoke this file's compile line by hand except for local iteration.
 *   clang -std=c99 -O1 -g -fsanitize=fuzzer,address \
 *         -Isrc \
 *         src/fractalsql_parse.c tests/fuzz/fuzz_parse_corpus.c \
 *         -o fuzz_parse_corpus
 *   ./fuzz_parse_corpus -max_total_time=30 \
 *         tests/fuzz/corpus_parse_corpus/
 */
#include "fractalsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define FUZZ_ERRMSG_SIZE 512

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    double *out = NULL;
    size_t  n_rows = 0, dim = 0;
    char    errmsg[FUZZ_ERRMSG_SIZE];

    if (size == 0)
        return 0;

    /* expected_dim=0: "infer from the first row", the real call sites'
     * default when the corpus's own dimension isn't already known
     * (fractal_search's first argument). This exercises the widest
     * range of the dim-mismatch-rejection path across rows. */
    if (parse_corpus((const char *) data, size, 0, &out, &n_rows, &dim, errmsg))
        free(out);
    return 0;
}
