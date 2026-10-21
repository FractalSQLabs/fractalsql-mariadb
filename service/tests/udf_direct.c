/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * service/tests/udf_direct.c
 *
 * Calls the UDF entry points in the adapter objects directly, without a
 * daemon or a database in between, so one process can run thousands of calls
 * and fail a chosen allocation or file call inside each of them.
 *
 * It links the same adapter objects fractalsqld links, so the code under test
 * is the shipped code. Each call follows the daemon's lifecycle: init with the
 * constant argument values visible, the body with a result buffer of
 * max_length + 1 bytes, then deinit.
 *
 * usage: udf_direct PHASE SEEDS.sql [STRIDE]
 *
 *   seed    every call of the seed file once
 *   mutate  each call with one argument at a time replaced by an edge value,
 *           and with the argument list shortened, lengthened or emptied
 *   oom     every call (and every STRIDE-th mutated call) once per allocation
 *           it makes, with that allocation failing, and once per file call
 *           it makes, with that file call failing
 *   cancel  every call once per interrupt poll it makes, with the
 *           interruption requested at that poll
 *   replies the reasoning, embedding and text-to-SQL calls once per reply a
 *           scripted reasoning plugin can give (needs FSQL_SCRIPTED_PLUGIN
 *           and FSQL_SCRIPTED_REPLY), with and without a failed allocation
 *   provider  the provider settings applied in many combinations, then the
 *           same calls under each, with and without a failed allocation
 *   config  the session configuration library driven directly: every key
 *           with values of every type, read-back buffers of every size, many
 *           sessions, and a failed allocation at each point of the round
 *   session the session registry driven directly: acquire and release in
 *           every order, a registry filled past its capacity, and a failed
 *           allocation at each point of a round
 *   all     every phase in turn
 *
 * The oom phase needs tests/oom_preload.c on LD_PRELOAD; without it the phase
 * is skipped. FSQL_DIRECT_ONLY=a,b limits the run to functions whose name
 * contains one of the fragments, and FSQL_DIRECT_OOM_CAP=N tries at most N
 * failure points per call (default 600), and FSQL_DIRECT_NO_VARIANTS=1
 * leaves the mutated calls out of the oom phase. Nothing here judges a result: a phase passes when the process
 * is still running at the end.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mysql.h>

#include "fractalsql_interrupt.h"
#include "fractalsql_config.h"
#include "fractalsql_provider.h"
#include "fractalsql_session.h"

/* The daemon's own function table, from the same generated declarations. */
enum fsq_kind { FSQ_KIND_CTL, FSQ_KIND_STR, FSQ_KIND_INT, FSQ_KIND_REAL };

struct fsq_fn {
    const char *name;
    enum fsq_kind kind;
    void *init;
    void *deinit;
    void *main;
};

#include "daemon_udfs.h"

#define g_fns g_fn_table
#define NFNS (sizeof g_fn_table / sizeof g_fn_table[0])
#define fn fsq_fn
#define K_STR FSQ_KIND_STR
#define K_INT FSQ_KIND_INT
#define K_REAL FSQ_KIND_REAL

#define MAXA 16

enum { A_NULL, A_STR, A_INT, A_REAL };

struct arg {
    int       kind;
    char     *s;        /* A_STR: NUL-terminated copy */
    size_t    len;
    long long i;
    double    d;
};

struct call {
    const struct fn *f;
    int              n;
    struct arg       a[MAXA];
};

/* ---- the interrupt hook: counts polls and can request one at the Nth ---- */
static long g_polls, g_cancel_at;
static int hook(void)
{
    g_polls++;
    return g_cancel_at > 0 && g_polls >= g_cancel_at;
}

/* ---- the fault controls exported by oom_preload.so, when it is loaded ---- */
static void (*oom_arm)(long, long);
static void (*oom_disarm)(void);
static long (*oom_allocs)(void);
static long (*oom_ios)(void);

static void load_oom(void)
{
    oom_arm    = (void (*)(long, long)) dlsym(RTLD_DEFAULT, "fsql_oom_arm");
    oom_disarm = (void (*)(void))       dlsym(RTLD_DEFAULT, "fsql_oom_disarm");
    oom_allocs = (long (*)(void))       dlsym(RTLD_DEFAULT, "fsql_oom_allocs");
    oom_ios    = (long (*)(void))       dlsym(RTLD_DEFAULT, "fsql_oom_ios");
}

/* ---- running one call ---- */
static long g_runs, g_refused;
/* How many calls share one ledger before it is started over. The edge values include 4 MiB payloads, and every
 * audit call walks, hashes and syncs the whole chain, so a long chain makes a run quadratic; a slow disk (a
 * macOS CI VM) turns that into minutes. FSQL_DIRECT_LEDGER_RESET overrides. */
static long g_ledger_reset = 100;

