/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * tests/fuzz/fuzz_parse_index_csv.c - libFuzzer entry point for
 * parse_index_csv() (src/fractalsql_parse.c).
 *
 * Lower external-adversary risk than fuzz_parse_vector_csv.c: this
 * parses the Analytics-tier edge/face vertex-index arguments, SQL-
 * caller-supplied text -- but it's the same hand-rolled scan-and-grow
 * technique (strtoll instead of strtod), worth the same hardening as
 * defense-in-depth.
 *
 * Build/run: see build_test.sh's fuzz gate ("30 fuzz_smoke") -- do not
 * invoke this file's compile line by hand except for local iteration.
 *   clang -std=c99 -O1 -g -fsanitize=fuzzer,address \
 *         -Isrc \
 *         src/fractalsql_parse.c tests/fuzz/fuzz_parse_index_csv.c \
 *         -o fuzz_parse_index_csv
 *   ./fuzz_parse_index_csv -max_total_time=30 \
 *         tests/fuzz/corpus_parse_index_csv/
 */
#include "fractalsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define FUZZ_ERRMSG_SIZE 512

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    size_t *out = NULL;
    size_t  n_out = 0;
    char    errmsg[FUZZ_ERRMSG_SIZE];

    if (size == 0)
        return 0;

    if (parse_index_csv((const char *) data, size, &out, &n_out, errmsg))
        free(out);
    return 0;
}
