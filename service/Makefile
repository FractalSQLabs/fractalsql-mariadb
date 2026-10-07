# SPDX-License-Identifier: Apache-2.0
# FractalSQL service build (spec: FRACTALSQL_SPLIT_PROCESS_SPEC.md).
#
# build/fractalsql.so   GPL-2.0-only UDF shim (runs inside mariadbd)
# build/fractalsqld     Apache-2.0 daemon (separate process). Compiles the
#                       adapter sources in ../src against the vendored core
#                       archive in ../include -- every UDF body runs here,
#                       not inside mariadbd.
#
# The shim is compiled without OpenSSL and without any core include path.

CC      ?= gcc
MDB_CONFIG ?= mariadb_config
MDB_CFLAGS := $(shell $(MDB_CONFIG) --cflags 2>/dev/null)
ifeq ($(strip $(MDB_CFLAGS)),)
  MDB_CFLAGS := -I/usr/include/mysql -I/usr/include/mariadb
endif

# Both overridable from the environment/command line for a cross build
# (e.g. an x86_64 build on an arm64 macOS runner, which has no x86_64
# `uname -m` to detect): FSQ_PLATFORM picks the vendored core archive,
# FSQ_ARCH_FLAGS (e.g. "-arch x86_64") is added to every compile and
# link below so the adapter objects, the daemon, and the core archive
# all end up the same architecture.
FSQ_PLATFORM ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
FSQ_ARCH_FLAGS ?=
CORE_ARCHIVE := $(firstword \
    $(wildcard ../include/$(FSQ_PLATFORM)/libfractalsql-community-sovereign-c.a) \
    ../include/libfractalsql-community-sovereign-c.a)

