#!/usr/bin/env bash
# demo/demo-workload.sh
#
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# A production-shaped mixed workload against the docker-compose demo:
# concurrent simulated users, each issuing a realistic MIX of calls
# (mostly cheap search, occasionally expensive reasoning) sustained
# over real wall-clock time, with p50/p95/p99 latency per operation
# type at the end. This proves the pipeline HOLDS UP under concurrent,
# sustained, realistic-mix load, not just that a single call returns
# the right answer (demo.sql/benchmark.sql do that).
#
# Baseline hardware assumption: a self-hosted, air-gapped deployment on
# modest 2016+-era hardware with an 8-16GB GPU running the reasoning
# model locally (not a cloud GPU).
#
# Usage:
#   ./demo/demo-workload.sh
#   ./demo/demo-workload.sh --duration 300 --concurrency 10
#   ./demo/demo-workload.sh --ollama-host 192.168.1.50:11434
#   ./demo/demo-workload.sh --ollama-host 192.168.1.50:11434 --model gemma4:12b
#
# --ollama-host / --model: this extension's config is process env
# vars, not a sysvar/GUC, since MariaDB has no live-reloadable config
# mechanism a dlopen'd UDF library can hook into. docker-compose.yml's
# `mariadb` service sets
# FRACTALSQL_HTTP_URL / FRACTALSQL_HTTP_EMBED_URL / FRACTALSQL_HTTP_MODEL
# directly in its `environment:` YAML block, so the edit-and-revert
# logic below sed-patches those YAML lines instead of a my.cnf
# fragment or a GUC command-line flag. Same safety guarantee either
# way: always reverted on exit (success, failure, or Ctrl-C).
#
# Env overrides:
#   WORKLOAD_DURATION      seconds per run (default 120)
#   WORKLOAD_CONCURRENCY   concurrent simulated users (default 5)
#   WORKLOAD_CONTAINER     mariadb container name (default fractalsql-mariadb-mariadb-1)
#   WORKLOAD_DB / WORKLOAD_DBUSER

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DURATION="${WORKLOAD_DURATION:-120}"
CONCURRENCY="${WORKLOAD_CONCURRENCY:-5}"
CONTAINER="${WORKLOAD_CONTAINER:-fractalsql-mariadb-mariadb-1}"
DB="${WORKLOAD_DB:-fractalsql_demo}"
DBUSER="${WORKLOAD_DBUSER:-root}"
DBPASS="${WORKLOAD_DBPASS:-fractalsql}"
OLLAMA_HOST=""
MODEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --duration)     DURATION="$2"; shift ;;
    --concurrency)  CONCURRENCY="$2"; shift ;;
    --ollama-host)  OLLAMA_HOST="$2"; shift ;;
    --model)        MODEL="$2"; shift ;;
    -h|--help)
      sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# mariadb client, non-interactive, tab-separated, no headers: the
# direct equivalent of psql's -tA.
MDB=(docker exec -i "$CONTAINER" mariadb -u "$DBUSER" -p"$DBPASS" -D "$DB" -N -B)
G="\033[32m"; Y="\033[33m"; Z="\033[0m"
log() { printf "%b\n" "$*"; }

# --------------------------------------------------------------------
# --ollama-host / --model overrides, unconditionally reverted on exit
# (success, failure, or Ctrl-C); see the KNOWN GAP note above.
# --------------------------------------------------------------------
COMPOSE_EDITED=0
revert_compose_overrides() {
  [ "$COMPOSE_EDITED" -eq 1 ] || return 0
  log "\n${Y}Reverting docker-compose.yml overrides...${Z}"
  sed -i \
    -e "s|FRACTALSQL_HTTP_URL: http://${OLLAMA_HOST}/v1/chat/completions|FRACTALSQL_HTTP_URL: http://ollama:11434/v1/chat/completions|" \
    -e "s|FRACTALSQL_HTTP_EMBED_URL: http://${OLLAMA_HOST}/v1/embeddings|FRACTALSQL_HTTP_EMBED_URL: http://ollama:11434/v1/embeddings|" \
    -e "s|FRACTALSQL_HTTP_MODEL: ${MODEL}|FRACTALSQL_HTTP_MODEL: gpt-oss:20b|" \
    docker-compose.yml
  docker compose up -d --force-recreate mariadb >/dev/null 2>&1
  COMPOSE_EDITED=0
}
trap revert_compose_overrides EXIT INT TERM

