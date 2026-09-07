/* src/fractalsql_parse.h - shared vector-text parsers.
 *
 * parse_vector_csv is fractalsql.c's own vector-text convention
 * (CSV "1,2,3" or bracketed-JSON "[1,2,3]"), used for fractal_search's
 * query_csv and each corpus row. fractal_vector_* adopts the exact
 * same convention for its JSON-array-string representation, rather
 * than inventing a second parser with subtly different edge-case
 * behavior. Defined in fractalsql_parse.c, a standalone TU with no
 * <mysql.h> dependency, so both fractalsql.c and fractalsql_vector.c
 * share one implementation (a parser bug fix lands once, not twice) and
 * so tests/fuzz's libFuzzer drivers can link it without a MariaDB dev
 * package at all -- see build_test.sh's gate 21.
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

/* Parses fractal_search's corpus argument: rows separated by ';' or (in
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

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_PARSE_H */