/* Runs init, the body and deinit the way the daemon does. */
static void run_call(const struct call *c)
{
    UDF_INIT           init;
    UDF_ARGS           args;
    char               msg[512] = "";
    enum Item_result   types[MAXA];
    enum Item_result   given[MAXA];
    char              *vals[MAXA];
    char               tbuf[MAXA][64];
    unsigned long      lens[MAXA];
    char               mnull[MAXA];
    long long          iv[MAXA];
    double             dv[MAXA];
    char               is_null = 0, err = 0;
    int                i;

    memset(&init, 0, sizeof init);
    memset(&args, 0, sizeof args);
    memset(mnull, 0, sizeof mnull);
    for (i = 0; i < c->n; i++) {
        const struct arg *a = &c->a[i];
        lens[i] = 0;
        vals[i] = NULL;
        types[i] = STRING_RESULT;
        switch (a->kind) {
        case A_STR:  vals[i] = a->s; lens[i] = (unsigned long) a->len; break;
        case A_INT:  types[i] = INT_RESULT;  iv[i] = a->i; vals[i] = (char *) &iv[i]; lens[i] = 8; break;
        case A_REAL: types[i] = REAL_RESULT; dv[i] = a->d; vals[i] = (char *) &dv[i]; lens[i] = 8; break;
        default: break;
        }
    }
    memcpy(given, types, sizeof given);
    args.arg_count  = (unsigned int) c->n;
    args.arg_type   = types;
    args.args       = vals;
    args.lengths    = lens;
    args.maybe_null = mnull;

    g_runs++;
    /* Progress on stderr (unbuffered) so a run that is killed for taking too long shows where it was. */
    if (g_runs % 250 == 0) fprintf(stderr, "udf_direct: call %ld (%s)\n", g_runs, c->f->name);
    /* An audit chain grows with every call and each call walks it; start
     * over now and then so the run stays linear. */
    if (g_runs % g_ledger_reset == 0) {
        const char *lp = getenv("FRACTALSQL_ENTERPRISE_LEDGER_PATH");
        if (lp && *lp) {
            char csv[4200];
            unlink(lp);
            snprintf(csv, sizeof csv, "%s.csv", lp);
            unlink(csv);
        }
    }
    if (((bool (*)(UDF_INIT *, UDF_ARGS *, char *)) c->f->init)(&init, &args, msg)) {
        g_refused++;
        return;
    }
    /* MariaDB converts every argument to the type init left in arg_type
     * before it calls the body (init may force a type, for example INT for
     * a count or REAL for a seed). A literal written as a decimal or a
     * string arrives here as text, so convert it the same way; a body that
     * reads 8 bytes from a 5-byte string is otherwise a harness artefact. */
    for (i = 0; i < c->n; i++) {
        long long  li = 0;
        double     ld = 0;
        if (vals[i] == NULL || types[i] == given[i]) continue;
        if (given[i] == INT_RESULT)       { li = *(long long *) vals[i]; ld = (double) li; }
        else if (given[i] == REAL_RESULT) {
            ld = *(double *) vals[i];
            /* Converting a NaN or an out-of-range double to an integer is undefined behaviour in C
             * (UBSan reports it on Apple's clang), so saturate; this harness mimics the server's
             * argument coercion, not a truncating cast of arbitrary input. */
            li = (ld != ld) ? 0
               : (ld >= 9223372036854775807.0)  ? 9223372036854775807LL
               : (ld <= -9223372036854775808.0) ? (-9223372036854775807LL - 1)
               : (long long) ld;
        }
        else {
            char *tmp = malloc(lens[i] + 1), *end;
            /* The fault shim can fail this harness allocation too; a
             * conversion that cannot run leaves the argument at zero. */
            if (tmp) {
                memcpy(tmp, vals[i], lens[i]);
                tmp[lens[i]] = '\0';
                ld = strtod(tmp, &end);
                li = strtoll(tmp, &end, 10);
                free(tmp);
            }
        }
        if (types[i] == INT_RESULT)        { iv[i] = li; vals[i] = (char *) &iv[i]; lens[i] = 8; }
        else if (types[i] == REAL_RESULT)  { dv[i] = ld; vals[i] = (char *) &dv[i]; lens[i] = 8; }
        else {
            lens[i] = (unsigned long) (given[i] == INT_RESULT ? snprintf(tbuf[i], sizeof tbuf[i], "%lld", li)
                                                              : snprintf(tbuf[i], sizeof tbuf[i], "%.15g", ld));
            vals[i] = tbuf[i];
        }
    }
    if (c->f->kind == K_STR) {
        unsigned long len = 0;
        char *res = malloc((size_t) init.max_length + 1);
        if (res) {
            ((char *(*)(UDF_INIT *, UDF_ARGS *, char *, unsigned long *, char *, char *))
                c->f->main)(&init, &args, res, &len, &is_null, &err);
            free(res);
        }
    } else if (c->f->kind == K_INT) {
        ((long long (*)(UDF_INIT *, UDF_ARGS *, char *, char *)) c->f->main)(&init, &args, &is_null, &err);
    } else {
        ((double (*)(UDF_INIT *, UDF_ARGS *, char *, char *)) c->f->main)(&init, &args, &is_null, &err);
    }
    ((void (*)(UDF_INIT *)) c->f->deinit)(&init);
}

/* ---- reading the seed file ---- */
static struct call *g_calls;
static int          g_ncalls, g_skipped;