# OpenSSL for fsqlctl.c's <openssl/hmac.h> use and for
# fractalsql_enterprise.c's Ed25519 check (via ADAPTER_OBJS/CORE_ARCHIVE
# below). Homebrew's openssl@3 is keg-only, so Darwin needs its own path.
# FSQ_OPENSSL_DIR is overridable too: arm-Homebrew's openssl@3 keg has
# no x86_64 objects, so an x86_64 cross build needs a separately built
# tree (see release.yml's build-macos job) passed in explicitly.
ifeq ($(shell uname -s),Darwin)
  FSQ_OPENSSL_DIR ?= $(shell brew --prefix openssl@3 2>/dev/null)
  ifeq ($(strip $(FSQ_OPENSSL_DIR)),)
    $(error darwin build needs Homebrew's openssl@3: brew install openssl@3)
  endif
  FSQ_OPENSSL_CFLAGS  := -I$(FSQ_OPENSSL_DIR)/include
  FSQ_OPENSSL_LDFLAGS := $(FSQ_OPENSSL_DIR)/lib/libcrypto.a
else
  FSQ_OPENSSL_CFLAGS  :=
  FSQ_OPENSSL_LDFLAGS := -lcrypto
endif

BUILD   := build
GEN     := $(BUILD)/gen
ADAPTER_SRCS := $(wildcard ../src/*.c)
ADAPTER_OBJS := $(patsubst ../src/%.c,$(BUILD)/daemon/%.o,$(ADAPTER_SRCS))

WARN    := -Wall -Wextra -Werror -std=gnu11
CFLAGS  ?= -O2 -g

# make COVERAGE=1 / ASAN=1 / UBSAN=1: instrument the daemon (adapter
# objects + fractalsqld.c), for build_test.sh
# --coverage/--asan/--ubsan/--tsan. The shim is never instrumented: it
# has no logic of its own to cover.
ifdef COVERAGE
  FSQ_SAN_FLAGS := --coverage
else ifdef ASAN
  FSQ_SAN_FLAGS := -fsanitize=address -fno-omit-frame-pointer
else ifdef UBSAN
  FSQ_SAN_FLAGS := -fsanitize=undefined -fno-sanitize-recover=undefined
else ifdef TSAN
  FSQ_SAN_FLAGS := -fsanitize=thread
else
  FSQ_SAN_FLAGS :=
endif

SHIM_SRC   := shim/fractalsql_shim.c common/fsq_sha256.h protocol/fsq_protocol.h protocol/opcodes.def
DAEMON_SRC := daemon/fractalsqld.c common/fsq_sha256.h protocol/fsq_protocol.h protocol/opcodes.def

.PHONY: all shim daemon test scan clean

all: shim daemon $(BUILD)/frame_test $(BUILD)/interrupt_test $(BUILD)/fsqlctl

shim: $(BUILD)/fractalsql.so

daemon: $(BUILD)/fractalsqld

$(GEN)/shim_udfs.h $(GEN)/daemon_udfs.h $(GEN)/fsqlctl_functions.h: protocol/opcodes.def protocol/functions.def scripts/gen_udf.py
	python3 scripts/gen_udf.py $(GEN)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/fractalsql.so: $(SHIM_SRC) $(GEN)/shim_udfs.h | $(BUILD)
	$(CC) $(WARN) $(CFLAGS) $(FSQ_ARCH_FLAGS) -fPIC -shared $(MDB_CFLAGS) -I$(GEN) -o $@ shim/fractalsql_shim.c

$(BUILD)/daemon:
	mkdir -p $@

$(BUILD)/daemon/%.o: ../src/%.c | $(BUILD)/daemon
	$(CC) -w -O2 -g -fPIC $(FSQ_ARCH_FLAGS) $(MDB_CFLAGS) -I../include -I../src $(FSQ_OPENSSL_CFLAGS) $(FSQ_SAN_FLAGS) -c -o $@ $<

# The daemon TU is compiled to an object next to the adapter objects
# instead of on the link line, so its -coverage .gcno lands in
# $(BUILD)/daemon/ and lcov pairs it with the .gcda build_test.sh copies in.
$(BUILD)/daemon/fractalsqld.o: daemon/fractalsqld.c $(DAEMON_SRC) $(GEN)/daemon_udfs.h | $(BUILD)/daemon
	$(CC) -Wall -Wextra -Werror -std=gnu11 $(CFLAGS) $(FSQ_ARCH_FLAGS) $(MDB_CFLAGS) -I../include -I../src -I$(GEN) $(FSQ_SAN_FLAGS) -c -o $@ $<

$(BUILD)/fractalsqld: $(BUILD)/daemon/fractalsqld.o $(ADAPTER_OBJS) $(CORE_ARCHIVE) | $(BUILD)
	$(CC) -Wall -Wextra -Werror -std=gnu11 $(CFLAGS) $(FSQ_ARCH_FLAGS) $(MDB_CFLAGS) -I../include -I../src -I$(GEN) $(FSQ_SAN_FLAGS) \
	    -o $@ $(BUILD)/daemon/fractalsqld.o $(ADAPTER_OBJS) $(CORE_ARCHIVE) -lm -lpthread -ldl $(FSQ_OPENSSL_LDFLAGS)

$(BUILD)/fsqlctl: cli/fsqlctl.c $(GEN)/fsqlctl_functions.h | $(BUILD)
	$(CC) -Wall -Wextra -Werror -std=gnu11 -O2 $(FSQ_ARCH_FLAGS) -I$(GEN) $(FSQ_OPENSSL_CFLAGS) -o $@ cli/fsqlctl.c $(FSQ_OPENSSL_LDFLAGS)

$(BUILD)/frame_test: tests/frame_test.c common/fsq_sha256.h protocol/fsq_protocol.h protocol/opcodes.def | $(BUILD)
	$(CC) -Wall -Wextra -Werror -std=gnu11 -O2 $(FSQ_ARCH_FLAGS) -o $@ tests/frame_test.c

# The cancel-seam test links the parser TU and the seam TU directly -- no
# daemon, no MariaDB, no core archive (the same headers-only link the fuzz
# drivers use).
$(BUILD)/interrupt_test: tests/interrupt_test.c ../src/fractalsql_parse.c ../src/fractalsql_interrupt.c ../src/fractalsql_parse.h ../src/fractalsql_interrupt.h | $(BUILD)
	$(CC) -Wall -Wextra -Werror -std=gnu11 -O2 $(FSQ_ARCH_FLAGS) -I../src -o $@ tests/interrupt_test.c ../src/fractalsql_parse.c ../src/fractalsql_interrupt.c

test: all
	sh tests/spike_test.sh
	sh tests/cli_test.sh

scan: shim
	sh scripts/license_scan.sh
	sh scripts/boundary_check.sh
	sh scripts/symbol_scan.sh $(BUILD)/fractalsql.so

clean:
	rm -rf $(BUILD)
