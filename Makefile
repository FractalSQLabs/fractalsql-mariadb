# fractalsql-mariadb Makefile: local (non-Docker) development build.
#
# v1: pure-C path. Statically links the vendored core archive at
# include/libfractalsql-community-minimal-c.a. No runtime LuaJIT dep.
#
# To refresh the vendored core release drop, re-deploy it into
# include/ (restores the archive, the public headers, and
# .artifacts.sha256 together).
#
# Build:   make
# Install: sudo make install
# Load:    mysql -u root -p < sql/install_udf.sql

CC      = gcc

# MariaDB headers: prefer mariadb_config, fall back to mysql_config
# (libmariadb-dev ships both).
MDB_CONFIG ?= mariadb_config
MDB_CFLAGS := $(shell $(MDB_CONFIG) --cflags 2>/dev/null)
ifeq ($(strip $(MDB_CFLAGS)),)
  MDB_CONFIG := mysql_config
  MDB_CFLAGS := $(shell $(MDB_CONFIG) --cflags 2>/dev/null)
endif
ifeq ($(strip $(MDB_CFLAGS)),)
  # Debian/Ubuntu's libmariadb-dev installs headers to
  # /usr/include/mysql; other distros use /usr/include/mariadb.
  MDB_CFLAGS := -I/usr/include/mysql -I/usr/include/mariadb
endif

# Vendored core archive selector. `community-sovereign-c` is the modern
# (glibc 2.34) build, a superset of `community-minimal-c` (confirmed via
# `nm`: it exports every minimal-tier symbol plus the v2 sovereign-tier
# additions this repo's UDF port links against: fsql_dimension_*,
# fsql_optimize_portfolio*, fsql_vascular_network, fsql_cortical_folding,
# fsql_nerve_plexus_metric, and fsql_morphological_complexity; see
# include/fractalsql_sql.h).
CORE_VARIANT ?= community-sovereign-c
# v1.2 platform layout: link the per-platform subdir
# include/<os>-<arch>/ (os = uname -s lower-cased, arch = uname -m, which
# is x86_64/aarch64 on Linux and arm64 on Apple Silicon, no translation).
# Falls back to the flat include/ layout during the dual-write window so
# this builds whether or not the subdir has been deployed yet; when core
# drops the flat layout (v1.3) the fallback resolves to the subdir.
FSQL_PLATFORM := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
CORE_ARCHIVE  := $(firstword \
    $(wildcard include/$(FSQL_PLATFORM)/libfractalsql-$(CORE_VARIANT).a) \
    include/libfractalsql-$(CORE_VARIANT).a)

# make COVERAGE=1: gcov-instrument every extension TU for lcov reporting
# (build_test.sh --coverage). --coverage must be on both the compile
# and link lines. Does not touch the vendored core archive -- only this
# extension's own SRCS get instrumented.
ifdef COVERAGE
  FSQL_COV_FLAGS := --coverage
else
  FSQL_COV_FLAGS :=
endif

# make ASAN=1 / UBSAN=1: sanitizer-instrument every extension TU
# (build_test.sh --asan / --ubsan). Same scoping as COVERAGE above --
# the vendored core archive is linked in as-is, matching this repo's
# own Windows build_test.ps1 -Asan/-Ubsan (Build-AsanExtension/
# Build-UbsanExtension) design, just ported to gcc/clang instead of
# MSVC/clang-cl. Mutually exclusive with each other and with COVERAGE
# (never combined in one build_test.sh invocation).
ifdef ASAN
  FSQL_SAN_FLAGS := -fsanitize=address -fno-omit-frame-pointer
else ifdef UBSAN
  FSQL_SAN_FLAGS := -fsanitize=undefined -fno-sanitize-recover=undefined
else
  FSQL_SAN_FLAGS :=
endif