static char *dupn(const char *s, size_t n)
{
    char *p = malloc(n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

/* Parses one SQL literal; returns 0 on success, -1 for anything else. */
static int parse_arg(const char *t, size_t n, struct arg *out)
{
    memset(out, 0, sizeof *out);
    while (n && isspace((unsigned char) *t)) { t++; n--; }
    while (n && isspace((unsigned char) t[n - 1])) n--;
    if (n == 0) return -1;
    if (t[0] == '\'') {
        char *buf = malloc(n + 1);
        size_t o = 0, i;
        for (i = 1; i + 1 < n; i++) {
            char ch = t[i];
            if (ch == '\'' && t[i + 1] == '\'') { buf[o++] = '\''; i++; }
            else if (ch == '\\' && i + 2 < n + 0) {
                char e = t[++i];
                buf[o++] = e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == '0' ? '\0' : e;
            } else buf[o++] = ch;
        }
        buf[o] = '\0';
        out->kind = A_STR; out->s = buf; out->len = o;
        return 0;
    }
    if (n == 4 && strncasecmp(t, "NULL", 4) == 0) { out->kind = A_NULL; return 0; }
    if (n == 15 && strncasecmp(t, "CONNECTION_ID()", 15) == 0) { out->kind = A_INT; out->i = 7; return 0; }
    {
        char *tmp = dupn(t, n), *end = NULL;
        int has_dot = strchr(tmp, '.') != NULL, has_exp = strpbrk(tmp, "eE") != NULL;
        int ok = 0;
        if (!has_dot && !has_exp) {
            out->i = strtoll(tmp, &end, 10);
            if (end && *end == '\0') { out->kind = A_INT; ok = 1; }
        } else {
            out->d = strtod(tmp, &end);
            if (end && *end == '\0') {
                if (has_exp) { out->kind = A_REAL; }
                else { out->kind = A_STR; out->s = tmp; out->len = n; tmp = NULL; }
                ok = 1;
            }
        }
        free(tmp);
        return ok ? 0 : -1;
    }
}

static const struct fn *find_fn(const char *name)
{
    size_t i;
    for (i = 0; i < NFNS; i++) if (strcmp(g_fns[i].name, name) == 0) return &g_fns[i];
    return NULL;
}

/* One line "SELECT name(arg, arg, ...);" becomes a call. */
static int parse_line(char *line, struct call *c)
{
    char *p = line, *name, *open, *q, *close;
    size_t depth = 0;
    char quote = 0;
    int n = 0;
    char *start;
    memset(c, 0, sizeof *c);
    if (strncasecmp(p, "SELECT ", 7) != 0) return -1;
    p += 7;
    while (*p == ' ') p++;
    name = p;
    open = strchr(p, '(');
    if (!open) return -1;
    *open = '\0';
    c->f = find_fn(name);
    if (!c->f) return -1;
    close = strrchr(open + 1, ')');
    if (!close) return -1;
    start = open + 1;
    if (close == start) return 0;
    for (q = start;; q++) {
        int end = (q == close);
        if (!end) {
            if (quote) {
                if (*q == '\\' && q[1]) q++;
                else if (*q == quote) { if (q[1] == quote) q++; else quote = 0; }
            } else if (*q == '\'' || *q == '"') quote = *q;
            else if (*q == '(' || *q == '[') depth++;
            else if (*q == ')' || *q == ']') depth--;
        }
        if (end || (!quote && depth == 0 && *q == ',')) {
            if (n >= MAXA || parse_arg(start, (size_t) (q - start), &c->a[n]) != 0) return -1;
            n++;
            start = q + 1;
        }
        if (end) break;
    }
    c->n = n;
    return 0;
}

/* FSQL_DIRECT_ONLY=a,b keeps only the calls whose function name contains one
 * of the listed fragments. */
static int wanted(const char *name)
{
    const char *only = getenv("FSQL_DIRECT_ONLY"), *p;
    if (!only || !*only) return 1;
    for (p = only; *p;) {
        const char *comma = strchr(p, ',');
        size_t n = comma ? (size_t) (comma - p) : strlen(p);
        char frag[64];
        if (n > 0 && n < sizeof frag) {
            memcpy(frag, p, n); frag[n] = '\0';
            if (strstr(name, frag)) return 1;
        }
        p += n + (comma ? 1 : 0);
    }
    return 0;
}

static void read_seeds(const char *path)
{
    FILE *f = fopen(path, "r");
    char *line = NULL;
    size_t cap = 0;
    ssize_t got;
    int cc = 0;
    if (!f) { perror(path); exit(2); }
    while ((got = getline(&line, &cap, f)) > 0) {
        struct call c;
        char *dup = dupn(line, (size_t) got);
        while (got > 0 && (dup[got - 1] == '\n' || dup[got - 1] == '\r' || dup[got - 1] == ';')) dup[--got] = '\0';
        if (strncasecmp(dup, "SELECT ", 7) != 0) { free(dup); continue; }
        if (parse_line(dup, &c) != 0) { g_skipped++; free(dup); continue; }
        if (!wanted(c.f->name)) {
            int ai;
            for (ai = 0; ai < c.n; ai++) if (c.a[ai].kind == A_STR) free(c.a[ai].s);
            free(dup);
            continue;
        }
        if (g_ncalls == cc) { cc = cc ? cc * 2 : 256; g_calls = realloc(g_calls, (size_t) cc * sizeof *g_calls); }
        g_calls[g_ncalls++] = c;
        free(dup);
    }
    free(line);
    fclose(f);
}

/* ---- edge values ---- */
static struct arg g_edges[64];
static int        g_nedges;

static void add_str(const char *s, size_t n)
{
    struct arg *a = &g_edges[g_nedges++];
    memset(a, 0, sizeof *a);
    a->kind = A_STR; a->s = dupn(s, n); a->len = n;
}
static void add_cstr(const char *s) { add_str(s, strlen(s)); }
static void add_int(long long v) { struct arg *a = &g_edges[g_nedges++]; memset(a, 0, sizeof *a); a->kind = A_INT; a->i = v; }
static void add_real(double v) { struct arg *a = &g_edges[g_nedges++]; memset(a, 0, sizeof *a); a->kind = A_REAL; a->d = v; }

static void build_edges(void)
{
    char *big;
    memset(&g_edges[g_nedges++], 0, sizeof g_edges[0]);   /* NULL */
    add_cstr(""); add_cstr(" "); add_cstr("x"); add_cstr("0"); add_cstr("-1"); add_cstr("1e999"); add_cstr("NaN");
    add_cstr("[]"); add_cstr("[1,2"); add_cstr("[1,2,3]"); add_cstr("[1,2,3,]"); add_cstr("[[1,2],[3]]");
    add_cstr("[NaN]"); add_cstr("[1e999]"); add_cstr("[1,\"a\",3]"); add_cstr("{}"); add_cstr("{\"a\":1}");
    add_cstr("{\"iterations\": -1}"); add_cstr("{\"iterations\": 1e30}"); add_cstr("{\"a\":");
    add_cstr("1,2,3"); add_cstr("0,0;1,1"); add_cstr("not json"); add_cstr("\xff\xfe\xfd");
    add_str("a\0b", 3);
    add_int(0); add_int(1); add_int(-1); add_int(2); add_int(INT_MAX); add_int(INT_MIN);
    add_int(LLONG_MAX); add_int(LLONG_MIN); add_int(4294967296LL);
    add_real(0.0); add_real(-0.0); add_real(1.0); add_real(-1.0); add_real(NAN); add_real(INFINITY);
    add_real(-INFINITY); add_real(1e308); add_real(-1e308); add_real(1e-308); add_real(5e-324);
    big = malloc(70001);
    memset(big, 'a', 70000);
    add_str(big, 70000);
    free(big);
    big = malloc(4194306);
    memset(big, '1', 4194305);
    add_str(big, 4194305);
    free(big);
    big = malloc(200002);
    {
        size_t i, o = 0;
        big[o++] = '[';
        for (i = 0; i < 40000; i++) o += (size_t) sprintf(big + o, "%s%zu", i ? "," : "", i % 97);
        big[o++] = ']';
        add_str(big, o);
    }
    free(big);
}

static void phase_seed(void)
{
    int i;
    for (i = 0; i < g_ncalls; i++) run_call(&g_calls[i]);
    printf("seed: %d calls\n", g_ncalls);
}

/* Calls the mutation callback for every variant of every seed call. */
typedef void (*variant_fn)(const struct call *, void *);

static void each_variant(void (*cb)(const struct call *, void *), void *ctx, int stride)
{
    int i, j, e, k = 0;
    for (i = 0; i < g_ncalls; i++) {
        const struct call *base = &g_calls[i];
        struct call v;
        for (j = 0; j < base->n; j++) {
            for (e = 0; e < g_nedges; e++) {
                if (stride > 1 && (k++ % stride) != 0) continue;
                v = *base;
                v.a[j] = g_edges[e];
                cb(&v, ctx);
            }
        }
        /* shortened, lengthened and emptied argument lists */
        for (j = 0; j <= base->n + 2 && j < MAXA; j++) {
            int m;
            if (j == base->n) continue;
            if (stride > 1 && (k++ % stride) != 0) continue;
            v = *base;
            v.n = j;
            for (m = base->n; m < j; m++) v.a[m] = g_edges[(m * 7) % g_nedges];
            cb(&v, ctx);
        }
        if (stride > 1 && (k++ % stride) != 0) continue;
        v = *base;
        for (j = 0; j < v.n; j++) memset(&v.a[j], 0, sizeof v.a[j]);   /* all NULL */
        cb(&v, ctx);
    }
}

static void cb_run(const struct call *c, void *ctx) { (void) ctx; run_call(c); }

static void phase_mutate(void)
{
    long before = g_runs;
    each_variant(cb_run, NULL, 1);
    printf("mutate: %ld calls\n", g_runs - before);
}

/* ---- allocation and file faults ---- */
static long g_oom_trials;
static int  g_oom_cap = 600;

static void oom_sweep_one(const struct call *c, void *ctx)
{
    long total, ios, n, step, m;
    (void) ctx;
    /* A clean, counted run first. */
    oom_arm(1L << 40, 1L << 40);
    run_call(c);
    total = oom_allocs();
    ios   = oom_ios();
    oom_disarm();
    step = total > g_oom_cap ? total / g_oom_cap : 1;
    for (n = 1; n <= total; n += step) {
        oom_arm(n, 0);
        run_call(c);
        oom_disarm();
        g_oom_trials++;
    }
    step = ios > g_oom_cap ? ios / g_oom_cap : 1;
    for (m = 1; m <= ios; m += step) {
        oom_arm(0, m);
        run_call(c);
        oom_disarm();
        g_oom_trials++;
    }
}

static void phase_oom(int stride)
{
    int i;
    if (!oom_arm || !oom_allocs || !oom_ios || !oom_disarm) {
        printf("oom: skipped (oom_preload.so is not loaded)\n");
        return;
    }
    for (i = 0; i < g_ncalls; i++) {
        if (getenv("FSQL_DIRECT_TRACE")) { fprintf(stderr, "oom seed %d %s\n", i, g_calls[i].f->name); }
        oom_sweep_one(&g_calls[i], NULL);
    }
    if (!getenv("FSQL_DIRECT_NO_VARIANTS")) each_variant(oom_sweep_one, NULL, stride > 0 ? stride : 25);
    printf("oom: %ld faulted runs\n", g_oom_trials);
}

/* ---- interruption ---- */
static void cancel_sweep_one(const struct call *c, void *ctx)
{
    long total, t, step;
    (void) ctx;
    g_polls = 0; g_cancel_at = 0;
    run_call(c);
    total = g_polls;
    step = total > 100 ? total / 100 : 1;
    for (t = 1; t <= total; t += step) {
        g_polls = 0; g_cancel_at = t;
        run_call(c);
    }
    g_cancel_at = 0;
}

static void phase_cancel(int stride)
{
    int i;
    fractalsql_interrupt_hook_set(hook);
    for (i = 0; i < g_ncalls; i++) cancel_sweep_one(&g_calls[i], NULL);
    each_variant(cancel_sweep_one, NULL, stride > 0 ? stride * 4 : 100);
    fractalsql_interrupt_hook_set(NULL);
    printf("cancel: done\n");
}


/* ---- reasoning, embedding and text-to-SQL calls under scripted replies ---- */
static int is_cognition(const struct call *c)
{
    static const char *const pat[] = { "reason", "t2s", "embed", "think", "agent_partial", "config" };
    size_t i;
    for (i = 0; i < sizeof pat / sizeof pat[0]; i++)
        if (strstr(c->f->name, pat[i])) return 1;
    return 0;
}

static void write_reply(const char *data, size_t n)
{
    FILE *f = fopen(getenv("FSQL_SCRIPTED_REPLY"), "wb");
    if (!f) { perror("FSQL_SCRIPTED_REPLY"); exit(2); }
    if (n) fwrite(data, 1, n, f);
    fclose(f);
}

static void run_cognition_calls(int with_oom)
{
    int i;
    for (i = 0; i < g_ncalls; i++) {
        if (!is_cognition(&g_calls[i])) continue;
        run_call(&g_calls[i]);
        if (with_oom && oom_arm) oom_sweep_one(&g_calls[i], NULL);
    }
}

static void phase_replies(void)
{
    static const char *const replies[] = {
        "hello", "SELECT 1", "", "PASS", "pass", "Pass: fine", "FAIL: bad", "pas",
        "@null", "@rc=-1", "@rc=-5", "@rc=3", "@size=16777217", "@size=3000000", "@size=70000",
        "0.5,0.25,0.125", "[0.5,0.25]", "1,2,3,4,5,6,7,8", "1,x,3", "nan,1", "1e999,1", ",", "1,,2",
        "\"quoted\"\n\\ back", "\xc3\xa9\xc3\xa9\xc3\xa9",
    };
    size_t i;
    char *csv;
    if (!getenv("FSQL_SCRIPTED_REPLY") || !getenv("FSQL_SCRIPTED_PLUGIN")) {
        printf("replies: skipped (FSQL_SCRIPTED_PLUGIN and FSQL_SCRIPTED_REPLY are not set)\n");
        return;
    }
    {
        struct fsq_provider_cfg c;
        memset(&c, 0, sizeof c);
        c.present = FSQL_PROV_REASONING_PLUGIN;
        c.reasoning_plugin = getenv("FSQL_SCRIPTED_PLUGIN");
        fractalsql_cognition_apply_provider(&c);
        fractalsql_textsql_apply_provider(&c);
    }
    for (i = 0; i < sizeof replies / sizeof replies[0]; i++) {
        write_reply(replies[i], strlen(replies[i]));
        run_cognition_calls(i < 8 || i == 15);
    }
    csv = malloc(2000000);
    {
        size_t o = 0, k;
        for (k = 0; k < 150000 && o < 1999900; k++) o += (size_t) sprintf(csv + o, "%s0.%zu", k ? "," : "", k % 10);
        write_reply(csv, o);
        run_cognition_calls(0);
    }
    free(csv);
    write_reply("hello", 5);
    printf("replies: done\n");
}

/* ---- provider settings ---- */
static int apply_all(const struct fsq_provider_cfg *c)
{
    int rc = 0;
    rc |= fractalsql_cognition_check_provider(c);
    rc |= fractalsql_textsql_check_provider(c);
    rc |= fractalsql_enterprise_check_provider(c);
    rc |= fractalsql_cognition_apply_provider(c);
    rc |= fractalsql_textsql_apply_provider(c);
    rc |= fractalsql_enterprise_apply_provider(c);
    return rc;
}

static void apply_sweep(const struct fsq_provider_cfg *c)
{
    long total, n, step;
    if (!oom_arm) return;
    oom_arm(1L << 40, 0);
    apply_all(c);
    total = oom_allocs();
    oom_disarm();
    step = total > g_oom_cap ? total / g_oom_cap : 1;
    for (n = 1; n <= total; n += step) {
        oom_arm(n, 0);
        apply_all(c);
        oom_disarm();
        g_oom_trials++;
    }
}

static void phase_provider(void)
{
    const char *plugin = getenv("FSQL_SCRIPTED_PLUGIN");
    struct fsq_provider_cfg full, c;
    int bit, k;
    long before = g_oom_trials;
    memset(&full, 0, sizeof full);
    full.present = 0x3ffffu;
    full.reasoning_plugin = plugin ? plugin : "/nonexistent/plugin.so";
    full.reasoning_url = "http://127.0.0.1:1/v1/chat/completions";
    full.reasoning_token = "token";
    full.reasoning_model = "model";
    full.reasoning_allow_plaintext = true;
    full.embed_url = "http://127.0.0.1:1/v1/embeddings";
    full.embed_model = "embed-model";
    full.think = "high";
    full.think_provider = "ollama";
    full.think_native_url = "http://127.0.0.1:1/api/chat";
    full.think_num_ctx_str = "4096";
    full.think_num_ctx = 4096;
    full.t2s_max_attempts = 3;
    full.t2s_allowed_statements = "select_insert_update";
    full.t2s_use_review = true;
    full.enterprise_lib = "/nonexistent/enterprise.so";
    full.enterprise_ledger_path = "/nonexistent/ledger.bin";
    full.enterprise_ledger_key = "key";
    full.enterprise_require_signature = true;

    for (k = 0; k < 3; k++) {
        c = full;
        if (k == 1) { c.think = "low"; c.reasoning_allow_plaintext = false; c.t2s_use_review = false;
                      c.t2s_allowed_statements = "select"; c.t2s_max_attempts = 10; c.enterprise_require_signature = false; }
        if (k == 2) { c.reasoning_token = ""; c.reasoning_model = ""; c.think_provider = ""; c.think_native_url = "";
                      c.embed_model = ""; c.think_num_ctx_str = ""; c.think_num_ctx = 0; }
        apply_all(&c);
        apply_sweep(&c);
        run_cognition_calls(k == 0);
    }
    for (bit = 0; bit < 18; bit++) {
        c = full;
        c.present = 1u << bit;
        apply_all(&c);
        apply_sweep(&c);
        run_cognition_calls(0);
    }
    memset(&c, 0, sizeof c);
    apply_all(&c);                         /* nothing present: back to the environment */
    apply_sweep(&c);
    run_cognition_calls(0);
    printf("provider: %ld faulted applies\n", g_oom_trials - before);
}


/* ---- the session configuration library ---- */
static void config_round(void)
{
    static const char *const vals[] = {
        "", "x", "0", "1", "-1", "10", "11", "99", "10000000", "10000001", "9999999999999999999",
        "1x", "abc", " 5", "5 ", "0x10", "true", "false", "on", "off", "yes", "no", "TRUE", "Off", "maybe",
        "select", "select_insert_update", "SELECT", "select|", "select_insert",
        "/abs/path", "/abs/../path", "/abs/./path", "relative/path", "../x", "..", "/", "//", "/a/b/c/d/e",
        "C:\\dir\\file", "C:/dir/file", "C:", "C:\\..\\x", "\\\\server\\share\\f", "\\rooted\\path",
        "/trailing/..", "/..", "/a/..b", "/a/b..", "high", "medium", "low", "ollama", "http://127.0.0.1:1/v1",
    };
    char longv[FSQL_CFG_MAX_VALUE + 64], out[FSQL_CFG_MAX_VALUE + 64], err[256], pathbuf[FSQL_CFG_MAX_VALUE + 64];
    static const size_t caps[] = { 0, 1, 2, 4, 16, 64, FSQL_CFG_MAX_VALUE + 64 };
    static const unsigned long long sids[] = { 0, 1, 2, 3, 4294967296ULL, ~0ULL };
    size_t k, v, c, si;
    long lv;
    char *j;
    int key;

    memset(longv, 'a', sizeof longv - 1); longv[sizeof longv - 1] = '\0';
    memset(pathbuf, 'p', sizeof pathbuf - 1); pathbuf[0] = '/'; pathbuf[sizeof pathbuf - 1] = '\0';
    fractal_config_key_name(-1); fractal_config_key_name(FSQL_CFG_KEY_COUNT);
    fractal_config_key_session_ok(-1); fractal_config_key_session_ok(FSQL_CFG_KEY_COUNT);
    fractal_config_key_by_name(NULL); fractal_config_key_by_name("nope"); fractal_config_key_by_name("fractalsql.");
    fractal_config_validate_path(NULL, err, sizeof err);
    fractal_config_validate_path("", err, sizeof err);
    fractal_config_validate_path("/ok", NULL, 0);
    fractal_config_validate_path("relative", NULL, 0);
    fractal_config_validate_path(pathbuf, err, sizeof err);
    for (key = 0; key < FSQL_CFG_KEY_COUNT; key++) {
        const char *name = fractal_config_key_name(key);
        char prefixed[128];
        snprintf(prefixed, sizeof prefixed, "fractalsql.%s", name);
        for (si = 0; si < sizeof sids / sizeof sids[0]; si++) {
            unsigned long long sid = sids[si];
            for (v = 0; v < sizeof vals / sizeof vals[0]; v++) {
                fractal_config_set_value(sid, si & 1 ? prefixed : name, vals[v], err, sizeof err);
                if (v % 7 == 0) fractal_config_set_value(sid, name, vals[v], NULL, 0);
            }
            fractal_config_set_value(sid, name, longv, err, sizeof err);
            fractal_config_set_value(sid, name, pathbuf, err, 3);
            fractal_config_set_value(sid, name, NULL, err, sizeof err);
            fractal_config_set_value(sid, NULL, "x", err, sizeof err);
            fractal_config_set_value(sid, "unknown_key", "x", err, sizeof err);
            for (c = 0; c < sizeof caps / sizeof caps[0]; c++) {
                fractal_config_get_value(sid, name, out, caps[c]);
                fractal_config_get_value(sid, prefixed, out, caps[c]);
            }
            fractal_config_get_value(sid, name, NULL, 0);
            fractal_config_get_value(sid, NULL, out, sizeof out);
            fractal_config_get_value(sid, "unknown_key", out, sizeof out);
            fractal_config_lookup_str(sid, name, out, sizeof out);
            fractal_config_lookup_str(sid, name, out, 2);
            fractal_config_lookup_str(sid, name, NULL, 0);
            fractal_config_lookup_long(sid, name, &lv);
            fractal_config_lookup_long(sid, name, NULL);
            fractal_config_lookup_long(sid, "unknown_key", &lv);
            j = fractal_config_session_json(sid);
            free(j);
            if (si % 2) fractal_config_reset_session(sid);
        }
    }
    /* More sessions than the table holds, so the oldest are evicted. */
    for (k = 1; k <= FSQL_CFG_MAX_SESSIONS + 8; k++) {
        fractal_config_set_value(100000 + k, "think", "low", err, sizeof err);
        fractal_config_set_value(100000 + k, "t2s_max_attempts", "2", err, sizeof err);
    }
    fractal_config_get_value(100001, "think", out, sizeof out);
    fractal_config_reset_session(100000 + FSQL_CFG_MAX_SESSIONS);
    fractal_config_reset_session(5555555);
    for (k = 0; k < 8; k++) {
        static const unsigned tiers[] = { 0, 1, 2, 4, 7, 3, 5, 6 };
        fractal_config_set_value(900 + k, "think_num_ctx", "2048", err, sizeof err);
        fractal_config_set_value(900 + k, "reasoning_allow_plaintext", "on", err, sizeof err);
        fractal_config_set_value(900 + k, "reasoning_token", "tok", err, sizeof err);
        fractal_config_set_value(900 + k, "reasoning_model", "m", err, sizeof err);
        fractal_config_set_value(900 + k, "embed_model", "em", err, sizeof err);
        fractal_config_set_value(900 + k, "think", "high", err, sizeof err);
        fractal_config_env_lock();
        fractal_config_apply_env_overrides(900 + k, tiers[k]);
        fractal_config_env_unlock();
        (void) fractal_config_env_fingerprint();
        fractal_config_reset_session(900 + k);
        fractal_config_env_lock();
        fractal_config_apply_env_overrides(900 + k, tiers[k]);
        fractal_config_env_unlock();
    }
}

static void phase_config(void)
{
    long total, n, step;
    config_round();
    if (!oom_arm) { printf("config: done (no fault sweep, oom_preload.so is not loaded)\n"); return; }
    oom_arm(1L << 40, 0);
    config_round();
    total = oom_allocs();
    oom_disarm();
    step = total > 1500 ? total / 1500 : 1;
    for (n = 1; n <= total; n += step) {
        oom_arm(n, 0);
        config_round();
        oom_disarm();
        g_oom_trials++;
    }
    printf("config: %ld allocations in a round, swept in steps of %ld\n", total, step);
}


/* ---- the session registry ---- */
static void session_round(int flood)
{
    bool busy = false, loaded = false;
    unsigned long long id;
    fsql_ctx *x, *y;

    x = fractal_session_acquire(11);
    y = fractal_session_acquire_exclusive(11, &busy);          /* refused: a plain holder has it */
    if (y) fractal_session_release_exclusive(11);
    fractal_session_acquire_exclusive(11, NULL);
    fractal_session_release(11);
    (void) x;
    y = fractal_session_acquire_exclusive(12, &busy);
    fractal_session_acquire_exclusive(12, &busy);              /* refused: already held */
    fractal_session_acquire_exclusive(12, NULL);
    fractal_session_acquire(12);                               /* refused: an exclusive holder has it */
    fractal_session_registry_close(12);                        /* pinned: a no-op */
    fractal_session_release_exclusive(12);
    fractal_session_release_exclusive(12);                     /* released twice */
    fractal_session_release_exclusive(777777);                 /* never existed */
    fractal_session_release(777777);
    fractal_session_release(12);
    fractal_session_registry_close(12);
    fractal_session_registry_close(777777);
    fractal_session_acquire(13);
    fractal_session_registry_close(13);                        /* pinned */
    fractal_session_release(13);
    fractal_session_registry_close(13);
    fractal_session_acquire(0);
    fractal_session_release(0);
    fractal_session_acquire(~0ULL);
    fractal_session_release(~0ULL);

    fractal_session_acquire_reason(1, &loaded);
    fractal_session_mark_reason_loaded(1);
    fractal_session_acquire_reason(1, NULL);
    fractal_session_release_tier();
    fractal_session_acquire_embed(1, &loaded);
    fractal_session_mark_embed_loaded(1);
    fractal_session_acquire_embed(1, NULL);
    fractal_session_release_tier();
    fractal_session_acquire_t2s(1, &loaded);
    fractal_session_mark_t2s_loaded(1);
    fractal_session_acquire_t2s(1, NULL);
    fractal_session_release_tier();
    fractal_session_acquire_review(1, &loaded);
    fractal_session_mark_review_loaded(1);
    fractal_session_acquire_review(1, NULL);
    fractal_session_release_tier();
    fractal_session_forget_reason_loaded();
    fractal_session_forget_embed_loaded();
    fractal_session_forget_t2s_loaded();
    fractal_session_forget_review_loaded();

    fractal_session_get_agent_partial(31);
    fractal_session_set_agent_partial(31, true);
    fractal_session_get_agent_partial(31);
    fractal_session_set_agent_partial(31, false);
    fractal_session_get_diversify_enabled(32);
    fractal_session_set_diversify_enabled(32, true);
    fractal_session_get_diversify_enabled(32);
    fractal_session_set_diversify_enabled(32, false);
    fractal_session_set_diversify_enabled(~0ULL - 5, true);
    fractal_session_registry_close(31);
    fractal_session_registry_close(32);
    fractal_session_destructive_locked(41);
    fractal_session_lock_destructive(41);
    fractal_session_lock_destructive(41);
    fractal_session_destructive_locked(41);
    fractal_session_destructive_locked(42);

    if (!flood) return;
    /* Past the registry's capacity: every old entry is released, so the
     * oldest are evicted... */
    for (id = 1000; id < 1000 + 4300; id++) {
        fractal_session_acquire(id);
        fractal_session_set_diversify_enabled(id, true);
        fractal_session_release(id);
    }
    /* ...and then with every entry pinned, so there is nothing to evict. */
    for (id = 20000; id < 20000 + 4300; id++) fractal_session_acquire(id);
    for (id = 20000; id < 20000 + 4300; id++) fractal_session_release(id);
    for (id = 30000; id < 30000 + 4300; id++) fractal_session_acquire_exclusive(id, &busy);
    for (id = 30000; id < 30000 + 4300; id++) fractal_session_release_exclusive(id);
    for (id = 40000; id < 40000 + 16500; id++) fractal_session_lock_destructive(id);
    fractal_session_destructive_locked(40000);
    fractal_session_destructive_locked(56000);
}

static void phase_session(void)
{
    long total, n, step;
    session_round(1);
    if (!oom_arm) { printf("session: done (no fault sweep)\n"); return; }
    oom_arm(1L << 40, 0);
    session_round(0);
    total = oom_allocs();
    oom_disarm();
    step = total > 1500 ? total / 1500 : 1;
    for (n = 1; n <= total; n += step) {
        oom_arm(n, 0);
        session_round(0);
        oom_disarm();
        g_oom_trials++;
    }
    printf("session: %ld allocations in a round, swept in steps of %ld\n", total, step);
}

int main(int argc, char **argv)
{
    const char *phase;
    int stride = argc > 3 ? atoi(argv[3]) : 0;
    if (argc < 3) {
        fprintf(stderr, "usage: udf_direct seed|mutate|oom|cancel|replies|provider|config|session|all SEEDS.sql [STRIDE]\n");
        return 2;
    }
    phase = argv[1];
    load_oom();
    if (getenv("FSQL_DIRECT_LEDGER_RESET") && atol(getenv("FSQL_DIRECT_LEDGER_RESET")) > 0)
        g_ledger_reset = atol(getenv("FSQL_DIRECT_LEDGER_RESET"));
    if (getenv("FSQL_DIRECT_OOM_CAP") && atoi(getenv("FSQL_DIRECT_OOM_CAP")) > 0)
        g_oom_cap = atoi(getenv("FSQL_DIRECT_OOM_CAP"));
    read_seeds(argv[2]);
    build_edges();
    printf("udf_direct: %d seed calls (%d lines skipped), %zu functions known\n", g_ncalls, g_skipped, NFNS);
    if (!strcmp(phase, "seed") || !strcmp(phase, "all")) phase_seed();
    if (!strcmp(phase, "mutate") || !strcmp(phase, "all")) phase_mutate();
    if (!strcmp(phase, "oom") || !strcmp(phase, "all")) phase_oom(stride);
    if (!strcmp(phase, "cancel") || !strcmp(phase, "all")) phase_cancel(stride);
    if (!strcmp(phase, "replies") || !strcmp(phase, "all")) phase_replies();
    if (!strcmp(phase, "config") || !strcmp(phase, "all")) phase_config();
    if (!strcmp(phase, "session") || !strcmp(phase, "all")) phase_session();
    if (!strcmp(phase, "provider") || !strcmp(phase, "all")) phase_provider();
    printf("udf_direct: %ld calls run, %ld refused by init\n", g_runs, g_refused);
    return 0;
}
