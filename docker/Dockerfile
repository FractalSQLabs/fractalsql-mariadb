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
# Build artifacts (collected in the `export` stage, emitted to the host
# via `docker buildx --output type=local,dest=...`):
#   /fractalsql.so           the GPL-2.0-only shim, loaded by mariadbd (glibc 2.34)
#   /fractalsqld             the Apache-2.0 daemon that holds the core and runs
#                            the UDF bodies (glibc 2.34)
#
# Both come from service/ (see service/protocol/SPEC.md).
#
# musl/Alpine is NOT a supported build target for this repo's shipped
# binaries: build.sh drives the modern glibc-2.34 profile only, against the
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
        gcc gcc-c++ make binutils file python3 openssl-devel \
        mariadb-connector-c-devel \
 && dnf clean all

WORKDIR /build
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY service/            /build/service/
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
# service/Makefile already knows the right mariadb_config flags and links
# (-lcrypto for the daemon's Ed25519 verify, none for the shim). Stripped
# via EXT_LDFLAGS's --strip-all, since the Makefile has no LDFLAGS hook of
# its own to thread that through the link step.
RUN set -eux; \
    ARCH=$(uname -m); \
    CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a"; \
    test -f "/build/${CORE_A}" \
        || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 && exit 1); \
    make -C service clean; \
    make -C service all scan; \
    cp service/build/fractalsql.so /fractalsql.so; \
    strip --strip-all /fractalsql.so; \
    cp service/build/fractalsqld /fractalsqld; \
    strip --strip-all /fractalsqld; \
    sh /build/docker/assert_so.sh /fractalsql.so \
        "${SIZE_CEILING_BYTES}" "${GLIBC_CEILING}" "${LIBC_KIND}"; \
    echo "--- fractalsqld ---"; file /fractalsqld; ldd /fractalsqld; \
    stat -c 'size: %s bytes' /fractalsqld

# --------------------------------------------------------------------
# Export stage: scratch, so `buildx --output=local` drops just the two
# binaries -- fractalsql.so (shim) and fractalsqld (daemon).
# --------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /fractalsql.so /fractalsql.so
COPY --from=builder /fractalsqld /fractalsqld

# --------------------------------------------------------------------
# service/: the GPL-2.0-only shim fractalsql.so that mariadbd
# loads, and the Apache-2.0 daemon fractalsqld that holds the core and
# runs the UDF bodies. Built on the runtime base so glibc and libmariadb
# match what the containers run. The shim links no core code and no
# OpenSSL; the daemon is the only process that links the core archive.
# --------------------------------------------------------------------
FROM mariadb:11.4 AS service-builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential libmariadb-dev libssl-dev python3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY src/     /build/src/
COPY include/ /build/include/
COPY sql/     /build/sql/
COPY service/ /build/service/
RUN make -C service clean all scan

# --------------------------------------------------------------------
# Daemon: fractalsqld as the mysql user, with the reasoning plugin it
# loads at runtime. The socket and config live in the shared volume
# /run/fractalsql, which the mariadb container also mounts.
# --------------------------------------------------------------------
FROM mariadb:11.4 AS fractalsqld
RUN apt-get update \
 && apt-get install -y --no-install-recommends libcurl4 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=service-builder /build/service/build/fractalsqld /usr/local/bin/fractalsqld
COPY include/linux-x86_64/fractalsql-reasoning-http.so  /usr/lib/fractalsql/fractalsql-reasoning-http.x86_64.so
COPY include/linux-aarch64/fractalsql-reasoning-http.so /usr/lib/fractalsql/fractalsql-reasoning-http.aarch64.so
RUN set -e \
 && ARCH=$(uname -m) \
 && mv "/usr/lib/fractalsql/fractalsql-reasoning-http.${ARCH}.so" \
        /usr/lib/fractalsql/fractalsql-reasoning-http.so \
 && rm -f /usr/lib/fractalsql/fractalsql-reasoning-http.*.so
# Socket and config directory, owned by the runtime user so the container
# can run as mysql with no capabilities. Named volumes copy this ownership.
RUN install -d -m 0750 -o mysql -g mysql /run/fractalsql
COPY docker/fsql-fractalsqld-entrypoint.sh /usr/local/bin/fsql-fractalsqld-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/fsql-fractalsqld-entrypoint.sh"]

# --------------------------------------------------------------------
# Demo: a RUNNABLE MariaDB 11.4 server with the shim and the UDFs
# registered, for docker-compose.yml. It loads only the GPL shim. The
# core and the reasoning plugin run in the fractalsqld container.
# --------------------------------------------------------------------
FROM mariadb:11.4 AS demo
# python3 + python3-venv: the bench/ head-to-head runs in-container
# via a venv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        mariadb-plugin-connect \
 && rm -rf /var/lib/apt/lists/*

COPY --from=service-builder /build/service/build/fractalsql.so /usr/lib/mysql/plugin/fractalsql.so
COPY docker/fsql-mariadb-entrypoint.sh /usr/local/bin/fsql-mariadb-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/fsql-mariadb-entrypoint.sh"]
CMD ["mariadbd"]

# docker-entrypoint-initdb.d scripts run once, on first container start,
# in lexical order, against the DB named by MARIADB_DATABASE. This
# registers every UDF in sql/install_udf.sql (CREATE FUNCTION ...
# SONAME 'fractalsql.so'). install_agents.sql runs second (11- prefix),
# since its stored procedures call the UDFs install_udf.sql registers.
COPY sql/install_udf.sql    /docker-entrypoint-initdb.d/10-fractalsql.sql
COPY sql/install_agents.sql /docker-entrypoint-initdb.d/11-fractalsql-agents.sql
# Enterprise audit mirror (demo only): the CONNECT engine must be loaded
# before the CONNECT table is created, so the plugin install runs first.
COPY docker/connect-plugin.sql /docker-entrypoint-initdb.d/12-connect-plugin.sql
COPY sql/install_enterprise_connect.sql /docker-entrypoint-initdb.d/13-install_enterprise_connect.sql

# bench/ head-to-head tester.
COPY bench/ /bench/

# Every demo, runnable on demand via
#   mariadb -uroot -pfractalsql fractalsql_demo < /demo/<demo>.sql
# Not run at init: reasoning demos need the LLM host reachable, and
# every demo is re-runnable.
COPY demo/ /demo/