# OpenSSL headers + libcrypto for fractalsql_enterprise.c's Ed25519
# signature check (<openssl/evp.h>). Linux: distro headers (libssl-dev,
# installed explicitly in docker/Dockerfile.test and already present as
# a transitive dependency of mariadb-server on the Debian/Ubuntu test
# image) and the shared -lcrypto. macOS: the SDK ships no OpenSSL
# headers and Homebrew's openssl@3 is keg-only, so point both compile
# and link at the keg, linking libcrypto.a statically -- matching the
# release build's posture, where a dynamic dep would record a Homebrew
# path end-user Macs are not guaranteed to have.
ifeq ($(shell uname -s),Darwin)
  FSQL_OPENSSL_DIR := $(shell brew --prefix openssl@3 2>/dev/null)
  ifeq ($(strip $(FSQL_OPENSSL_DIR)),)
    $(error darwin build needs Homebrew's openssl@3: brew install openssl@3)
  endif
  FSQL_OPENSSL_CFLAGS := -I$(FSQL_OPENSSL_DIR)/include
  FSQL_OPENSSL_LDFLAGS := $(FSQL_OPENSSL_DIR)/lib/libcrypto.a
else
  FSQL_OPENSSL_CFLAGS :=
  FSQL_OPENSSL_LDFLAGS := -lcrypto
endif

CFLAGS  = -Wall -Wextra -O3 -fPIC $(MDB_CFLAGS) -Iinclude $(FSQL_OPENSSL_CFLAGS) $(FSQL_COV_FLAGS) $(FSQL_SAN_FLAGS)
# -lpthread: fractalsql_session.c's connection-scoped ctx registry
# (for Discovery/Diversify) uses a pthread_mutex_t.
# -ldl: the vendored core archive's fsql_load_reasoning (Cognition
# tier) dlopen's the reasoning plugin internally.
# -lcrypto (Linux) / static libcrypto.a (macOS): see the FSQL_OPENSSL_*
# block just above CFLAGS for how each platform finds OpenSSL for
# fractalsql_enterprise.c's ent_verify_signature() (Ed25519 EVP verify).
LDFLAGS = -shared -lm -lpthread -ldl $(FSQL_OPENSSL_LDFLAGS) $(FSQL_COV_FLAGS) $(FSQL_SAN_FLAGS)

TARGET = fractalsql.so
SRCS   = src/fractalsql.c src/fractalsql_parse.c src/fractalsql_session.c src/fractalsql_vector.c src/fractalsql_cognition.c src/fractalsql_textsql.c src/fractalsql_enterprise.c
OBJS   = $(SRCS:.c=.o)

# MariaDB's plugin dir (mariadb_config --plugindir). Fall back to a
# common location if mariadb_config doesn't report one.
PLUGIN_DIR := $(shell $(MDB_CONFIG) --plugindir 2>/dev/null)
ifeq ($(strip $(PLUGIN_DIR)),)
  PLUGIN_DIR := /usr/lib/mysql/plugin
endif

all: verify-vendor $(TARGET)

$(CORE_ARCHIVE):
	@echo "ERROR: $(CORE_ARCHIVE) missing." >&2
	@echo "  Re-deploy the vendored core release drop into include/," >&2
	@echo "  which restores both the archive and .artifacts.sha256." >&2
	@exit 1


# Supply-chain verification. The vendored core release drop ships the
# archive plus `.artifacts.sha256` (sha256sum of every shipped
# .h/.a/.so). Verify it matches the bytes on disk before linking:
# catches a tampered .a in this repo's include/ at build time, both
# in `make` and in CI.
.PHONY: verify-vendor
verify-vendor:
	@if [ ! -f include/.artifacts.sha256 ]; then \
		echo "ERROR: include/.artifacts.sha256 missing." >&2; \
		echo "  Re-deploy the vendored core release drop into include/ to restore it." >&2; \
		exit 1; \
	fi
	# GNU coreutils' sha256sum on Linux; macOS ships no coreutils, only
	# Perl's shasum (/usr/bin/shasum), so fall back to `shasum -a 256`.
	# Both read the same "<hash>  <name>" manifest format. A missing
	# binary exits nonzero too, so the handler below still fires (which
	# is why this can't just assume sha256sum exists).
	@cd include && { \
		if command -v sha256sum >/dev/null 2>&1; then \
			sha256sum --quiet --check .artifacts.sha256; \
		else \
			shasum -a 256 -c .artifacts.sha256; \
		fi; \
	} || { \
		echo "ERROR: vendored artifact checksum mismatch in include/." >&2; \
		echo "  Possible causes: tampered .a/.so, partial deploy, or stale .sha256." >&2; \
		echo "  Re-deploy the vendored core release drop to recover." >&2; \
		exit 1; \
	}

$(TARGET): $(OBJS) $(CORE_ARCHIVE) verify-vendor
	$(CC) -o $@ $(OBJS) $(CORE_ARCHIVE) $(LDFLAGS)

%.o: %.c include/fractalsql.h include/fractalsql_sql.h src/fractalsql_session.h src/fractalsql_parse.h src/fractalsql_enterprise.h src/fractalsql_hmac.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

install: $(TARGET)
	cp $(TARGET) $(PLUGIN_DIR)

# Native VECTOR(n) vs Scout Mode, and the portable TEXT vs native
# VECTOR(n) storage/latency comparison. Both assume the extension is
# installed against a reachable MariaDB server and that Python deps from
# bench/requirements.txt are available; pass connection overrides via
# BENCH_ARGS, e.g. `make bench BENCH_ARGS="--host 127.0.0.1 --password
# <root password>"`. See bench/README.md.
PYTHON ?= python3
BENCH_ARGS ?=

.PHONY: bench bench-vector

bench:
	$(PYTHON) bench/data_gen.py --with-native-vector $(BENCH_ARGS)
	$(PYTHON) bench/head_to_head.py $(BENCH_ARGS)

bench-vector:
	$(PYTHON) bench/data_gen.py --with-native-vector $(BENCH_ARGS)
	$(PYTHON) bench/vector_type_head_to_head.py $(BENCH_ARGS)

.PHONY: all clean install verify-vendor
