#!/usr/bin/env bash
# demo/run_demo.sh
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Runs every demo/*.sql content demo against the Docker demo
# container's own database, in one pass -- the "docker compose up -d;
# pull a model; run_demo.sh" button for a from-scratch look at
# everything in demo/, instead of running each file by hand.
#
# Usage (inside the demo container, matching docs/docker-demo.md's own
# `docker compose exec mariadb <cmd>` invocation style):
#   docker compose exec mariadb /demo/run_demo.sh
#   docker compose exec mariadb /demo/run_demo.sh --quiet
#   docker compose exec mariadb /demo/run_demo.sh --only demo-vertical-fleet-logistics.sql
#   docker compose exec mariadb /demo/run_demo.sh --skip demo-agents.sql,enterprise-stress.sql
#   docker compose exec mariadb /demo/run_demo.sh --include-response-modes
#
# Scope: this is specifically the Docker demo image's workflow. It
# assumes the demo container's own `fractalsql_demo` database (created
# by docker-compose.yml's MARIADB_DATABASE, with the UDFs and the 16
# agent procedures registered by the docker-entrypoint-initdb.d
# scripts) and /demo/*.sql (COPYed by docker/Dockerfile's demo stage).
# A bare host install has no /demo and no demo database -- run demos
# there manually per each file's own header.
#
# Reasoning-dependent sections need a model pulled first (docs/docker-
# demo.md step 2); without one, those calls fail with a clean
# model-not-found error and this script counts that file as a
# non-zero-exit result, same as any other failure -- it does not
# special-case or hide that (same stance demo-workload.sh's own header
# takes).
#
# A non-zero exit from one file is a "go read its log" signal, not
# proof of a bug. The mariadb client aborts the script at the first
# error, so one error anywhere in a file ends that file's run -- which
# means a file that demonstrates an error ON PURPOSE (a deliberate
# CHECK-constraint failure in demo-fractal-vector.sql, an
# unknown-metric rejection in demo-agents.sql, the enterprise-tier-
# gated demos showing the documented dormant path on a Community build
# with no enterprise_lib configured) can end early even though its
# own handlers would otherwise have caught the condition and carried
# on. Read the per-file log before assuming a bug.
#
# demo/response-modes.sql is SKIPPED BY DEFAULT, and
# --include-response-modes runs it as an ordinary file (one client
# session, the whole file) like every other demo. Two reasons it is
# not in the default pass:
#
#   1. It reuses demo.sql's demo_alerts table, so demo.sql has to have
#      run first. The default pass runs the files in name order, so
#      demo.sql does run first -- but only when the whole directory
#      is being run; a --only pass that lands on response-modes.sql
#      alone needs demo.sql run by hand first.
#   2. This engine's response-mode knob
#      (FSQL_REASONING_HTTP_RESPONSE_MODE) is environment-only and is
#      read in the DAEMON's process -- fractalsqld holds the reasoning
#      plugin and runs every UDF body, so the knob is fractalsqld's
#      environment, not mariadbd's -- and it is baked into the loaded
#      plugin context for that context's whole lifetime. Switching
#      modes therefore needs a daemon restart with a new environment,
#      which a client-side script cannot do to another process.
#
# Point 2 is why this file does NOT do what the knob suggests it
# should. This repo's own demo/response-modes.sql does not need the
# knob at all: its three sections demonstrate the plain-text,
# fenced-code and JSON shapes through the surface that already
# provides them (fractal_reason(), fractal_t2s_generate()'s internal
# fenced-code extraction, and prompt-level JSON validated with
# JSON_VALID()). See that file's own header for the full reasoning.
#
# demo/demo-workload.sh is NOT part of this: that is a separate
# concurrent load/stress tool (p50/p95/p99 latency under sustained
# load), not a content demo -- see its own header.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Connection config for the demo database. The demo container's own
# credentials are the defaults (docker-compose.yml's mariadb service:
# MARIADB_ROOT_PASSWORD=fractalsql, MARIADB_DATABASE=fractalsql_demo).
DB="${FSQL_DEMO_DB:-fractalsql_demo}"
DBUSER="${FSQL_DEMO_DBUSER:-root}"
DBPASS="${FSQL_DEMO_DBPASS:-fractalsql}"
DBHOST="${FSQL_DEMO_DBHOST:-127.0.0.1}"
DBPORT="${FSQL_DEMO_DBPORT:-3306}"
MARIADB_BIN="${FSQL_DEMO_MARIADB_BIN:-mariadb}"
LOG_DIR="${FSQL_DEMO_RUN_LOG_DIR:-/tmp/fractalsql_demo_run}"
TIMEOUT_SECS="${FSQL_DEMO_RUN_TIMEOUT:-300}"

QUIET=0
ONLY=""
SKIP=""
INCLUDE_RESPONSE_MODES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)                  QUIET=1 ;;
    --only)                   ONLY="$2"; shift ;;
    --skip)                   SKIP="$2"; shift ;;
    --include-response-modes) INCLUDE_RESPONSE_MODES=1 ;;
    -h|--help)
      sed -n '2,75p' "$0"; exit 0 ;;
    *) printf "run_demo.sh: unknown arg: %s (try --help)\n" "$1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v "$MARIADB_BIN" >/dev/null 2>&1; then
  printf "run_demo.sh: no %s client on PATH. Run this inside the demo\n" "$MARIADB_BIN" >&2
  printf "container -- docker compose exec mariadb /demo/run_demo.sh -- not on\n" >&2
  printf "a bare host install (see this script's own header).\n" >&2
  exit 2
fi

mkdir -p "$LOG_DIR"

# response-modes.sql is held out of the default pass (see this
# script's own header for why); --include-response-modes lets it
# through the normal loop, so --only/--skip apply to it as well.
ALWAYS_SKIP="response-modes.sql"
if [[ "$INCLUDE_RESPONSE_MODES" -eq 1 ]]; then
  ALWAYS_SKIP=""
fi

IFS=',' read -r -a only_list <<< "$ONLY"
IFS=',' read -r -a skip_list <<< "$SKIP"

should_run() {
  local base="$1"
  [[ -n "$ALWAYS_SKIP" && "$base" == "$ALWAYS_SKIP" ]] && return 1
  if [[ -n "$ONLY" ]]; then
    for o in "${only_list[@]}"; do [[ "$base" == "$o" ]] && return 0; done
    return 1
  fi
  for s in "${skip_list[@]}"; do [[ -n "$s" && "$base" == "$s" ]] && return 1; done
  return 0
}

# One demo file, one client session. The client's stdout AND stderr
# both go to the log; its exit code is the file's verdict. No --force:
# the client stops at the first error, which is exactly the "this file
# errored somewhere" signal the tally reports.
run_demo_file() {
  local sqlfile="$1" log="$2"
  timeout "$TIMEOUT_SECS" "$MARIADB_BIN" \
    --protocol=TCP -h "$DBHOST" -P "$DBPORT" \
    -u "$DBUSER" -p"$DBPASS" -D "$DB" \
    < "$sqlfile" > "$log" 2>&1
}

pass=0
fail=0
declare -a failed_files=()

for sqlfile in "$HERE"/*.sql; do
  base="$(basename "$sqlfile")"
  should_run "$base" || continue
  [[ "$QUIET" -eq 1 ]] || printf "=== %s ===\n" "$base"
  log="$LOG_DIR/$base.log"
  if run_demo_file "$sqlfile" "$log"; then
    pass=$((pass + 1))
    [[ "$QUIET" -eq 1 ]] || printf "  ok (%s)\n" "$log"
  else
    fail=$((fail + 1))
    failed_files+=("$base")
    [[ "$QUIET" -eq 1 ]] || printf "  exit != 0 -- see %s (may be an intentional demonstration; read it before assuming a bug)\n" "$log"
  fi
done

if [[ "$INCLUDE_RESPONSE_MODES" -ne 1 && "$QUIET" -ne 1 ]]; then
  printf "(skipped response-modes.sql -- it reuses demo.sql's demo_alerts table;\n"
  printf " pass --include-response-modes to run it too)\n"
fi

printf "\n"
printf "=== %s ok, %s non-zero exit, logs in %s ===\n" "$pass" "$fail" "$LOG_DIR"
if [[ "$fail" -gt 0 ]]; then
  printf "Non-zero-exit files (read the log before assuming a bug -- see this\n"
  printf "script's own header for the files known to error by design):\n"
  printf '  %s\n' "${failed_files[@]}"
fi

exit 0
