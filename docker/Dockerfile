# syntax=docker/dockerfile:1.7
#
# fractalsql-mariadb Docker build: pure-C, vendored core archive,
# zero-dependency posture (no LuaJIT anywhere in this path).
#
# One fractalsql.so covers every supported MariaDB major (10.6 / 10.11 /
# 11.4 LTS / 12.3 LTS). The UDF ABI (UDF_INIT / UDF_ARGS /
# MYSQL_ERRMSG_SIZE, my_bool xxx_init/xxx/xxx_deinit) has been stable
# across all of them, so this Dockerfile only needs one build stage
# per (arch, libc-profile) cell.
#
# Build artifact (collected in the `export` stage, emitted to the host
# via `docker buildx --output type=local,dest=...`):
#   /fractalsql.so           (glibc 2.34)
#
# musl/Alpine is NOT a supported build target for this repo's shipped
# .so: build.sh drives the modern glibc-2.34 profile only, against the
# core archive vendored under include/linux-<arch>/.
#
# Usage:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target export \
#     --output type=local,dest=./dist/amd64 \
#     --build-arg CORE_VARIANT=community-minimal-c \
#     -f docker/Dockerfile .
#
# build.sh drives this for amd64/arm64.

ARG BASE_IMAGE=rockylinux:9
ARG GLIBC_CEILING=34
ARG LIBC_KIND=glibc
ARG SIZE_CEILING_BYTES=3145728

# Vendored core archive variant. Default "community-sovereign-c" is the
# modern glibc-2.34 build from the vendored core release drop in
# include/, a superset of "community-minimal-c" (confirmed via `nm`:
# exports every minimal-tier symbol plus the v2 sovereign-tier
# additions this repo's UDF port links against, including
# fsql_dimension_*, fsql_optimize_portfolio*, fsql_vascular_network,
# fsql_cortical_folding, fsql_nerve_plexus_metric, and
# fsql_morphological_complexity).
ARG CORE_VARIANT=community-sovereign-c

ARG EXT_CFLAGS="-D_GLIBCXX_USE_CXX11_ABI=0 -ffunction-sections -fdata-sections -fvisibility=default"
ARG EXT_LDFLAGS="-static-libgcc -Wl,--gc-sections -Wl,--strip-all -Wl,--exclude-libs,ALL"

# --------------------------------------------------------------------
# Stage: builder. mariadb-connector-c-devel for UDF headers (mysql.h),
# vendored core .a for the SFS implementation.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder
RUN dnf install -y --setopt=install_weak_deps=False \
        gcc gcc-c++ make binutils file \
        mariadb-connector-c-devel \
 && dnf clean all

WORKDIR /build
COPY src/                /build/src/
COPY include/            /build/include/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG GLIBC_CEILING
ARG LIBC_KIND
ARG CORE_VARIANT

# Core archives are vendored per-arch under include/linux-<uname-m>/
# (include/linux-x86_64/, include/linux-aarch64/), so a single
# Dockerfile works for both `docker buildx --platform
# linux/amd64` and `linux/arm64` via `uname -m` inside the builder stage.
RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-deploy the vendored core release drop into include/," >&2 \
        && echo "  which restores the archive together with .artifacts.sha256." >&2 \
        && exit 1)

RUN set -eux; \
    ARCH=$(uname -m); \
    CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a"; \
    MDB_CFLAGS="$(mariadb_config --cflags 2>/dev/null || echo -I/usr/include/mariadb)"; \
    gcc -Wall -Wextra -O3 -fPIC \
        -Iinclude $MDB_CFLAGS \
        ${EXT_CFLAGS} \
        -shared -o /fractalsql.so \
        src/fractalsql.c \
        src/fractalsql_parse.c \
        src/fractalsql_session.c \
        src/fractalsql_vector.c \
        src/fractalsql_cognition.c \
        src/fractalsql_textsql.c \
        src/fractalsql_enterprise.c \
        "/build/${CORE_A}" \
        -lm -lpthread -ldl \
        ${EXT_LDFLAGS}; \
    sh /build/docker/assert_so.sh /fractalsql.so \
        "${SIZE_CEILING_BYTES}" "${GLIBC_CEILING}" "${LIBC_KIND}"

# --------------------------------------------------------------------
# Export stage: scratch, so `buildx --output=local` drops just the .so.
# --------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /fractalsql.so /fractalsql.so

