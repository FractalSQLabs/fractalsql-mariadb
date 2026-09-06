# fractalsql-mariadb Makefile: local (non-Docker) development build.
#
# v1: pure-C path. Statically links the vendored core archive at
# include/libfractalsql-community-minimal-c.a. No runtime LuaJIT dep.
#
# Refresh include/ from the foundry:
#     cd ../fractalsql-core
#     make validated-drop-native
#     ./scripts/deploy.sh --git fractalsql-mariadb
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
  MDB_CFLAGS := -I/usr/include/mariadb
endif

# Vendored core archive selector. `community-sovereign-c` is the modern
# (glibc 2.34) build, a superset of `community-minimal-c` (confirmed via
# `nm`: it exports every minimal-tier symbol plus the v2 sovereign-tier
# additions this repo's UDF port links against: fsql_dimension_*,
# fsql_optimize_portfolio*, fsql_vascular_network, fsql_cortical_folding,
# fsql_nerve_plexus_metric, and fsql_morphological_complexity; see
# include/fractalsql_sql.h). Override to `community-sovereign-c-legacy`
# for glibc 2.28 hosts.
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

CFLAGS  = -Wall -Wextra -O3 -fPIC $(MDB_CFLAGS) -Iinclude
# -lpthread: fractalsql_session.c's connection-scoped ctx registry
# (for Discovery/Diversify) uses a pthread_mutex_t. A no-op stub on
# glibc >= 2.34 (pthread merged into libc) but required on glibc 2.28
# (the -legacy CORE_VARIANT target) and on macOS/BSD libc.
# -ldl: the vendored core archive's fsql_load_reasoning (Cognition
# tier) dlopen's the reasoning plugin internally. Same glibc-2.34-merge
# story as -lpthread: a no-op stub on modern glibc, required on the
# -legacy CORE_VARIANT target. Harmless on macOS/BSD.
# -lcrypto: fractalsql_enterprise.c's ent_verify_signature() verifies
# the enterprise .so's detached Ed25519 signature via OpenSSL's EVP API
# (EVP_PKEY_new_raw_public_key/EVP_DigestVerify*). Requires libssl-dev
# (or the platform equivalent) at build time; already present as a
# transitive dependency of mariadb-server on the Debian/Ubuntu test
# image, called out explicitly here (and in docker/Dockerfile.test) so
# it isn't an implicit, silently-broken assumption.
LDFLAGS = -shared -lm -lpthread -ldl -lcrypto

TARGET = fractalsql.so
SRCS   = src/fractalsql.c src/fractalsql_session.c src/fractalsql_vector.c src/fractalsql_cognition.c src/fractalsql_textsql.c src/fractalsql_enterprise.c
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
	@echo "  Refresh from foundry:" >&2
	@echo "    cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-mariadb" >&2
	@exit 1


# Supply-chain verification. The vendored archive is dropped from
# fractalsql-core's deploy.sh together with `.artifacts.sha256`
# (sha256sum of every shipped .h/.a/.so). Verify it matches the
# bytes on disk before linking: catches a tampered .a in this
# repo's include/ at build time, both in `make` and in CI.
.PHONY: verify-vendor
verify-vendor:
	@if [ ! -f include/.artifacts.sha256 ]; then \
		echo "ERROR: include/.artifacts.sha256 missing, re-deploy from core" >&2; \
		echo "  cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-mariadb" >&2; \
		exit 1; \
	fi
	@cd include && sha256sum --quiet --check .artifacts.sha256 || { \
		echo "ERROR: vendored artifact checksum mismatch in include/." >&2; \
		echo "  Possible causes: tampered .a/.so, partial deploy, or stale .sha256." >&2; \
		echo "  Re-deploy from core to recover." >&2; \
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

.PHONY: all clean install verify-vendor
