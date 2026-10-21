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
# The same file also builds the MCP server (mcp/), which is a CLIENT of
# the database rather than part of it: the `mcp` target stages the
# server binary on its own, and the `demo` target stages it alongside
# the shim so the demo container's one-shot MCP helper works with no
# host build at all.
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
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target mcp \
#     --load -t fractalsql-mariadb-mcp:latest \
#     -f docker/Dockerfile .
#
# build.sh drives this for amd64/arm64.

ARG BASE_IMAGE=rockylinux:9@sha256:d7be1c094cc5845ee815d4632fe377514ee6ebcf8efaed6892889657e5ddaaa6
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
# Package list sorted, so a diff between two builds of this file is
# readable and an added dependency is obvious.
RUN dnf install -y --setopt=install_weak_deps=False --enablerepo=crb \
        binutils \
        file \
        gcc \
        gcc-c++ \
        libstdc++-static \
        mariadb-connector-c-devel \
        make \
        openssl-devel \
        pkgconf-pkg-config \
        python3 \
 && dnf clean all

WORKDIR /build
COPY src/                /build/src/
COPY include/            /build/include/
COPY sql/                /build/sql/
COPY service/            /build/service/
COPY mcp/                /build/mcp/
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

# The MCP server ships in the packages beside the shim and the daemon. It is a CLIENT of the database (libmariadb over
# the wire), built here on the same old-glibc base so the one binary runs on every supported distro. libstdc++ is linked
# statically; libgcc_s stays dynamic (a static libgcc would raise the glibc floor above the 2.34 ceiling).
RUN set -eux; \
    make -C mcp clean; \
    make -C mcp CXXFLAGS="-std=c++17 -O2 -Wall -Wextra $(mariadb_config --cflags) $(pkg-config --cflags openssl)" \
        LDFLAGS="-static-libstdc++ -Wl,--strip-all"; \
    cp mcp/fractalsql-mariadb-mcp /fractalsql-mariadb-mcp; \
    /fractalsql-mariadb-mcp --version; \
    echo "--- fractalsql-mariadb-mcp ---"; ldd /fractalsql-mariadb-mcp; \
    MAXG=$(objdump -T /fractalsql-mariadb-mcp | grep -o 'GLIBC_2\.[0-9]*' | sed 's/GLIBC_2\.//' | sort -n | tail -1); \
    test "${MAXG:-0}" -le "${GLIBC_CEILING}" \
        || (echo "ERROR: MCP binary needs glibc 2.${MAXG}, ceiling is 2.${GLIBC_CEILING}" >&2 && exit 1)

# --------------------------------------------------------------------
# Export stage: scratch, so `buildx --output=local` drops just the two
# binaries -- fractalsql.so (shim) and fractalsqld (daemon).
# --------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /fractalsql.so /fractalsql.so
COPY --from=builder /fractalsqld /fractalsqld
COPY --from=builder /fractalsql-mariadb-mcp /fractalsql-mariadb-mcp
# The MCP server's tool-surface and safety-annotation locks, beside the
# binary that reads them: without them the server refuses to start,
# because a missing lock is not a pass.
COPY --from=builder /build/mcp/.mcp-schema-lock /.mcp-schema-lock
COPY --from=builder /build/mcp/.mcp-safety-annotations-lock /.mcp-safety-annotations-lock

# --------------------------------------------------------------------
# service/: the GPL-2.0-only shim fractalsql.so that mariadbd
# loads, and the Apache-2.0 daemon fractalsqld that holds the core and
# runs the UDF bodies. Built on the runtime base so glibc and libmariadb
# match what the containers run. The shim links no core code and no
# OpenSSL; the daemon is the only process that links the core archive.
# --------------------------------------------------------------------
FROM mariadb:11.4@sha256:d1891ede5a559f1086f55053bb8cc1569b0298338c4d72d71725a7f74f6ba620 AS service-builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        libmariadb-dev \
        libssl-dev \
        python3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY src/     /build/src/
COPY include/ /build/include/
COPY sql/     /build/sql/
COPY service/ /build/service/
# The scan step includes the check on the MCP server's process boundary,
# which reads the tree next to service/. The tree has to be in the build
# context for that check to run at all.
COPY mcp/     /build/mcp/
RUN make -C service clean all scan

# --------------------------------------------------------------------
# mcp-builder: the MCP server binary (fractalsql-mariadb-mcp).
#
# The MCP server is a CLIENT of the database, not an in-process
# extension: it opens its own MariaDB connection and calls the
# engine's stored procedures and UDFs over it, while the UDF bodies
# themselves run in the separate fractalsqld daemon. It is therefore
# an ordinary Linux binary with two shared-library dependencies
# (libmariadb, libssl) and no build-time link against the core
# archive -- the same split the shim/daemon pair has.
#
# mcp/Makefile drives the build: no CMake, no package manager, one
# binary from mcp/src/*.cpp and mcp/src/adapters/*.cpp, with
# nlohmann/json vendored under mcp/vendor.
# --------------------------------------------------------------------
FROM mariadb:11.4@sha256:d1891ede5a559f1086f55053bb8cc1569b0298338c4d72d71725a7f74f6ba620 AS mcp-builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        libmariadb-dev \
        libssl-dev \
        pkg-config \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY mcp/ /build/mcp/
