/* src/fractalsql_parse.h - shared vector-text parsers.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * parse_vector_csv is fractalsql.c's own vector-text convention
 * (CSV "1,2,3" or bracketed-JSON "[1,2,3]"), used for fractal_sfs_converge's
 * query_csv and each corpus row. fractal_vector_* adopts the exact
 * same convention for its JSON-array-string representation, rather
 * than inventing a second parser with subtly different edge-case
 * behavior. Defined in fractalsql_parse.c, a standalone TU with no
 * <mysql.h> dependency, so both fractalsql.c and fractalsql_vector.c
 * share one implementation (a parser bug fix lands once, not twice) and
 * so tests/fuzz's libFuzzer drivers can link it without a MariaDB dev
 * package at all.
 */
#ifndef FRACTALSQL_PARSE_H
#define FRACTALSQL_PARSE_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Parses a single vector from CSV ("1,2,3") or bracketed-JSON
 * ("[1,2,3]") text into a newly malloc'd double array (caller frees
 * *out). On success, *n_out > 0 (an empty vector is rejected). On
 * failure, writes a human-readable message into errmsg (caller-
 * allocated, >= MYSQL_ERRMSG_SIZE bytes) and returns false. */
bool parse_vector_csv(const char *src, size_t srclen,
                      double **out, size_t *n_out, char *errmsg);

/* Parses fractal_sfs_converge's corpus argument: rows separated by ';' or (in
 * bracketed-JSON mode) by top-level '[', each row parsed via
 * parse_vector_csv. expected_dim of 0 means "infer from the first row";
 * a nonzero value enforces every row (and the first) matches it. An
 * empty/whitespace-only corpus is accepted (*n_rows_out = 0), not an
 * error. Caller frees *out. */
bool parse_corpus(const char *src, size_t srclen, size_t expected_dim,
                  double **out, size_t *n_rows_out, size_t *dim_out, char *errmsg);

/* Parses a CSV or bracketed-JSON string of non-negative integers (the
 * Analytics-tier edge/face vertex-index arguments). Caller frees *out. */
bool parse_index_csv(const char *src, size_t srclen,
                     size_t **out, size_t *n_out, char *errmsg);

/* Split text into chunks of at most `size` characters (code points) and write a malloc'd JSON array of {"no","start","end","text"} to *out
 * (free() it). mode: 0 fixed, 1 paragraph, 2 sentence. The same algorithm, with the same output, runs in every FractalSQL host; see
 * docs/api-analytics.md. Returns 0, or 1 when more than 100000 chunks would be produced, or -1 on out of memory. size must be 1..100000 and
 * overlap 0..size-1 (the caller checks). */
#define FSQL_CHUNK_MAX_SIZE   100000
#define FSQL_CHUNK_MAX_CHUNKS 100000
int fsql_chunk_text(const unsigned char *t, size_t blen, long size, long overlap, int mode, char **out);

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_PARSE_H */