# --------------------------------------------------------------------
# Demo stage: a RUNNABLE MariaDB server with the UDFs already
# registered, for docker-compose.yml. Every stage above this line only
# ever hands raw .so files to the host (buildx --output=local); this is
# the first stage in this file you can actually `docker run`.
#
# Pinned to MariaDB 11.4 (the oldest maintained LTS major in this
# repo's compat matrix) since this is a fresh eval environment people
# will keep around, not an existing cluster to version-match -- "LTS"
# rather than "newest" so the eval image only ever tracks maintained,
# non-rolling majors.
#
# Turnkey end-state for `docker compose up -d` (no flags):
#   * MariaDB 11.4 running, DB fractalsql_demo, with the fractalsql UDF
#     set already registered (sql/install_udf.sql run as an
#     entrypoint-initdb script).
#   * The `ollama` compose service is up by default with NO model
#     pulled (model download is user-initiated, via the `pull-model`
#     compose profile).
#   * Every demo is in /demo/ and runnable on demand via
#     `mariadb -uroot -pfractalsql fractalsql_demo < /demo/<demo>.sql`.
#
# A real MariaDB PLUGIN (`INSTALL SONAME`, `fractalsql_reasoning_plugin`-
# style GLOBAL system variables read from my.cnf) was considered and
# rejected in favor of the design below. MariaDB's plugin loader
# (sql/sql_plugin.cc) requires a MYSQL_DAEMON_PLUGIN's declared
# interface version to exactly match the running server's own compiled
# MYSQL_VERSION_ID, down to the patch level, before INSTALL SONAME will
# accept the library. A single prebuilt fractalsql.so could never
# satisfy that across this repo's 10.6-12.3 compat matrix (or even
# across patch releases of one major), unlike every CREATE FUNCTION
# ... SONAME UDF in this library, which the stable UDF ABI already
# makes major/patch-independent.
#
# fractal_reason()/fractal_embed() (src/fractalsql_cognition.c) are
# instead configured via mysqld's PROCESS ENVIRONMENT, read once on
# first use: FRACTALSQL_REASONING_PLUGIN / FRACTALSQL_HTTP_URL /
# FRACTALSQL_HTTP_TOKEN / FRACTALSQL_HTTP_MODEL /
# FRACTALSQL_HTTP_EMBED_URL / FRACTALSQL_HTTP_EMBED_MODEL, set below
# via `environment:` in docker-compose.yml, pointing at the `ollama`
# service. See docs/reasoning-setup.md for the full configuration walkthrough.
# --------------------------------------------------------------------
FROM mariadb:11.4 AS demo
# python3 + python3-venv: the bench/ head-to-head runs in-container
# via a venv.
# libcurl4: fractalsql-reasoning-http.so (bundled below) dynamically
# links libcurl.so.4. Without it, fsql_load_reasoning's dlopen fails
# silently from a plain UDF's perspective: MariaDB's UDF ABI has no
# per-call custom error message path, so fractal_reason/fractal_embed/
# fractal_t2s_generate all just return NULL with a generic error
# instead of surfacing "libcurl.so.4: cannot open shared object file".
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        libcurl4 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /fractalsql.so /usr/lib/mysql/plugin/fractalsql.so

# Bundled reasoning plugin (vendored prebuilt .so from include/). Select
# the right arch via `uname -m` the same way the builder stage does, so
# this image builds on both linux/amd64 and linux/arm64. include/
# carries the plugin for every supported platform (linux-x86_64,
# linux-aarch64, darwin-arm64, darwin-x86_64; windows-x86_64 ships a
# .dll via the MSI path, not used here).
COPY include/linux-x86_64/fractalsql-reasoning-http.so  /usr/lib/mysql/plugin/fractalsql-reasoning-http.x86_64.so
COPY include/linux-aarch64/fractalsql-reasoning-http.so /usr/lib/mysql/plugin/fractalsql-reasoning-http.aarch64.so
RUN set -e \
 && ARCH=$(uname -m) \
 && mv "/usr/lib/mysql/plugin/fractalsql-reasoning-http.${ARCH}.so" \
        /usr/lib/mysql/plugin/fractalsql-reasoning-http.so \
 && rm -f /usr/lib/mysql/plugin/fractalsql-reasoning-http.*.so

# docker-entrypoint-initdb.d scripts run once, on first container start,
# in lexical order, against the DB named by MARIADB_DATABASE. This
# registers every UDF in sql/install_udf.sql (CREATE FUNCTION ...
# SONAME 'fractalsql.so') the same way `mariadb -uroot -p < install_udf.sql`
# does for a manual install. install_agents.sql runs second (11- prefix,
# after 10-) since its 15 stored procedures call base-tier functions
# install_udf.sql just registered.
COPY sql/install_udf.sql    /docker-entrypoint-initdb.d/10-fractalsql.sql
COPY sql/install_agents.sql /docker-entrypoint-initdb.d/11-fractalsql-agents.sql

# bench/ head-to-head tester. requirements-equivalent deps come from
# bench/tester/package.json (Node, not Python, for this repo's
# existing bench harness). Install at image build time so the layer
# caches independently of source changes.
COPY bench/ /bench/

# Every demo, runnable on demand via
#   mariadb -uroot -pfractalsql fractalsql_demo < /demo/<demo>.sql
# Not run at init: reasoning
# demos are inert without a pulled model, and every demo is re-runnable.
COPY demo/ /demo/
