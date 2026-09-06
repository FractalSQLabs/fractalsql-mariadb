/* include/sfs_core_c.h
 *
 * Pure-C SFS core — internal interface consumed by src/fsql.c when
 * built with -DFSQL_IMPL_C. Mirrors the entry points of the Lua
 * community module (sfs_core_community.lua) so the same driver code
 * in fsql.c can swap implementations at compile time.
 *
 * Not part of the public ABI. Downstream language bindings and the
 * 9-factory fleet only see fractalsql.h.
 *
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2014 Hamid Salimi (SFS algorithmic lineage)
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */

#ifndef FSQL_SFS_CORE_C_H
#define FSQL_SFS_CORE_C_H

#include <stddef.h>
#include <stdint.h>

/* Diffusion noise generator selection (fsql_sfs_cfg.diffusion_mode). */
#define FSQL_SFS_DIFFUSE_GAUSSIAN 0   /* canonical SFS (Salimi 2014), default */
#define FSQL_SFS_DIFFUSE_LEVY     1   /* Mantegna's algorithm, beta=1.5 */

typedef struct fsql_sfs_cfg {
    /* Bounds (length = dim). */
    const double *lower;
    const double *upper;
    size_t        dim;

    /* SFS hyperparameters. */
    int    max_generation;     /* outer loop iterations */
    int    population_size;    /* fixed population */
    int    maximum_diffusion;  /* walks per particle per gen */
    double walk;               /* 0.0 = self-diffusion, 0.5 = canonical */
    int    bound_clipping;     /* 1 to clip to [lower, upper], 0 to allow drift */

    /* Opposition-Based Learning (OBL). When set, each trial candidate's
     * bound-reflected opposite (opposite[i] = lower[i] + upper[i] -
     * trial[i]) is also evaluated and the better of the two is kept
     * before the existing greedy accept check runs. Deterministic — no
     * RNG draw — so it cannot desync the PRNG stream between the C and
     * Lua implementations. Doubles the fitness-eval count of the
     * affected diffusion step when enabled. 0 (default) = disabled,
     * byte-identical to pre-OBL behavior. */
    int    use_obl;

    /* Diffusion noise generator: FSQL_SFS_DIFFUSE_GAUSSIAN (default, 0)
     * or FSQL_SFS_DIFFUSE_LEVY (1). Lévy-flight substitutes a heavy-
     * tailed step (Mantegna's algorithm, beta=1.5) for the Gaussian
     * walk, which can help escape local optima on highly multimodal
     * landscapes at the cost of occasional very large steps. Composes
     * with use_obl (OBL applies to whichever diffusion mode produced
     * the trial candidate). 0 (default) = today's Gaussian behavior,
     * byte-identical to before this field existed. */
    int    diffusion_mode;

    /* Deterministic RNG seed as a DOUBLE — matches LuaJIT's
     * math.randomseed(d) contract exactly. Passing the same double
     * value to both the Lua oracle and the pure-C backend produces
     * byte-equal RNG streams. Integer seeds up to |seed| < 2^53
     * round-trip losslessly through double.
     *
     * If seed == 0.0 AND the caller went through fsql_new / fsql_search,
     * fsql.c's driver synthesizes a time-based double at ctx creation.
     * In CI/parity contexts, always pass a non-zero seed. */
    double seed;

#ifdef FSQL_TRACE_ENABLED
    /* Trace outputs (Gate 24 / Gate 25). Only present in the trace
     * build variant — production builds compile without these fields,
     * so the public ABI of fsql_sfs_run is unchanged.
     *
     * trace_trajectory_out, when non-NULL, receives best_fit at the
     * END of each generation. Caller must size it >= max_generation
     * doubles. trace_trajectory_n is set to the number of values
     * actually written (= max_generation when run completes normally).
     *
     * trace_snapshot_out, when non-NULL, receives bytes of the post-
     * init state: pop_size * dim doubles of particle coords, then
     * pop_size doubles of fits. Caller must size it >= that many
     * bytes. trace_snapshot_n is set to bytes written. */
    double *trace_trajectory_out;
    size_t *trace_trajectory_n;
    void   *trace_snapshot_out;
    size_t *trace_snapshot_n;
#endif
} fsql_sfs_cfg;

/* Result struct populated by fsql_sfs_run. best_point must point to
 * dim doubles of caller-owned storage. */
typedef struct fsql_sfs_result {
    double *best_point;  /* caller-owned, dim doubles */
    double  best_fit;

    /* Scout (discovery) output. When non-NULL, fsql_sfs_run copies the
     * FINAL population out before freeing its internal arrays — this is
     * the run_explore() capability of the LuaJIT oracle, exposed for the
     * Scout search mode. NULL = Sniper-only (skip; zero overhead).
     *   population_out: caller-owned, population_size * dim doubles,
     *                   laid out particle-major (row p = particle p).
     *   fits_out:       caller-owned, population_size doubles.
     * Both are optional and independent; set either, neither, or both. */
    double *population_out;
    double *fits_out;
} fsql_sfs_result;

/* Fitness function signature. Returns a scalar; lower is better
 * (matches the Lua convention). `ctx` is an opaque caller cookie. */
typedef double (*fsql_fitness_fn)(const double *point, size_t dim, void *ctx);

/* Built-in cosine distance fitness: 1 - cos(point, query).
 * The caller owns `query` (dim doubles). The fitness function context
 * is the query pointer itself; use fsql_sfs_cosine_fitness as the
 * fitness_fn and pass (void*) query as the ctx. */
double fsql_sfs_cosine_fitness(const double *point, size_t dim, void *ctx);

/* Scout fitness: minimum cosine distance from `point` to ANY stored
 * corpus vector. Minimizing it drives a particle toward its NEAREST
 * data basin; with walk=0 (no cross-particle best-pull) the population
 * spreads across distinct basins — the discovery behavior. The ctx is
 * an fsql_sfs_corpus_ctx the caller owns for the duration of the run. */
typedef struct fsql_sfs_corpus_ctx {
    const double *corpus;   /* n_rows * dim doubles, row-major */
    size_t        n_rows;
} fsql_sfs_corpus_ctx;

double fsql_sfs_mindist_fitness(const double *point, size_t dim, void *ctx);

/* Main optimizer. Seeds the RNG from cfg->seed, initializes a
 * population of cfg->population_size particles in [lower, upper]^dim,
 * runs cfg->max_generation iterations with Gaussian diffusion walks,
 * and writes best_point + best_fit into *result.
 *
 * Returns 0 on success, negative errno-style on failure:
 *     -1  invalid cfg
 *     -2  out of memory
 */
int fsql_sfs_run(const fsql_sfs_cfg *cfg,
                 fsql_fitness_fn fitness, void *fitness_ctx,
                 fsql_sfs_result *result);

#endif