RUN set -eux; \
    make -C mcp clean; \
    make -C mcp; \
    test -x /build/mcp/fractalsql-mariadb-mcp; \
    /build/mcp/fractalsql-mariadb-mcp --version

# --------------------------------------------------------------------
# mcp: the MCP server on its own, for a deployment that runs the
# server outside the database container. Stdio is the default
# transport; --http <port> is the optional one.
#
# The binary is staged with an explicit 0755 mode rather than left
# to COPY's default: this repo does not track file modes in git
# (core.fileMode is false), so the checked-in sources arrive 644 and
# a bare `cp` staging of an executable is exactly the trap that
# cost this repo a silent, platform-specific failure once already.
# `install -m 0755` sets the mode explicitly at staging time.
# --------------------------------------------------------------------
FROM mariadb:11.4@sha256:d1891ede5a559f1086f55053bb8cc1569b0298338c4d72d71725a7f74f6ba620 AS mcp
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libmariadb3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=mcp-builder /build/mcp/fractalsql-mariadb-mcp /usr/local/bin/fractalsql-mariadb-mcp
# The MCP server's tool-surface and safety-annotation locks, beside the
# binary that reads them: without them the server refuses to start,
# because a missing lock is not a pass.
COPY --from=mcp-builder /build/mcp/.mcp-schema-lock /usr/local/bin/.mcp-schema-lock
COPY --from=mcp-builder /build/mcp/.mcp-safety-annotations-lock /usr/local/bin/.mcp-safety-annotations-lock
RUN install -m 0755 /usr/local/bin/fractalsql-mariadb-mcp \
             /usr/local/bin/fractalsql-mariadb-mcp.tmp \
 && mv -f /usr/local/bin/fractalsql-mariadb-mcp.tmp /usr/local/bin/fractalsql-mariadb-mcp \
 && fractalsql-mariadb-mcp --version

# --------------------------------------------------------------------
# Daemon: fractalsqld as the mysql user, with the reasoning plugin it
# loads at runtime. The socket and config live in the shared volume
# /run/fractalsql, which the mariadb container also mounts.
# --------------------------------------------------------------------
FROM mariadb:11.4@sha256:d1891ede5a559f1086f55053bb8cc1569b0298338c4d72d71725a7f74f6ba620 AS fractalsqld
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
FROM mariadb:11.4@sha256:d1891ede5a559f1086f55053bb8cc1569b0298338c4d72d71725a7f74f6ba620 AS demo
# python3 + python3-venv: the bench/ head-to-head runs in-container
# via a venv. libmariadb3: the MCP server's own client library.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libmariadb3 \
        mariadb-plugin-connect \
        python3 \
        python3-venv \
 && rm -rf /var/lib/apt/lists/*

COPY --from=service-builder /build/service/build/fractalsql.so /usr/lib/mysql/plugin/fractalsql.so
# The MCP server, so demo/mcp/call-tool.sh works out of the box in the
# demo container instead of needing a separate host build.
COPY --from=mcp-builder /build/mcp/fractalsql-mariadb-mcp /usr/local/bin/fractalsql-mariadb-mcp
# The MCP server's tool-surface and safety-annotation locks, beside the
# binary that reads them: without them the server refuses to start,
# because a missing lock is not a pass.
COPY --from=mcp-builder /build/mcp/.mcp-schema-lock /usr/local/bin/.mcp-schema-lock
COPY --from=mcp-builder /build/mcp/.mcp-safety-annotations-lock /usr/local/bin/.mcp-safety-annotations-lock
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
#
# /demo/ also carries the one-shot MCP client helpers
# (demo/mcp/call-tool.sh, demo/mcp/call-tool.py) and run_demo.sh, which
# runs the whole directory in one pass:
#   docker compose exec mariadb /demo/run_demo.sh
COPY demo/ /demo/

# The exec bit is set HERE, not carried in by COPY. This repo does not
# track file modes in git (core.fileMode is false), so the checked-in
# copies arrive 644 and the scripts would be unrunnable in the image --
# and a bare `cp` staging of an executable is exactly the trap that
# cost this repo a silent, platform-specific failure once already.
# `install -m 0755` sets the mode explicitly at staging time.
RUN install -m 0755 /demo/run_demo.sh /demo/run_demo.sh.tmp \
 && mv -f /demo/run_demo.sh.tmp /demo/run_demo.sh \
 && install -m 0755 /demo/mcp/call-tool.sh /demo/mcp/call-tool.sh.tmp \
 && mv -f /demo/mcp/call-tool.sh.tmp /demo/mcp/call-tool.sh \
 && install -m 0755 /demo/mcp/call-tool.py /demo/mcp/call-tool.py.tmp \
 && mv -f /demo/mcp/call-tool.py.tmp /demo/mcp/call-tool.py \
 && install -m 0755 /usr/local/bin/fractalsql-mariadb-mcp \
             /usr/local/bin/fractalsql-mariadb-mcp.tmp \
 && mv -f /usr/local/bin/fractalsql-mariadb-mcp.tmp /usr/local/bin/fractalsql-mariadb-mcp
