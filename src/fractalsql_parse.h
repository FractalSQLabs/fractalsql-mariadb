/* src/fractalsql_parse.h - shared vector-text parser.
 *
 * parse_vector_csv is fractalsql.c's own vector-text convention
 * (CSV "1,2,3" or bracketed-JSON "[1,2,3]"), used for fractal_search's
 * query_csv and each corpus row. fractal_vector_* adopts the exact
 * same convention for its JSON-array-string representation, rather
 * than inventing a second parser with subtly different edge-case
 * behavior. Declared here (defined in fractalsql.c) so both
 * translation units share one implementation, so a parser bug fix
 * lands once, not twice.
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

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_PARSE_H */