if [ -n "$OLLAMA_HOST" ] || [ -n "$MODEL" ]; then
  [ -n "$OLLAMA_HOST" ] && log "Pointing reasoning/text-to-sql/embed at $OLLAMA_HOST for this run..."
  [ -n "$MODEL" ] && log "Using chat model $MODEL for reason/text-to-sql this run..."
  sed_args=()
  if [ -n "$OLLAMA_HOST" ]; then
    sed_args+=(-e "s|FRACTALSQL_HTTP_URL: http://ollama:11434/v1/chat/completions|FRACTALSQL_HTTP_URL: http://${OLLAMA_HOST}/v1/chat/completions|")
    sed_args+=(-e "s|FRACTALSQL_HTTP_EMBED_URL: http://ollama:11434/v1/embeddings|FRACTALSQL_HTTP_EMBED_URL: http://${OLLAMA_HOST}/v1/embeddings|")
  fi
  if [ -n "$MODEL" ]; then
    sed_args+=(-e "s|FRACTALSQL_HTTP_MODEL: gpt-oss:20b|FRACTALSQL_HTTP_MODEL: ${MODEL}|")
  fi
  sed -i "${sed_args[@]}" docker-compose.yml
  COMPOSE_EDITED=1
  if ! docker compose up -d --force-recreate mariadb; then
    log "\n${Y}docker compose up failed, see output above. Aborting before"
    log "running the workload against a container that never started.${Z}"
    exit 1
  fi
  ready=0
  for _ in $(seq 1 30); do
    "${MDB[@]}" -e "SELECT 1;" >/dev/null 2>&1 && { ready=1; break; }
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    log "\n${Y}mariadb never became reachable within 30s of starting --"
    log "aborting before running the workload against a dead container."
    log "Check: docker logs $CONTAINER${Z}"
    exit 1
  fi
fi

if ! "${MDB[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
  log "${Y}$CONTAINER is not reachable, is it running? (docker ps)${Z}"
  exit 1
fi

# --------------------------------------------------------------------
# Schema + seed data: a small relational schema for text-to-sql, a
# document table for embed/vectorizer, and a vector corpus for
# Sniper/Scout.
# --------------------------------------------------------------------
log "Setting up workload schema (200 customers, ~1000 orders, 300 documents, 5000 vectors)..."
"${MDB[@]}" -e "
DELETE FROM fractal_vectorizers WHERE source_table = 'wl_documents';
DROP TABLE IF EXISTS wl_orders, wl_customers, wl_documents, wl_vectors;

CREATE TABLE wl_customers (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(64) NOT NULL, status VARCHAR(16) NOT NULL);
INSERT INTO wl_customers (name, status)
SELECT CONCAT('customer_', gs),
       ELT(1 + FLOOR(RAND()*4), 'active','active','active','churned')
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 200) SELECT n AS gs FROM seq) s;

CREATE TABLE wl_orders (id INT AUTO_INCREMENT PRIMARY KEY, customer_id INT NOT NULL,
                         total_cents INT NOT NULL, status VARCHAR(16) NOT NULL, placed_at TIMESTAMP NOT NULL,
                         FOREIGN KEY (customer_id) REFERENCES wl_customers(id));
INSERT INTO wl_orders (customer_id, total_cents, status, placed_at)
SELECT FLOOR(RAND()*199 + 1), FLOOR(RAND()*20000 + 500),
       ELT(1 + FLOOR(RAND()*5), 'pending','paid','paid','paid','refunded'),
       NOW() - INTERVAL FLOOR(RAND() * 90) DAY
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 1000) SELECT n FROM seq) s;

CREATE TABLE wl_documents (id INT AUTO_INCREMENT PRIMARY KEY, body TEXT NOT NULL, embedding JSON);
INSERT INTO wl_documents (body)
SELECT CONCAT(ELT(1 + FLOOR(RAND()*8),
    'Quarterly infrastructure review: database latency remained within SLA across all regions.',
    'Customer escalation notes: billing discrepancy resolved after reconciling the March invoice.',
    'Release notes: the search API now supports diverse retrieval alongside nearest-neighbor lookup.',
    'Incident postmortem: a connection pool exhaustion event was traced to a retry storm.',
    'Onboarding guide: new team members should start with the architecture overview document.',
    'Security review: rotated API credentials for all third-party integrations this cycle.',
    'Product feedback summary: users requested clearer error messages on failed imports.',
    'Capacity planning: projected storage growth suggests a review is needed within two quarters.'),
    ' (doc ', gs, ')')
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 300) SELECT n AS gs FROM seq) s;

