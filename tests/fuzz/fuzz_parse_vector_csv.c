/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * tests/fuzz/fuzz_parse_vector_csv.c - libFuzzer entry point for
 * parse_vector_csv() (src/fractalsql_parse.c).
 *
 * Highest-priority fuzz target in this repo: this is the parser that
 * runs on fractal_embed()'s raw, unvalidated response from whatever
 * embedding endpoint FRACTALSQL_HTTP_EMBED_URL points at (see
 * src/fractalsql_cognition.c's fractal_embed(), which calls this on
 * resp.summary after fsql_dispatch_ai returns) -- a malicious or
 * merely buggy third-party HTTP provider fully controls these bytes.
 * It is also called on every fractal_search()/fractal_explore() query
 * argument and each corpus row (via parse_corpus, fuzzed separately),
 * SQL-caller-supplied text with a different, lower-privilege threat
 * model but the identical parser underneath.
 *
 * Build/run: see build_test.sh's fuzz gate ("30 fuzz_smoke") -- do not
 * invoke this file's compile line by hand except for local iteration;
 * the gate is the source of truth for flags.
 *   clang -std=c99 -O1 -g -fsanitize=fuzzer,address \
 *         -Isrc \
 *         src/fractalsql_parse.c tests/fuzz/fuzz_parse_vector_csv.c \
 *         -o fuzz_parse_vector_csv
 *   ./fuzz_parse_vector_csv -max_total_time=30 \
 *         tests/fuzz/corpus_parse_vector_csv/
 */
#include "fractalsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/* Matches mysql.h's MYSQL_ERRMSG_SIZE (512) -- see fractalsql_parse.c's
 * own local copy of this same constant for why it isn't #included from
 * mysql.h directly. */
#define FUZZ_ERRMSG_SIZE 512

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    double *out = NULL;
    size_t  n_out = 0;
    char    errmsg[FUZZ_ERRMSG_SIZE];

    if (size == 0)
        return 0;

    /* parse_vector_csv takes an explicit length, not a NUL-terminated
     * string (its real callers pass args->args[N]/args->lengths[N]
     * straight from the UDF ABI, which is not NUL-terminated) -- feed
     * the raw fuzz bytes directly, no copy/terminate step needed. */
    if (parse_vector_csv((const char *) data, size, &out, &n_out, errmsg))
        free(out);
    return 0;
}
