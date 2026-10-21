# fractalsql-mariadb-mcp: one binary, mirroring the repo's own top-level
# Makefile/build.sh convention (7.1 — not CMake, no package manager).
# OpenSSL is linked unconditionally (there is no conditional-compile split in
# scope here, 13.5) but stdio-only deployments never call into it.

CXX      ?= g++
# OpenSSL's flags come from pkg-config. Where pkg-config (or its openssl entry) is missing, fall
# back to the plain libraries rather than linking without them, which fails on TLS_server_method.
OPENSSL_CFLAGS := $(shell pkg-config --cflags openssl 2>/dev/null)
OPENSSL_LIBS   := $(shell pkg-config --libs openssl 2>/dev/null || echo -lssl -lcrypto)
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra $(shell mariadb_config --cflags) $(OPENSSL_CFLAGS)
# src/vectors.cpp uses std::to_chars on a double (shortest round-trip form), which
# Apple's libc++ marks unavailable before macOS 13.3. CI exports
# MACOSX_DEPLOYMENT_TARGET=11.0 for the extension; the MCP server is a separate
# binary, so it carries its own, newer minimum (as package-darwin.sh does).
ifeq ($(shell uname -s),Darwin)
    CXXFLAGS += -mmacosx-version-min=13.3
endif

SRC      := $(wildcard src/*.cpp) $(wildcard src/adapters/*.cpp)
OBJ      := $(SRC:.cpp=.o)
LIBS     := $(shell mariadb_config --libs) $(OPENSSL_LIBS) -lpthread

ifdef COVERAGE
# -fprofile-update=atomic: the HTTP transport spawns a thread per connection,
# so gcov's default (non-atomic) profile counters are updated concurrently by
# several threads. That races the counters and corrupts the .gcda merge --
# the symptom is a coverage report with counts that are silently wrong.
# The atomic update is the only correct option for a multi-threaded binary.
CXXFLAGS += -O1 --coverage -fprofile-update=atomic
LDFLAGS  += --coverage
endif

# ASAN=1 / UBSAN=1 compose freely; TSAN=1 composes with UBSAN=1 but NOT
# with ASAN=1 (the runtimes cannot share a binary). UBSAN builds do not
# recover: the first undefined-behaviour hit aborts the server, so a
# build_test.sh gate cannot pass over it.
SANITIZE =
ifeq ($(ASAN),1)
  SANITIZE += -fsanitize=address
endif
ifeq ($(UBSAN),1)
  SANITIZE += -fsanitize=undefined -fno-sanitize-recover=undefined
endif
ifeq ($(TSAN),1)
  ifeq ($(ASAN),1)
    $(error TSAN=1 cannot be combined with ASAN=1 -- their runtimes cannot link into the same binary)
  endif
  SANITIZE += -fsanitize=thread
endif
ifneq ($(strip $(SANITIZE)),)
  CXXFLAGS := $(CXXFLAGS) -O1 -g -fno-omit-frame-pointer $(SANITIZE)
endif

fractalsql-mariadb-mcp: $(OBJ)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(OBJ) $(LIBS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -Ivendor -c $< -o $@

clean:
	rm -f $(OBJ) fractalsql-mariadb-mcp

.PHONY: clean