CREATE TABLE wl_vectors (id INT AUTO_INCREMENT PRIMARY KEY, emb_arr JSON);
-- max_recursive_iterations defaults to 1000; the vec_id sequence below
-- needs 5000, confirmed against a live server (silently truncates the
-- INSERT with ERROR 1931 otherwise, leaving wl_vectors empty).
SET SESSION max_recursive_iterations = 10000;
INSERT INTO wl_vectors (emb_arr)
SELECT JSON_ARRAYAGG(RAND() * 2 - 1)
FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 5000) SELECT n AS vec_id FROM seq) v
CROSS JOIN (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 128) SELECT n AS dim_idx FROM seq) d
GROUP BY v.vec_id;
" >/dev/null

VZID=$("${MDB[@]}" -N -e "CALL fractal_vectorizer_create('wl_documents', 'body', 'embedding', NULL, @vzid); SELECT @vzid;" 2>&1)
log "Vectorizer created (id=$VZID), backfilling ${G}300${Z} documents before the run starts..."
"${MDB[@]}" -e "CALL fractal_vectorizer_process_queue(500, 600);" >/dev/null 2>&1

# --------------------------------------------------------------------
# Worker: sustained, weighted-random mix of operations for DURATION
# seconds. Weighted 40/15/15/10/10/10 across operation types.
# --------------------------------------------------------------------
RESULTS_DIR="/tmp/fractalsql_demo_workload_$$"
rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"

REASON_PROMPTS=(
    "summarize the current customer status distribution in one sentence"
    "what pattern, if any, is notable in recent order activity"
    "suggest one thing worth double-checking about billing data quality"
)
T2S_QUESTIONS=(
    "how many active customers are there?"
    "what is the total value of paid orders?"
    "which customers have refunded orders?"
    "how many orders were placed in the last 30 days?"
)
EMBED_TEXTS=(
    "a customer reported a billing discrepancy on their latest invoice"
    "quarterly infrastructure review shows stable database latency"
    "new release adds diverse retrieval to the search API"
)

# psql's \timing prints a parseable "Time: N ms" line even on error;
# the mariadb client has no direct equivalent, so latency here is
# measured with the shell's own wall clock around the docker exec call
# instead of parsing client output, arguably more portable than
# relying on a specific client's timing-message format.
worker() {
    local wid="$1" end_at op t0 t1 out lat
    end_at=$(( $(date +%s) + DURATION ))
    : > "$RESULTS_DIR/worker_$wid.log"
    while [ "$(date +%s)" -lt "$end_at" ]; do
        local r=$(( RANDOM % 100 ))
        if   [ "$r" -lt 40 ]; then op=sniper
        elif [ "$r" -lt 55 ]; then op=scout
        elif [ "$r" -lt 70 ]; then op=embed
        elif [ "$r" -lt 80 ]; then op=insert
        elif [ "$r" -lt 90 ]; then op=t2s
        else                       op=reason
        fi

        t0=$(date +%s%3N)
        case "$op" in
            sniper)
                # Pure SFS convergence, no stored corpus needed -- '' as
                # the corpus arg is fractal_search's own documented
                # convergence-only mode (same pattern benchmark.sql uses).
                out=$("${MDB[@]}" -e "
                    SELECT fractal_search('',
                        (SELECT JSON_ARRAYAGG(RAND()*2-1) FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<128) SELECT n FROM seq) s),
                        1, '{\"iterations\":30,\"population_size\":30}');" 2>&1) ;;
            scout)
                # fractal_explore(corpus, query, params) takes the whole
                # corpus inline (no table-scanning UDF exists in MariaDB's
                # C ABI). Aggregate wl_vectors into that shape first,
                # same pattern benchmark.sql's @bench_corpus uses. Both
                # SET statements and the SELECT must share one client
                # invocation so the session vars survive between them.
                out=$("${MDB[@]}" -e "
                    SET @wl_corpus = (SELECT JSON_ARRAYAGG(emb_arr) FROM wl_vectors);
                    SET @wl_query  = (SELECT JSON_ARRAYAGG(RAND()*2-1) FROM (WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<128) SELECT n FROM seq) s);
                    SELECT p FROM JSON_TABLE(
                        (SELECT fractal_explore(@wl_corpus, @wl_query,
                            '{\"population_size\": 20, \"iterations\": 8, \"walk\": 0}')),
                        '\$.population[*]' COLUMNS (p JSON PATH '\$')
                    ) jt LIMIT 20;" 2>&1) ;;
            embed)
                local txt="${EMBED_TEXTS[$((RANDOM % ${#EMBED_TEXTS[@]}))]}"
                out=$("${MDB[@]}" -e "SELECT fractal_embed(CONNECTION_ID(), '$txt');" 2>&1) ;;
            insert)
                out=$("${MDB[@]}" -e "
                    INSERT INTO wl_documents (body)
                    VALUES (CONCAT('workload-generated note from worker $wid at ', NOW()));" 2>&1) ;;
            t2s)
                local q="${T2S_QUESTIONS[$((RANDOM % ${#T2S_QUESTIONS[@]}))]}"
                out=$("${MDB[@]}" -e "
                    CALL fractal_text_to_sql('$q', '[\"wl_customers\",\"wl_orders\"]', @wl_s, @wl_e);
                    SELECT @wl_s, @wl_e;" 2>&1) ;;
            reason)
                local p="${REASON_PROMPTS[$((RANDOM % ${#REASON_PROMPTS[@]}))]}"
                out=$("${MDB[@]}" -e "SELECT fractal_reason(CONNECTION_ID(), '$p');" 2>&1) ;;
        esac
        t1=$(date +%s%3N)
        lat=$(( t1 - t0 ))

        # mariadb -e exits non-zero and prints "ERROR" to stderr (folded
        # into $out via 2>&1) on failure. Check for that rather than
        # trusting the elapsed time alone, so a fast failure never
        # counts as a fast success.
        if printf '%s' "$out" | grep -qi '^ERROR'; then
            echo "$op fail 0" >> "$RESULTS_DIR/worker_$wid.log"
        else
            echo "$op ok $lat" >> "$RESULTS_DIR/worker_$wid.log"
        fi
    done
}

# Scheduler: drains the vectorizer queue on a fixed cadence, standing in
# for the MariaDB Event Scheduler / OS cron a real deployment would use
# (see docs/vectorizer-setup.md for the BYO-scheduler options).
scheduler() {
    local end_at=$(( $(date +%s) + DURATION ))
    while [ "$(date +%s)" -lt "$end_at" ]; do
        sleep 5
        "${MDB[@]}" -e "SELECT fractal_vectorizer_process_queue();" >/dev/null 2>&1
    done
}

log "\nRunning ${G}${CONCURRENCY}${Z} concurrent workers for ${G}${DURATION}s${Z}..."
log "Mix: 40% sniper / 15% scout / 15% embed / 10% insert / 10% text-to-sql / 10% reason\n"

pids=()
for w in $(seq 1 "$CONCURRENCY"); do
    worker "$w" &
    pids+=("$!")
done
scheduler &
pids+=("$!")
for p in "${pids[@]}"; do wait "$p"; done

# --------------------------------------------------------------------
# Aggregate: per-operation count, failures, and p50/p95/p99 latency (ms).
# --------------------------------------------------------------------
percentile() {
    local file="$1" p="$2" n idx
    n=$(wc -l < "$file")
    [ "$n" -eq 0 ] && { echo "-"; return; }
    idx=$(( (p * n + 99) / 100 ))
    [ "$idx" -lt 1 ] && idx=1
    [ "$idx" -gt "$n" ] && idx="$n"
    sed -n "${idx}p" "$file"
}

log "================================================================"
log "Results (${CONCURRENCY} workers x ${DURATION}s)"
log "================================================================"
printf "%-8s %8s %8s %10s %10s %10s\n" "op" "calls" "failed" "p50 ms" "p95 ms" "p99 ms"

cat "$RESULTS_DIR"/worker_*.log > "$RESULTS_DIR/all.log" 2>/dev/null || : > "$RESULTS_DIR/all.log"
total_calls=0
total_failed=0
for op in sniper scout embed insert t2s reason; do
    n=$(awk -v o="$op" '$1==o' "$RESULTS_DIR/all.log" | wc -l)
    [ "$n" -eq 0 ] && continue
    nfail=$(awk -v o="$op" '$1==o && $2=="fail"' "$RESULTS_DIR/all.log" | wc -l)
    awk -v o="$op" '$1==o && $2=="ok" {print $3}' "$RESULTS_DIR/all.log" | sort -n > "$RESULTS_DIR/$op.sorted"
    p50=$(percentile "$RESULTS_DIR/$op.sorted" 50)
    p95=$(percentile "$RESULTS_DIR/$op.sorted" 95)
    p99=$(percentile "$RESULTS_DIR/$op.sorted" 99)
    printf "%-8s %8s %8s %10s %10s %10s\n" "$op" "$n" "$nfail" "$p50" "$p95" "$p99"
    total_calls=$((total_calls + n))
    total_failed=$((total_failed + nfail))
done

log ""
log "Total: $total_calls calls, $total_failed failed, $(( total_calls / DURATION )) calls/sec aggregate throughput"
if [ "$total_failed" -eq 0 ]; then
    log "${G}No failures under this load.${Z}"
else
    log "${Y}$total_failed calls failed, if reasoning wasn't configured, that's expected"
    log "for reason/text-to-sql/embed; anything else is a real problem worth digging into.${Z}"
fi
log "================================================================"

rm -rf "$RESULTS_DIR"
