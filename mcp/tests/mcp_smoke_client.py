#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND GPL-2.0-or-later
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""mcp_smoke gate's client driver for the fractalsql-mariadb-mcp C++ server.

Driven by build_test.sh's gate_39_mcp_smoke (and the matching PowerShell
gate): spawns the MCP server binary over its stdio transport against the
harness's running scratch cluster (fractalsqld + the mock reasoning
plugin Mdb-Setup / mdb_setup wired up), and mechanically enforces the
spec's accessibility invariant (1.7) plus a representative per-tier set
of real tools/call round trips in the SQL-level gates' happy-path/
error-path pairing style. Zero dependencies beyond the stdlib.

The client never imports the server's implementation -- it talks only
the newline-delimited JSON-RPC wire format (13.3.2), so it keeps working
across the implementation's own refactors.

Input (environment; the harness exports these -- it sets MARIADB_*,
FSQLCTL_* and the mock-LLM/probe env for its own scratch cluster ahead
of spawning this driver):
  MCP_SERVER_EXE     the fractalsql-mariadb-mcp binary just built
  MCP_HERE           the mcp/ directory (lock/manifest paths)
  MCP_SERVER_CWD     the server process's working directory (its
                     stderr JSON log lands here as mcp_server.log)
  MCP_MARIADB_BIN    the harness's mariadb client binary, for the
                     direct-SQL fixture setup that happens BEFORE the
                     server owns the cluster (the harness's own
                     scratch cluster on --host/--port/-D/--user)

Exits 0 on all-pass, 1 otherwise; prints PASS/FAIL lines the gates
relabel."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

_failures = 0


# Hand-maintained safety classification, deliberately NOT generated from the server
# and NOT the same file as mcp/.mcp-safety-annotations-lock: regenerating that lock
# records whatever a new tool declares, so it cannot force anyone to decide. This table
# can: tools/list is checked against it, and a tool missing from it, or whose hints
# differ from it, fails the smoke test. Edit it by hand when you add a tool.
#   read        readOnlyHint (no state changed)
#   write       changes state, but is not destructive (additive / recomputable)
#   destructive can discard or overwrite data or configuration; refused by FSQL_MCP_READ_ONLY
# The bool is openWorldHint: True if the tool reaches outside this DB connection
# (e.g. sends text to the embedding or reasoning provider).
EXPECTED_SAFETY = {
    "fractal_agent_allocate": ("write", True),
    "fractal_agent_anomaly_triage": ("write", True),
    "fractal_agent_data_analyst": ("destructive", True),
    "fractal_agent_detect_loop": ("read", False),
    "fractal_agent_detour_classify": ("write", True),
    "fractal_agent_diverse_portfolios": ("write", True),
    "fractal_agent_feedback_audit": ("destructive", False),
    "fractal_agent_network_coverage_alert": ("write", True),
    "fractal_agent_outlier_intercept": ("write", True),
    "fractal_agent_patient_deterioration_triage": ("write", True),
    "fractal_agent_plan_explore": ("write", True),
    "fractal_agent_rebalance_sibling": ("write", True),
    "fractal_agent_recall_hybrid": ("read", False),
    "fractal_agent_recommend_diverse": ("destructive", False),
    "fractal_agent_regime_triage": ("write", True),
    "fractal_agent_route_task": ("write", True),
    "fractal_agent_schedule_workload": ("write", True),
    "fractal_agent_track_anomaly": ("write", True),
    "fractal_agent_trajectory_predict": ("read", False),
    "fractal_audit_log": ("destructive", False),
    "fractal_audit_unpack": ("read", False),
    "fractal_change_point_detect": ("read", False),
    "fractal_cortical_folding": ("read", False),
    "fractal_cross_modal_search": ("read", False),
    "fractal_cycle_detect": ("read", False),
    "fractal_detect_collapse": ("read", False),
    "fractal_dimension_boxcount": ("read", False),
    "fractal_dimension_dfa": ("read", False),
    "fractal_dimension_drift": ("read", False),
    "fractal_diversify_disable": ("destructive", False),
    "fractal_diversify_enable": ("destructive", False),
    "fractal_diversify_set_params": ("destructive", False),
    "fractal_embed": ("write", True),
    "fractal_explain_result": ("read", False),
    "fractal_feedback_report": ("destructive", False),
    "fractal_hybrid_clinical_search": ("read", False),
    "fractal_isolate_background": ("destructive", False),
    "fractal_ledger_compact": ("destructive", False),
    "fractal_ledger_flush": ("destructive", False),
    "fractal_ledger_load": ("destructive", False),
    "fractal_ledger_reset_hard": ("destructive", False),
    "fractal_ledger_reset_soft": ("destructive", False),
    "fractal_ledger_shadow_count": ("read", False),
    "fractal_ledger_truth_count": ("read", False),
    "fractal_ledger_verify": ("read", False),
    "fractal_mine_topology_negatives": ("read", False),
    "fractal_morphological_complexity": ("read", False),
    "fractal_nerve_plexus_metric": ("read", False),
    "fractal_optimize_portfolio": ("read", False),
    "fractal_optimize_portfolio_multimodal": ("read", False),
    "fractal_optimize_portfolio_multimodal_ex": ("read", False),
    "fractal_optimize_portfolio_multimodal_pareto": ("read", False),
    "fractal_optimize_subset": ("read", False),
    "fractal_periodogram": ("read", False),
    "fractal_rag_agent": ("write", True),
    "fractal_reason": ("write", True),
    "fractal_schema_context": ("read", False),
    "fractal_search": ("read", False),
    "fractal_search_agent": ("write", True),
    "fractal_search_debug": ("read", False),
    "fractal_search_explore": ("read", False),
    "fractal_search_telemetry": ("read", False),
    "fractal_search_trajectory": ("read", False),
    "fractal_session_close": ("destructive", False),
    "fractal_spectrogram_entropy": ("read", False),
    "fractal_sql_agent": ("destructive", True),
    "fractal_state_fingerprint": ("read", False),
    "fractal_store_morphology": ("destructive", False),
    "fractal_tda_persistence_diagram": ("read", False),
    "fractal_text_to_sql": ("write", True),
    "fractal_vascular_network": ("read", False),
    "fractal_vector": ("read", False),
    "fractal_vector_from_text": ("read", False),
    "fractal_vector_hamming_distance": ("read", False),
    "fractal_vector_lp_distance": ("read", False),
    "fractal_vector_quantize_binary": ("read", False),
    "fractal_vector_quantize_int8": ("read", False),
    "fractal_vector_to_json": ("read", False),
    "fractal_vectorizer_create": ("destructive", False),
    "fractal_vectorizer_drop": ("destructive", False),
    "fractal_vectorizer_enqueue": ("destructive", False),
    "fractal_vectorizer_pause": ("destructive", False),
    "fractal_vectorizer_process_queue": ("destructive", False),
    "fractal_vectorizer_resume": ("destructive", False),
    "fractal_configure_reasoning": ("destructive", False),
    "fractal_daemon_config_get": ("read", False),
    "fractal_version": ("read", False),
    "fractal_config_get": ("read", False),
    "fractal_config_keys": ("read", False),
    "fractal_config_list": ("read", False),
    "fractal_config_reset": ("destructive", False),
    "fractal_config_set": ("destructive", False),
    "fractal_daemon_config_set": ("destructive", False),
}


def _safety_kind(a):
    if a.get("readOnlyHint") and a.get("destructiveHint"):
        return "contradiction"
    return "destructive" if a.get("destructiveHint") else ("read" if a.get("readOnlyHint") else "write")


def check(label: str, cond: bool) -> bool:
    global _failures
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        _failures += 1
    return bool(cond)


def mariadb(*statements: str) -> str:
    """Run fixture SQL over the harness's own scratch cluster."""
    host = os.environ["MARIADB_HOST"]
    port = os.environ["MARIADB_PORT"]
    user = os.environ.get("MARIADB_USER") or "root"
    database = os.environ["MARIADB_DATABASE"]
    cmd = [os.environ["MCP_MARIADB_BIN"],
           f"--host={host}", f"--port={port}", f"-u{user}", "-D", database,
           "--skip-ssl-verify-server-cert", "-N"]
    pw = os.environ.get("MARIADB_PASSWORD")
    if pw:
        cmd.append(f"--password={pw}")
    for s in statements:
        cmd += ["-e", s]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"fixture SQL failed: {r.stderr.strip()}")
    return r.stdout


def main() -> int:  # noqa: ANN201
    mcp_exe = os.environ["MCP_SERVER_EXE"]
    here = os.environ["MCP_HERE"]

    # -- phase 0: the 10.5 + 15.3 + 15.5 integrity locks, via the binary ----
    # The gate enforces the regenerate-and-commit workflow mechanically: the
    # binary recomputes all three projections over its registered tool
    # surface; a changed tool table without a regenerated committed lock
    # fails here. Lock/manifest writes must work with no database at all
    # (they are static over the registered surface), which is what lets
    # the empty-DB env below stand in for "not connected".
    lock_path = os.path.join(here, ".mcp-schema-lock")
    safety_path = os.path.join(here, ".mcp-safety-annotations-lock")
    if not check("phase0: committed .mcp-schema-lock exists", os.path.isfile(lock_path)):
        return 1
    if not check("phase0: committed .mcp-safety-annotations-lock exists",
                 os.path.isfile(safety_path)):
        return 1
    with tempfile.TemporaryDirectory() as td:
        regenerated = os.path.join(td, "schema.tmp")
        r = subprocess.run(
            [mcp_exe, "--write-schema-lock", "--schema-lock-path", regenerated],
            env=dict(os.environ, MARIADB_HOST="", MARIADB_PORT="",
                     MARIADB_DATABASE="", MARIADB_USER="", MARIADB_PASSWORD=""),
            capture_output=True, text=True)
        if not check("phase0: --write-schema-lock regenerates cleanly", r.returncode == 0):
            return 1
        committed = open(lock_path, encoding="utf-8").read().strip()
        check("phase0: lock matches the registered tool set (10.5 workflow)",
              committed != "" and committed == open(regenerated).read().strip())
        regenerated_safety = os.path.join(td, "safety.tmp")
        r = subprocess.run(
            [mcp_exe, "--write-safety-annotations-lock"],
            env=dict(os.environ,
                     MARIADB_HOST="", MARIADB_PORT="",
                     MARIADB_DATABASE="", MARIADB_USER="", MARIADB_PASSWORD="",
                     FSQL_MCP_SAFETY_LOCK=regenerated_safety),
            capture_output=True, text=True)
        ok = (r.returncode == 0
              and open(safety_path, encoding="utf-8").read()
                  == open(regenerated_safety).read())
        check("phase0: safety annotations match the registered surface (15.3)", ok)
        regenerated_manifest = os.path.join(td, "manifest.tmp")
        r = subprocess.run(
            [mcp_exe, "--write-manifest"],
            env=dict(os.environ,
                     MARIADB_HOST="", MARIADB_PORT="",
                     MARIADB_DATABASE="", MARIADB_USER="", MARIADB_PASSWORD="",
                     FSQL_MCP_MANIFEST=regenerated_manifest),
            capture_output=True, text=True)
        committed_manifest = os.path.join(here, "manifest.json")
        ok = (r.returncode == 0
              and os.path.isfile(committed_manifest)
              and open(committed_manifest, encoding="utf-8").read()
                  == open(regenerated_manifest).read())
        check("phase0: manifest matches the registered surface (15.5)", ok)

    # -- phase 1: the CLI / startup surface ---------------------------------
    # One-shot invocations that must answer without a database, and the
    # catalog-narrowing knobs (15.1) that decide which tools a session
    # can even see. The narrowing is asserted HERE, against the binary's
    # own --list-tools output, because it is a startup-time decision:
    # a narrowed-down server never registers the excluded tools at all,
    # so a tools/list call against a narrowed server would prove the
    # same thing only indirectly.
    r = subprocess.run([mcp_exe, "--version"], capture_output=True, text=True)
    check("phase1: --version prints a version and exits 0",
          r.returncode == 0 and r.stdout.strip() != "")
    r = subprocess.run([mcp_exe, "--help"], capture_output=True, text=True)
    check("phase1: --help prints usage and exits 0",
          r.returncode == 0 and "Usage:" in r.stdout)
    r = subprocess.run([mcp_exe, "--no-such-flag"], capture_output=True, text=True)
    check("phase1: an unknown flag is refused with a nonzero exit",
          r.returncode != 0 and "unknown argument" in r.stderr.lower())
    # --list-tools must not need a database either: it is a static
    # projection over the registered surface, same as the lock writes.
    r = subprocess.run(
        [mcp_exe, "--list-tools"],
        env=dict(os.environ, MARIADB_HOST="", MARIADB_PORT="",
                 MARIADB_DATABASE="", MARIADB_USER="", MARIADB_PASSWORD=""),
        capture_output=True, text=True)
    listed = r.stdout
    check("phase1: --list-tools works with no database and lists tools",
          r.returncode == 0 and "fractal_version" in listed)
    # The tool whitelist (--tool) and the category filter (--category)
    # are the two narrowing knobs; each must REMOVE tools from the
    # listed surface, not merely reorder it.
    r = subprocess.run(
        [mcp_exe, "--list-tools", "--tool", "fractal_version"],
        env=dict(os.environ, MARIADB_HOST="", MARIADB_PORT="",
                 MARIADB_DATABASE="", MARIADB_USER="", MARIADB_PASSWORD=""),
        capture_output=True, text=True)
    narrowed = r.stdout
    check("phase1: --tool narrows the tool surface to the whitelist",
          r.returncode == 0 and "fractal_version" in narrowed
          and "fractal_reason" not in narrowed)
    r = subprocess.run(
        [mcp_exe, "--list-tools", "--category", "admin"],
        env=dict(os.environ, MARIADB_HOST="", MARIADB_PORT="",
                 MARIADB_DATABASE="", MARIADB_USER="", MARIADB_PASSWORD=""),
        capture_output=True, text=True)
    cat_narrowed = r.stdout
    check("phase1: --category narrows the tool surface to that category",
          r.returncode == 0 and cat_narrowed.strip() != ""
          and "fractal_reason" not in cat_narrowed)

    # -- fixture setup (direct SQL, before the server sees the tables) ------
    mariadb("""
    DROP TABLE IF EXISTS mcp_sm_docs;
    CREATE TABLE mcp_sm_docs (
      id BIGINT PRIMARY KEY AUTO_INCREMENT,
      title VARCHAR(64),
      emb TEXT
    );
    INSERT INTO mcp_sm_docs (title, emb) VALUES
      ('alpha','[1.0,0.0,0.0]'),('beta','[0.0,1.0,0.0]'),
      ('gamma','[0.9,0.1,0.0]'),('delta','[0.15,0.15,0.12]');
    DROP TABLE IF EXISTS mcp_sm_logs;
    CREATE TABLE mcp_sm_logs (ts BIGINT, host VARCHAR(64), metric DOUBLE);
    """)
    # 96-point bimodal-ish series for the anomaly agents. (seq_1_to_96's
    # column is named `seq`, not `x` -- caught live on the first gate run.)
    mariadb("INSERT INTO mcp_sm_logs (ts, host, metric) "
            "SELECT seq*2, 'host-1', 50.0 + (seq % 8) * 1.3 + IF(seq > 48, 30.0, 0.0) "
            "FROM seq_1_to_96")
    # memory fixture for recall_hybrid's cohort filter: one multi-row
    # INSERT (the client's -e args concatenate, so separate statements
    # would arrive as one malformed string -- caught live).
    mem_rows = ", ".join(
        "('mem-i%d','[%f,%f,0.0]')" % (i, 1.0 + i * 0.001, 0.5 - i * 0.001)
        for i in range(24))
    mariadb("INSERT INTO mcp_sm_docs (title, emb) VALUES " + mem_rows)

    # -- spawn the server (stdio transport, 1.1) ----------------------------
    server_log_path = os.path.join(os.environ["MCP_SERVER_CWD"],
                                   "mcp_server.log")
    server_log = open(server_log_path, "w", encoding="utf-8")
    env = dict(os.environ)
    env.pop("LD_PRELOAD", None)  # see gate 01's sanitizer note
    # This client exercises the configuration-writing tools (it points the
    # reasoning plugin at a local endpoint, swaps the model, and so on), and
    # those writes are refused unless the server is run with the
    # configuration-writes switch set to "all". The default ("safe") allows
    # only the model names and the think mode, which is not enough for what
    # this client does.
    env["FSQL_MCP_CONFIG_WRITES"] = "all"
    proc = subprocess.Popen(
        [mcp_exe],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=server_log,
        cwd=os.environ["MCP_SERVER_CWD"], env=env, text=True, bufsize=1,
    )

    _req = [0]
    _queue = []

    def _reader(proc) -> None:  # noqa: ANN001
        for line in proc.stdout:
            _queue.append(line)
        _queue.append(None)  # EOF sentinel

    threading.Thread(target=_reader, args=(proc,), daemon=True).start()

    def send(msg: dict) -> None:
        if msg.get("method") == "tools/call":
            p = msg.get("params") or {}
            _RECORDED_CALLS.append((p.get("name"), p.get("arguments") or {}))
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv(deadline: float | None = None):  # noqa: ANN201
        """Queue-backed read so polls can bound their wait (a cancelled
        in-flight call must deliver no result to wait on)."""
        start = time.monotonic()
        while True:
            if _queue:
                line = _queue.pop(0)
                if line is None:
                    print("FAIL server closed stdout; server log tail:")
                    print(open(server_log_path, encoding="utf-8").read()[-2000:])
                    return None
                return json.loads(line)
            if deadline is not None and time.monotonic() - start > deadline:
                return {"__timeout__": True}
            time.sleep(0.02)

    def wait_for(rid, timeout: float = 30.0):  # noqa: ANN201
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            r = recv(deadline=0.2)
            if r is None or r.get("__timeout__"):
                if r is None:
                    return None
                continue
            if not isinstance(r, dict):
                return None
            if r.get("id") == rid:
                return r
        return {"__timeout__": True}

    def call(name: str, args: dict, timeout: float = 30.0):  # noqa: ANN201
        _req[0] += 1
        rid = 1000 + _req[0]
        send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
              "params": {"name": name, "arguments": args}})
        resp = wait_for(rid, timeout)
        # Surface the engine's own error text next to any FAIL the gate
        # prints for this call: the error text is the diagnosis (1.6's
        # verbatim engine errors are supposed to carry actionable text).
        if isinstance(resp, dict) and (resp.get("result") or {}).get("isError"):
            print("  [error-text] "
                  + (resp["result"].get("content") or [{}])[0].get("text", ""))
            if resp["result"].get("structuredContent"):
                print("  [error-class] "
                      + str(resp["result"]["structuredContent"]))
        return resp

    try:
        # -- initialize handshake --------------------------------------
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "gate-smoke", "version": "0"}}})
        init = recv()
        if not check("initialize handshake echoes the requested "
                     "protocolVersion",
                     init is not None
                     and init.get("result", {}).get("serverInfo", {})
                     .get("name") == "fractalsql-mariadb-mcp"
                     and init.get("result", {}).get("protocolVersion")
                     == "2025-06-18"):
            finish(proc, server_log)
            return 1
        send({"jsonrpc": "2.0", "id": 1, "method": "ping",
              "params": {}})
        pong = wait_for(1)
        check("ping liveness probe responds with an empty {}", pong is not None
              and pong.get("result") == {})

        # -- the accessibility invariant (1.7), mechanically ----------
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        listed = recv()["result"]["tools"]
        check("tools/list: the full engine-filtered catalog (93 tools)",
              len(listed) == 93)
        anonymous = [t["name"] for t in listed
                     if not (t.get("description") or "").strip()
                     or "properties" not in t["inputSchema"]]
        check("1.7 accessibility invariant: every tool has a non-empty "
              "description and a complete inputSchema.properties", not anonymous)
        # The marker says "this tool takes no arguments", so it must be
        # present exactly on the tools whose schema has no properties - and
        # absent on the ones that do take an argument, such as the
        # session-scoped tools that carry the optional state handle.
        mismarked = [t["name"] for t in listed
                     if bool(t["inputSchema"].get("x-fractalsql-no-arguments"))
                     != (not t["inputSchema"].get("properties"))]
        zero_arg = [t for t in listed
                    if t["inputSchema"].get("x-fractalsql-no-arguments")]
        check("1.7: the no-arguments marker matches the tool's real shape",
              not mismarked and len(zero_arg) >= 1)
        tiers = {t.get("_meta", {}).get("x-fractalsql-tier") for t in listed}
        check("tier metadata groups tools like the docs teach (1.7)",
              tiers == {"discovery", "cognition", "agency", "analytics",
                        "enterprise", "vectorizer", "admin"})
        classes = {t.get("_meta", {}).get("x-fractalsql-class") for t in listed}
        tiers_meta = {t.get("_meta", {}).get("x-fractalsql-retry-tier") for t in listed}
        # 11.2/12.0: retry tiers are a MariaDB-only exposure -- present on
        # EVERY tool, and only one of the shim's three tiers.
        check("x-fractalsql-class + x-fractalsql-retry-tier present on "
              "every tool; retry tiers limited to the shim's own set",
              classes == {"cheap", "expensive"}
              and tiers_meta == {"pure", "stateful", "no-retry"})
        annotated = {t["name"] for t in listed
                     if (t.get("annotations") or {}).get("destructiveHint") is True}
        heavy = [n for n in ["fractal_ledger_reset_hard", "fractal_ledger_compact",
                             "fractal_vectorizer_drop", "fractal_daemon_config_set"]
                 if n in annotated]
        check("15.2/6: destructiveHint present on the heavy/destructive tools",
              len(heavy) >= 3)
        tools_by_name = {t["name"]: t for t in listed}
        # safety table: every tool's hints must match EXPECTED_SAFETY
        explicit = ("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")
        check("EXPECTED_SAFETY classifies exactly the tools served (a new tool "
              "needs a row there): unclassified="
              + str(sorted(set(tools_by_name) - set(EXPECTED_SAFETY)))[:160]
              + " stale=" + str(sorted(set(EXPECTED_SAFETY) - set(tools_by_name)))[:160],
              set(EXPECTED_SAFETY) == set(tools_by_name))
        check("every tool sends all four hints explicitly (an omitted hint "
              "defaults to destructive/open-world in the MCP spec)",
              all(all(isinstance((t.get("annotations") or {}).get(k), bool) for k in explicit)
                  for t in listed))
        safety_drift = {n: [(_safety_kind(t.get("annotations") or {}),
                             (t.get("annotations") or {}).get("openWorldHint")),
                            EXPECTED_SAFETY.get(n)]
                        for n, t in tools_by_name.items()
                        if (_safety_kind(t.get("annotations") or {}),
                            (t.get("annotations") or {}).get("openWorldHint"))
                        != EXPECTED_SAFETY.get(n)}
        check("every tool's hints match EXPECTED_SAFETY (got, expected)"
              + (": " + str(dict(list(safety_drift.items())[:3])) if safety_drift else ""),
              not safety_drift)
        reasoning_tools = [n for n in ["fractal_reason", "fractal_agent_route_task",
                                       "fractal_sql_agent"]
                           if n in tools_by_name]
        check("15.2: openWorldHint/secretHint on the reasoning-capable tools",
              len(reasoning_tools) == 3
              and all(tools_by_name[n]["annotations"].get("openWorldHint")
                      and tools_by_name[n]["annotations"].get("secretHint")
                      for n in reasoning_tools))
        # 15.2's openWorldHint is applied PER TOOL, and it means exactly one
        # thing: this call reaches an entity outside this database -- a
        # chat-LLM or an embedding-provider dispatch. The set below is every
        # tool that does. It is pinned here on purpose: the safety lock
        # (phase0) records the same column, so a flip in either direction
        # fails a gate.
        provider_crossing = {t["name"] for t in listed
                             if t.get("annotations", {}).get("openWorldHint")}
        check("15.2: openWorldHint marks exactly the provider-crossing tools",
              provider_crossing == {
                  # the cognition tier's three provider dispatches
                  "fractal_reason", "fractal_embed", "fractal_text_to_sql",
                  # the agency tier's own provider dispatches
                  "fractal_search_agent", "fractal_rag_agent",
                  "fractal_sql_agent", "fractal_agent_plan_explore",
                  # the thirteen reasoning agents
                  "fractal_agent_allocate", "fractal_agent_anomaly_triage",
                  "fractal_agent_data_analyst", "fractal_agent_detour_classify",
                  "fractal_agent_diverse_portfolios",
                  "fractal_agent_network_coverage_alert",
                  "fractal_agent_outlier_intercept",
                  "fractal_agent_patient_deterioration_triage",
                  "fractal_agent_rebalance_sibling", "fractal_agent_regime_triage",
                  "fractal_agent_route_task", "fractal_agent_schedule_workload",
                  "fractal_agent_track_anomaly"})
        plan_explore_ann = tools_by_name.get("fractal_agent_plan_explore", {}) \
                                .get("annotations", {})
        check("15.2: plan_explore crosses the embedding provider but carries "
              "no secretHint (an embedded label is the caller's own data)",
              plan_explore_ann.get("openWorldHint")
              and not plan_explore_ann.get("secretHint"))
        # 15.2's idempotentHint is DERIVED, and it follows readOnlyHint: a
        # read touches nothing, so repeating it changes nothing. The two
        # Diversify session-state tools are idempotent without being
        # read-only. And no provider-crossing tool is idempotent -- a repeat
        # re-dispatches a paid call, which is the client's decision.
        read_only = {t["name"] for t in listed
                     if t.get("annotations", {}).get("readOnlyHint")}
        idempotent = {t["name"] for t in listed
                      if t.get("annotations", {}).get("idempotentHint")}
        check("15.2: every read-only tool is idempotent (a read has no "
              "additional effect when repeated)",
              read_only <= idempotent)
        check("15.2: the Diversify pair is idempotent without being "
              "read-only (enabling twice leaves the same state on)",
              {"fractal_diversify_enable", "fractal_diversify_disable"}
              <= idempotent)
        check("15.2: no provider-crossing tool is idempotent (a repeat "
              "re-dispatches a paid call)",
              not (provider_crossing & idempotent))
        # The read-only posture of the two Diversify-driven agents: both
        # change this session's state, so neither is a read-only tool.
        stateful_agents = {"fractal_agent_recommend_diverse",
                           "fractal_agent_feedback_audit"}
        check("15.2: the two Diversify-driven agents are not read-only "
              "(they change session state)",
              not (stateful_agents & read_only))
        pure_reads = {"fractal_agent_detect_loop",
                      "fractal_agent_trajectory_predict",
                      "fractal_schema_context"}
        check("15.2: the pure-computation and plain-read tools are read-only",
              pure_reads <= read_only)
        agent_partial = [t for t in listed
                         if "reasoning_step_failed" in t.get("description", "")]
        check("S-FT-004: the honoring agents' descriptions state the partial "
              "shape; the two non-reasoning agents do not",
              len(agent_partial) >= 12
              and "fractal_agent_plan_explore" not in {
                  t["name"] for t in agent_partial}
              and "fractal_agent_trajectory_predict" not in {
                  t["name"] for t in agent_partial})

        # -- sanity check (plugin docs' one-liner) ---------------------
        r = call("fractal_version", {})
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("sanity check: fractal_version returns a real "
              "edition/version",
              sc is not None and not (r["result"].get("isError"))
              and sc.get("edition") == "Community")

        # -- Analytics: fractal_spectrogram_entropy ---------------------
        # A period-4 tone; the adapter wraps the bare SQL array as
        # {"entropy":[...]}. 96 samples, window 32, hop 16 -> 5 frames.
        tone = [[1, 0, -1, 0][i % 4] for i in range(96)]
        r = call("fractal_spectrogram_entropy",
                 {"series": tone, "window": 32, "hop": 16})
        ent = ((r["result"].get("structuredContent") or {}).get("entropy")
               if r is not None and not r["result"].get("isError") else None)
        check("Analytics: fractal_spectrogram_entropy returns an in-range "
              "per-frame array", isinstance(ent, list) and len(ent) == 5
              and all(0.0 <= v <= 1.0 for v in ent))
        r = call("fractal_spectrogram_entropy", {"series": tone, "window": 4})
        check("Analytics: fractal_spectrogram_entropy rejects window < 8 "
              "as an error, not a result",
              r is not None and r["result"].get("isError") is True)

        # -- Discovery tier --------------------------------------------
        r = call("fractal_search", {"query": [0.6, 0.8],
                                    "corpus": [[1, 0], [0, 1], [0.6, 0.8]],
                                    "k": 3})
        check("Discovery: fractal_search over an inline corpus returns "
              "the top_k row with the query itself on top",
              r is not None and not r["result"].get("isError")
              and (r["result"]["structuredContent"] or {}).get("top_k")
              and r["result"]["structuredContent"]["top_k"][0]["idx"] == 2)
        r = call("fractal_search", {"query": [0.6, 0.8]})
        check("Discovery: pure Sniper convergence (corpus omitted) returns "
              "best_point",
              r is not None and not r["result"].get("isError")
              and "best_point" in (r["result"]["structuredContent"] or {}))
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.15, 0.15, 0.1], "k": 2000})
        check("1.5 row ceiling: over-ceiling k is a schema error naming "
              "FSQL_MCP_MAX_ROWS_CEILING",
              r is not None and r["result"].get("isError")
              and r["result"]["structuredContent"]["error_class"] == "schema"
              and "FSQL_MCP_MAX_ROWS_CEILING"
              in r["result"]["content"][0]["text"])
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [1.0, 0.0, 0.0], "k": 2})
        sc = r["result"]["structuredContent"] if r else None
        check("Discovery: telemetry's nearest neighbor is the real row "
              "and k=2 returns exactly it",
              isinstance(sc, list) and len(sc) == 2
              and isinstance(sc[0], dict)
              and sc[0]["doc_id"] == 1)
        r = call("fractal_hybrid_clinical_search",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.9, 0.9, 0.9], "doc_ids": [1, 4], "k": 5})
        sc = r["result"]["structuredContent"] if r else None
        check("Discovery: cohort restriction applies to the scan",
              isinstance(sc, list)
              and {x["doc_id"] for x in sc} <= {1, 4})

        # -- Cognition tier (against the harness's mock reasoning) -----
        r = call("fractal_reason", {"query": "reply with a short confirmation"})
        check("Cognition: fractal_reason reaches the mock reasoning "
              "provider (text comes back verbatim)",
              r is not None and not r["result"].get("isError")
              and "SELECT 1" in r["result"]["content"][0]["text"])
        r = call("fractal_text_to_sql",
                 {"question": "how many docs are in mcp_sm_docs",
                  "table_names": ["mcp_sm_docs"]})
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("Cognition: fractal_text_to_sql returns validated SQL text "
              "(GENERATE -> ALLOWLIST -> mechanical check via the mock)",
              sc is not None and not (r.get("result") or {}).get("isError")
              and str(sc.get("sql") or sc.get("out_sql") or "").strip()
              == "SELECT 1")

        # -- a Community agent (no-LLM tier) ---------------------------
        r = call("fractal_agent_recall_hybrid",
                 {"mem_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [1.0, 0.0, 0.0], "filter_col": "title",
                  "filter_val": "mem-i0", "k": 2, "content_col": "title"})
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("Agency (community, no-LLM): recall_hybrid returns the real "
              "cohort row",
              isinstance(sc, list) and sc
              and "mem-i0" in json.dumps(sc[0]))
        r = call("fractal_agent_anomaly_triage",
                 {"log_table": "mcp_sm_logs", "metric_col": "metric",
                  "time_col": "ts", "filter_col": "host",
                  "filter_val": "host-1", "baseline_window": 32})
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        try:
            summary = json.dumps(json.loads((sc or {}).get("triage_summary")
                                            or ""))
        except Exception:  # noqa: BLE001
            summary = str((sc or {}).get("triage_summary") or "")
        check("Agency: anomaly_triage composes drift -> reason (the mock "
              "reply landed in triage_summary)",
              isinstance(sc, dict) and sc.get("threat_score") is not None
              and "SELECT 1" in summary
              and sc.get("reasoning_step_failed") is None)

        # -- the enterprise clean-error path (6/2.3) -------------------
        r = call("fractal_ledger_reset_hard", {})
        check("Enterprise: gated tool returns the clean 'enterprise tier "
              "not loaded' condition, not a crash or a silent no",
              r is not None and r["result"].get("isError")
              and "enterprise tier not loaded"
              in r["result"]["content"][0]["text"]
              and r["result"]["structuredContent"]["error_class"] == "engine")
        r = call("fractal_ledger_verify", {"kind": 1})
        check("Enterprise: fractal_ledger_verify is pure read-only and "
              "works without the enterprise library",
              r is not None and not r["result"].get("isError"))

        # -- error-taxonomy pairing (1.6/11.1) --------------------------
        r = call("fractal_agent_anomaly_triage",
                 {"log_table": "mcp_sm_logs", "metric_col": "metric",
                  "time_col": "ts", "filter_col": "host",
                  "filter_val": "no-such-host", "baseline_window": 32})
        check("engine error class carries the engine's own actionable text "
              "(verbatim, 1.6)",
              r is not None and r["result"].get("isError")
              and r["result"]["structuredContent"]["error_class"] == "engine"
              and "no rows matching the filter"
              in r["result"]["content"][0]["text"])
        # fractal_dimension_drift carries the non-vector `win` field
        # (1.4: lenient coercion is vector-element-scoped; a wrong type
        # elsewhere fails validation normally, before any driver call).
        r = call("fractal_dimension_drift", {"series": [0.1, 0.2], "win": "x"})
        check("schema error class rejected before any driver call "
              "(wrong-typed non-vector field: no leniency, 1.4)",
              r is not None and r["result"]["structuredContent"]
              ["error_class"] == "schema")
        r = call("fractal_search", {"query": "not,an,array"})
        check("schema error: non-array vector rejected",
              r is not None and r.get("result", {}).get("isError")
              and r["result"]["structuredContent"]["error_class"] == "schema")

        # -- $/cancel propagation (1.1) ---------------------------------
        # A long SFS run keeps the session's statement in-flight (the shim
        # call sits inside the agent's CALL); the cancel must interrupt
        # the DB-side work (KILL QUERY against this connection, 13.4.2 --
        # via the separate control connection), stay responsive, and
        # NEVER deliver the eventual result.
        _req[0] += 1
        slow_id = 1000 + _req[0]
        corpus = [[0.1 * ((i * 7) % 11), 0.2 * ((i * 5) % 13),
                   0.3 * ((i * 3) % 17)] for i in range(300)]
        send({"jsonrpc": "2.0", "id": slow_id, "method": "tools/call",
              "params": {"name": "fractal_search",
                         "arguments": {"query": [0.1, 0.2, 0.3],
                                       "corpus": corpus,
                                       "k": 30,
                                       "params": {"iterations": 9000,
                                                  "population_size": 500}}}})
        time.sleep(0.2)
        send({"jsonrpc": "2.0", "method": "notifications/cancelled",
              "params": {"requestId": slow_id}})
        send({"jsonrpc": "2.0", "id": 9000, "method": "ping"})
        ping = None
        stale_result = None
        # First: the ping must get through WHILE the cancelled call runs.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            r = recv(deadline=0.2)
            if r is None or r.get("__timeout__"):
                continue
            if r.get("id") == 9000:
                ping = r
                break
        # Then: the cancelled id responds ONLY with a cancellation signal --
        # never with the computed result -- within a generous window.
        window_end = time.monotonic() + 30
        while time.monotonic() < window_end:
            r = recv(deadline=0.2)
            if r is None:
                break
            if r.get("__timeout__"):
                continue
            if r.get("id") == slow_id:
                stale_result = r
                break
        check("$/cancel: server stays responsive while a call is in flight",
              ping is not None)
        stale_dump = json.dumps(stale_result) if stale_result else ""
        real_result = (stale_result is not None
                       and not (stale_result.get("error")
                                or (stale_result.get("result") or {})
                                .get("isError"))
                       and "best_point" in stale_dump)
        check("$/cancel: the cancelled call's REAL result is never "
              "delivered (at most an explicit cancellation signal)",
              not real_result
              and (stale_result is None
                   or (stale_result.get("error") or
                       ((stale_result["result"].get("content") or [{}])[0]
                        .get("text", "").find("cancel") >= 0))))

        # -- resources & prompts ----------------------------------------
        for uri, label in (("fractalsql://schema", "schema"),
                           ("fractalsql://config", "config"),
                           ("fractalsql://vectorizer/status", "vectorizer/status"),
                           ("fractalsql://agents", "agents")):
            send({"jsonrpc": "2.0", "id": 9100, "method": "resources/read",
                  "params": {"uri": uri}})
            r = recv()
            check(f"resource fractalsql://{label} reads as real content",
                  r is not None and r.get("result", {}).get("contents"))
            if r is not None and "error" in r:
                print(f"  [resource-error {label}] " + str(r["error"]))
        send({"jsonrpc": "2.0", "id": 9200, "method": "prompts/list"})
        prompts = recv()["result"]["prompts"]
        check("prompts/list: the spec section 4 prompt set (11)",
              len(prompts) == 11)
        send({"jsonrpc": "2.0", "id": 9201, "method": "prompts/get",
              "params": {"name": "safe_sql_question",
                         "arguments": {"question": "how many orders?"}}})
        msg = recv()["result"]["messages"][0]["content"]["text"]
        check("safe_sql_question prompt keeps auto_execute explicitly OFF",
              "explicitly OFF" in msg or "EXPLICITLY FALSE" in msg)

        # An argument whose VALUE contains the placeholder for that same
        # argument must come back, not spin. The substitution used to
        # replace every occurrence and then look again -- so a value
        # carrying its own placeholder put one back every time it
        # removed one, and the request never returned: the server thread
        # was stuck for good on a request that is supposed to be free.
        send({"jsonrpc": "2.0", "id": 9202, "method": "prompts/get",
              "params": {"name": "safe_sql_question",
                         "arguments": {"question": "{question}"}}})
        r = recv(deadline=time.monotonic() + 20)
        text = ""
        if isinstance(r, dict) and not r.get("__timeout__"):
            text = (((r.get("result") or {}).get("messages") or [{}])[0]
                    .get("content") or {}).get("text", "")
        check("prompts/get: an argument value that contains its own "
              "placeholder is substituted, not looped on",
              bool(text) and "{question}" in text)

        # -- the per-session configuration overlay (admin tier) ----------
        # The five session-config tools sit on the engine's overlay SQL
        # surface. Three properties are asserted here that the engine's
        # own gate (gate 49) does not cover, because they are MCP
        # properties: the "value" field's TYPE (a configuration value
        # is text, whatever it looks like -- a value that happens to
        # read as a JSON number must not arrive as a number), the
        # operator-only refusal on the read path, and the shape of the
        # "overrides" object (every override the connection holds must
        # be in it -- a session may hold several at once).
        r = call("fractal_config_keys", {}, timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        keys = (sc or {}).get("keys") if isinstance(sc, dict) else None
        check("session config: keys() lists the engine's whole key surface",
              isinstance(keys, list) and len(keys) == 18
              and all(isinstance(k, dict) and "name" in k
                      and "session_overridable" in k for k in keys))

        r = call("fractal_config_set",
                 {"key": "think", "value": "high"}, timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("session config: set() accepts a tuning key",
              isinstance(sc, dict) and sc.get("ok") is True
              and sc.get("key") == "think")

        r = call("fractal_config_get", {"key": "think"}, timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("session config: get() returns the session's own override",
              isinstance(sc, dict) and sc.get("key") == "think"
              and sc.get("value") == "high")

        # A value that happens to be all digits is still TEXT. The
        # engine's config surface is textual end to end; a JSON-shaped
        # read would turn "8192" into the number 8192 and the same
        # tool's "value" field would change type depending on what the
        # operator typed.
        r = call("fractal_config_set",
                 {"key": "think_num_ctx", "value": "8192"}, timeout=60)
        r = call("fractal_config_get", {"key": "think_num_ctx"},
                 timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        val = sc.get("value") if isinstance(sc, dict) else None
        check("session config: a numeric-looking value comes back as the "
              "STRING it was set to",
              isinstance(val, str) and val == "8192")

        r = call("fractal_config_list", {}, timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        ov = (sc or {}).get("overrides") if isinstance(sc, dict) else None
        check("session config: list() shows the connection's overrides",
              isinstance(ov, dict) and ov.get("think") == "high"
              and ov.get("think_num_ctx") == "8192")

        # A daemon-wide key is refused BY NAME, with the reason, and
        # the refusal arrives as {ok:false, reason:...} -- not as an
        # exception and not as a silent no-op.
        r = call("fractal_config_set",
                 {"key": "reasoning_plugin", "value": "/opt/evil.so"},
                 timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("session config: set() refuses a daemon-wide key by name, "
              "with the reason",
              isinstance(sc, dict) and sc.get("ok") is False
              and "reasoning_plugin" in str(sc.get("reason", "")))

        # The operator-only keys are refused on the READ path too: the
        # enterprise tier's library, ledger and signature posture are
        # the operator's, and this surface is not how an operator reads
        # them.
        r = call("fractal_config_get", {"key": "enterprise_lib"},
                 timeout=60)
        res = (r.get("result") or {}) if r else {}
        text = str((res.get("content") or [{}])[0].get("text", ""))
        check("session config: get() refuses an operator-only key by name",
              res.get("isError") is True and "operator territory" in text)

        r = call("fractal_config_reset", {}, timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("session config: reset() drops the connection's overrides",
              isinstance(sc, dict) and isinstance(sc.get("dropped"), int)
              and sc.get("dropped") >= 2)
        r = call("fractal_config_list", {}, timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        ov = (sc or {}).get("overrides") if isinstance(sc, dict) else None
        check("session config: after the reset the connection holds no "
              "overrides", isinstance(ov, dict) and ov == {})

        # -- S-FT-004 partial-result honesty (agent_partial_reasoning_fail)
        # The MCP layer opts every session into the engine's per-session
        # partial mode at connect (FSQL_MCP_AGENT_PARTIAL, default on);
        # the engine's PSM agents then return the data half plus
        # reasoning_step_failed when the reasoning endpoint fails, which
        # the MCP boundary normalizes to isError:false rather than a
        # raise. Repoint the daemon's chat endpoint at a dead port via
        # the admin tool (per-connection conf edit + reload, exactly what
        # a real operator's misconfiguration looks like), exercise an
        # agent (data field + reasoning_step_failed both back), prove
        # fractal_reason itself still fails loudly, then RESTORE the
        # mock provider and re-prove a normal reason call.
        broken = "http://127.0.0.1:9/v1/chat/completions"
        r = call("fractal_daemon_config_get", {"key": "reasoning_url"}, timeout=60)
        original = ((r.get("result") or {})
                    .get("structuredContent") or {}).get("value")
        r = call("fractal_daemon_config_set",
                 {"key": "reasoning_url", "value": broken}, timeout=60)
        # The setup assertion must require the RELOAD to have actually
        # happened. set_config reports a refused reload as isError:false with
        # reloaded:false and an outcome naming the refusal (the daemon keeps
        # its previous configuration, all-or-nothing), so an assertion that
        # only checks "isError is not True" passes while the daemon is still
        # serving the OLD endpoint -- and the rest of this block then
        # measures the wrong thing entirely. Caught live: the reload was
        # being refused (the MCP mis-parsed the daemon's reply) and this
        # check still went green.
        setup_sc = ((r.get("result") or {}).get("structuredContent")
                    if r is not None else None)
        check("S-FT-004 setup: the admin tool accepts a (dead) "
              "reasoning_url and reloads it live",
              r is not None and (r.get("result") or {}).get("isError") is not True
              and isinstance(setup_sc, dict)
              and setup_sc.get("reloaded") is True
              and "did NOT accept the reload" not in str(setup_sc.get("outcome", "")))
        if isinstance(setup_sc, dict) and setup_sc.get("reloaded") is not True:
            print("  [reload-refused] " + json.dumps(setup_sc)[:400])
        # The changed tier's NEXT call picks the new configuration up
        # (a reload never performs a plugin/library load itself), and the
        # per-tier plugin-load flags only reset on the NEXT reason
        # dispatch -- so the FIRST post-reload call is the one that
        # actually fails.
        r = call("fractal_agent_regime_triage",
                 {"series": [round(i * 0.1, 6) for i in range(100)]},
                 timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        sc_dump = json.dumps(sc) if sc is not None else ""
        check("S-FT-004: broken-endpoint agent call returns the computed "
              "data half plus reasoning_step_failed (isError=false)",
              r is not None and (r.get("result") or {}).get("isError") is False
              and sc is not None and "dfa_exponent" in str(sc)
              and "reasoning_step_failed" in sc_dump)
        r = call("fractal_reason", {"query": "does the raise survive"},
                 timeout=60)
        if r is not None and not (r.get("result") or {}).get("isError"):
            print("  [reason-was-not-error] "
                  + json.dumps((r.get("result") or {}).get("structuredContent")))
        check("S-FT-004: fractal_reason itself still fails loudly (it IS "
              "the reasoning step)",
              r is not None and (r.get("result") or {}).get("isError") is True)
        # Restore the mock provider and a NORMAL reason outcome, proving
        # the gate's own restore step actually took. get_config reads the
        # conf FILE, which (env-fallback installs) may not carry
        # reasoning_url at all -- fall back to the harness's own mock URL,
        # which is exactly the value the running daemon was configured
        # with (mdb_setup / Mdb-Setup exported it).
        if isinstance(original, str) and original:
            call("fractal_daemon_config_set",
                 {"key": "reasoning_url", "value": original}, timeout=60)
        else:
            fallback = os.environ.get("FRACTALSQL_HTTP_URL")
            if fallback:
                call("fractal_daemon_config_set",
                     {"key": "reasoning_url", "value": fallback}, timeout=60)
        r = call("fractal_reason", {"query": "post-restore sanity"},
                 timeout=60)
        check("S-FT-004 cleanup: mock reasoning restored (a normal reason "
              "call succeeds again)",
              r is not None and not (r.get("result") or {}).get("isError"))

        # -- path-shaped config values are refused BEFORE the file is
        # written ------------------------------------------------------
        # reasoning_plugin is a FILE PATH, and the daemon refuses a
        # relative path and a ".." segment at load/reload time. A
        # refused reload still leaves the bad value ON DISK, so the
        # MCP's admin tool checks the path's shape first and refuses
        # the change outright: the tool's contract is that a refused
        # change leaves the live configuration unchanged in BEHAVIOR,
        # which a bad value already written to the conf would break.
        # Only reasoning_plugin is exercised here -- enterprise_lib and
        # enterprise_ledger_path are operator-territory keys, refused
        # for a different reason and never writable from a tool call.
        conf_path = os.environ.get("FSQLCTL_CONF", "")
        before = ""
        if conf_path and os.path.isfile(conf_path):
            before = open(conf_path, encoding="utf-8", errors="replace").read()
        for bad in ("relative/plugin.so", "/opt/fractalsql/../etc/plugin.so"):
            r = call("fractal_daemon_config_set",
                     {"key": "reasoning_plugin", "value": bad}, timeout=60)
            txt = ""
            sc = None
            if r is not None:
                sc = (r.get("result") or {}).get("structuredContent") or {}
                txt = ((r.get("result") or {}).get("content") or [{}])[0].get("text", "") or ""
            check(f"config paths: the path-shaped value {bad!r} is refused, "
                  "naming the rule",
                  r is not None and (r.get("result") or {}).get("isError") is True
                  and "absolute path" in txt
                  and sc.get("error_class") == "schema")
        after = ""
        if conf_path and os.path.isfile(conf_path):
            after = open(conf_path, encoding="utf-8", errors="replace").read()
        check("config paths: a refused path leaves the daemon's conf file "
              "byte-identical (the refusal happens before the write)",
              bool(conf_path) and before != "" and before == after)

        # -- unknown tool/method pairing (framing + dispatch) ------------
        send({"jsonrpc": "2.0", "id": 9300, "method": "tools/call",
              "params": {"name": "fractal_nonexistent", "arguments": {}}})
        r = wait_for(9300, 10)
        check("unknown tool refuses with an error naming tools/list",
              r is not None and r.get("error") is not None
              and "unknown tool" in r["error"]["message"])
        send({"jsonrpc": "2.0", "id": 1, "method": "bogus/method"})
        r = wait_for(1, 10)
        check("unknown method returns -32601", r is not None
              and r.get("error", {}).get("code") == -32601)

        # -- a MALFORMED request line must not take the server down ------
        # The stdio transport dispatches on a worker thread, and an
        # exception that reaches a thread function is std::terminate: the
        # whole MCP server dies, silently. The shape check used to read
        # the request's id and method through a helper that THROWS on a
        # non-object (a bare "5", "[]", "null") and on a method that is
        # not a string -- so those lines took the process with them.
        for label, raw in (("a non-object request", "5"),
                           ("an array request", "[]"),
                           ("a null request", "null"),
                           ("a non-string method",
                            '{"jsonrpc":"2.0","id":9401,"method":5}')):
            proc.stdin.write(raw + "\n")
            proc.stdin.flush()
            r = recv(10)
            check(f"a malformed request ({label}) is answered with a "
                  f"JSON-RPC error, not a dead server",
                  isinstance(r, dict) and r.get("error") is not None
                  and isinstance(r.get("error", {}).get("code"), int))
        # The server must still be there afterwards.
        send({"jsonrpc": "2.0", "id": 9402, "method": "ping"})
        r = wait_for(9402, 10)
        check("the server is still serving after the malformed requests",
              r is not None and "result" in r)

        # -- a config value that tries to inject a config key -------------
        # The daemon's config file is line-based ("key = value"), so a
        # newline inside a value ends the key's line and starts another
        # one: a value carrying "\nenterprise_require_signature = 0"
        # would inject a config key the surface refuses by name.
        if conf_path:
            before = open(conf_path, encoding="utf-8", errors="replace").read()
            r = call("fractal_daemon_config_set",
                     {"key": "reasoning_model",
                      "value": "m\nenterprise_require_signature = 0"})
            after = open(conf_path, encoding="utf-8", errors="replace").read()
            txt = ""
            if isinstance(r, dict) and (r.get("result") or {}).get("isError"):
                txt = (r["result"].get("content") or [{}])[0].get("text", "")
            check("a config value carrying a line break is refused, and the "
                  "conf file gains no second key",
                  isinstance(r, dict) and (r.get("result") or {}).get("isError")
                  is True and "enterprise_require_signature" not in after
                  and before == after)
    finally:
        finish(proc, server_log)

    # -- the shutdown-drain phase (its own server instance) -----------------
    # Deliberately OUTSIDE the main session's try/finally: it needs a
    # dedicated server process whose ONLY job is to be shut down while a
    # request is genuinely in flight.
    run_shutdown_drain_phase(mcp_exe, os.environ["MCP_SERVER_CWD"], env)
    run_read_only_latch_phase(mcp_exe, os.environ["MCP_SERVER_CWD"], env)
    return 1 if _failures else 0


def restore_daemon_plugin(mcp_exe, server_cwd, env, original: str) -> None:
    """Put the daemon's reasoning_plugin back to `original` and reload it.

    Runs on its own short-lived server instance: the drain server has
    already exited by the time the restore is due, and the admin tier
    (fractal_daemon_config_set) is the only path to the daemon's live
    config. The restore is verified by a follow-up reasoning call that
    must succeed -- a restore that was accepted by the conf write but
    refused by the daemon's reload would otherwise go unnoticed, and
    every later reasoning gate in the run would fail against a daemon
    still holding the slow fixture.
    """
    global _failures
    proc = None
    log = None
    try:
        log = open(os.path.join(server_cwd, "mcp_shutdown_drain_restore.log"),
                   "w", encoding="utf-8")
        proc = subprocess.Popen(
            [mcp_exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, cwd=server_cwd, env=env, text=True, bufsize=1)

        def send(msg: dict) -> None:
            proc.stdin.write(json.dumps(msg) + "\n")
            proc.stdin.flush()

        def recv(deadline: float) -> dict | None:
            end = time.monotonic() + deadline
            while time.monotonic() < end:
                line = proc.stdout.readline()
                if not line:
                    return None
                try:
                    return json.loads(line)
                except ValueError:
                    continue
            return None

        def call(name: str, args: dict, rid: int) -> dict | None:
            send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                  "params": {"name": name, "arguments": args}})
            return recv(90)

        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "drain-restore", "version": "0"}}})
        if recv(30) is None:
            check("shutdown drain cleanup: the restore server completed its "
                  "initialize handshake", False)
            return

        r = call("fractal_daemon_config_set",
                 {"key": "reasoning_plugin", "value": original}, 2)
        sc = ((r.get("result") or {}).get("structuredContent") or {}) if r else {}
        if not check("shutdown drain cleanup: the daemon accepted the restore "
                     "of its real reasoning plugin",
                     sc.get("reloaded") is True):
            if r is not None:
                print("  [restore-refused] " + json.dumps(sc)[:400])
            return

        # A normal reasoning call must work again -- the daemon is back on
        # the real provider, not still holding the slow fixture.
        r = call("fractal_reason", {"query": "post-restore sanity"}, 3)
        ok = r is not None and not (r.get("result") or {}).get("isError")
        if not ok and r is not None:
            print("  [restore-postcheck] "
                  + json.dumps((r.get("result") or {})
                               .get("structuredContent"))[:400])
        check("shutdown drain cleanup: a normal reasoning call succeeds "
              "again (the daemon is back on the real provider)", ok)
    except Exception as exc:  # noqa: BLE001
        print("  [restore-error] %r" % (exc,))
        check("shutdown drain cleanup: the daemon was restored to its real "
              "reasoning plugin", False)
    finally:
        if proc is not None:
            try:
                proc.stdin.close()
            except Exception:  # noqa: BLE001
                pass
            try:
                proc.wait(timeout=15)
            except Exception:  # noqa: BLE001
                proc.kill()
        if log is not None:
            log.close()


def run_read_only_latch_phase(mcp_exe, server_cwd, base_env) -> None:
    """FSQL_MCP_READ_ONLY=true, in a server instance of its own: reads are
    still served, a destructive tool is refused at the dispatch layer, and the
    server latched the engine's destructive ledger UDFs on its own connection
    (fractal_lock_destructive). The server logs a "latch not applied" warning
    when that call fails (an engine older than the plugin), so the absence of
    the warning is the evidence the latch call went through. This harness runs
    without an enterprise core, so the ledger UDFs themselves cannot show the
    difference here; the engine-level behaviour has its own check in the
    build_test enterprise_mock gate."""
    env = dict(base_env, FSQL_MCP_READ_ONLY="true")
    log_path = os.path.join(server_cwd, "mcp_readonly_latch.log")
    got: dict = {}
    with open(log_path, "w", encoding="utf-8") as log:
        proc = subprocess.Popen(
            [mcp_exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, cwd=server_cwd, env=env, text=True, bufsize=1)
        out: list = []
        threading.Thread(target=lambda: [out.append(l) for l in proc.stdout],
                         daemon=True).start()

        def rpc(rid: int, method: str, params: dict | None = None, timeout: float = 60.0):
            msg = {"jsonrpc": "2.0", "id": rid, "method": method}
            if params is not None:
                msg["params"] = params
            proc.stdin.write(json.dumps(msg) + "\n")
            proc.stdin.flush()
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                while out:
                    try:
                        rec = json.loads(out.pop(0))
                    except ValueError:
                        continue
                    if rec.get("id") == rid:
                        return rec
                time.sleep(0.02)
            return None

        try:
            rpc(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                  "clientInfo": {"name": "smoke-ro", "version": "1"}})
            proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            proc.stdin.flush()
            got["read"] = rpc(2, "tools/call", {"name": "fractal_version", "arguments": {}})
            got["refused"] = rpc(3, "tools/call", {"name": "fractal_daemon_config_set", "arguments": {}})
        finally:
            try:
                proc.stdin.close()
            except Exception:  # noqa: BLE001
                pass
            try:
                proc.wait(timeout=30)
            except Exception:  # noqa: BLE001
                proc.kill()
                proc.wait(timeout=10)
    log_text = open(log_path, encoding="utf-8", errors="replace").read()
    read = got.get("read") or {}
    refused_err = ((got.get("refused") or {}).get("error") or {})
    check("env: FSQL_MCP_READ_ONLY serves reads, refuses a destructive tool, and the "
          "server applied the engine-side destructive latch (no 'latch not applied' warning)",
          bool(read) and not (read.get("result") or {}).get("isError")
          and "read-only mode" in str(refused_err.get("message", ""))
          and "destructive latch not applied" not in log_text)


def run_shutdown_drain_phase(mcp_exe, server_cwd, base_env) -> None:
    """Prove the MCP server's own shutdown drain-wait loop actually runs.

    The stdio transport drains after EOF: it waits up to
    FSQL_MCP_SHUTDOWN_DRAIN_MS for the in-flight request count to reach
    zero before joining its workers. That wait is a no-op unless a real
    request is still being processed at the exact moment the shutdown
    begins -- normally a sub-millisecond race, so the loop's wait body
    never runs and the drain path is effectively untested.

    MARIADB-SHAPED. A single-process engine could hold a request open
    with a plugin's artificial sleep, pointed at that plugin by a
    bootstrap SQL statement -- because there the plugin lives in the
    SAME process as the MCP server. Here the reasoning plugin is loaded
    by the DAEMON, not by the server, so the server cannot point ITSELF
    at a slow plugin.

    The MariaDB equivalent is the daemon's own live-reloadable
    `reasoning_plugin` conf key: the phase edits the daemon's config
    file and asks the daemon to reload it (fractal_daemon_config_set, the
    admin tier's own lever -- the same one the S-FT-004 case above
    uses), and the daemon's NEXT reasoning call loads the slow fixture
    instead of the real HTTP plugin. The reasoning call then sits inside
    the plugin's artificial sleep, and the MCP request stays in flight
    for a controlled, known window.

    The swap is REVERSED before the phase returns: the real plugin path
    is put back and reloaded, so the daemon is left exactly as the rest
    of the harness expects. A phase that left the daemon pointed at a
    3-second-sleep fixture would silently degrade every later reasoning
    gate in the same run.

    What is proven: a request in flight at the moment the server is
    asked to stop is DRAINED, not dropped, and the drain wait is
    BOUNDED -- the server exits on its own, promptly, without a hang and
    without a hard kill.
    """
    global _failures
    # The fixture's path comes from base_env, not from os.environ: that
    # is the environment the server is actually started with, and it is
    # what the harness sets explicitly. (os.environ is the CLIENT's
    # environment, which the harness populates too, but base_env is the
    # authoritative copy -- the phase must look where the server's own
    # environment came from, not where the driver's happened to inherit
    # it.)
    slow_plugin = base_env.get("MCP_SLOW_REASONING_PLUGIN", "") or \
        os.environ.get("MCP_SLOW_REASONING_PLUGIN", "")
    have_slow = bool(slow_plugin) and os.path.isfile(slow_plugin)
    if not have_slow:
        check("shutdown drain: the harness did not build the slow reasoning "
              "plugin, so the drain-wait loop cannot be exercised (this is a "
              "HARNESS BUG, not a server bug -- the fixture is what makes a "
              "request deterministically in flight at the shutdown instant)",
              False)
        return

    # The plugin path the core will dlopen must be CANONICAL -- it has to
    # equal its own resolution, or the core refuses the load outright
    # ("reasoning plugin path is not canonical").
    #
    # On POSIX that is realpath(): the resolved path must EQUAL the
    # configured one, so a symlinked directory segment is rejected (the
    # Homebrew /opt/homebrew/opt/... form). On Windows the core uses
    # _fullpath(), which resolves "/", "\", ".." and drive letters but does
    # NOT follow symlinks -- so FORWARD SLASHES are what it rejects there
    # (they resolve to backslashes, so the result differs from the input),
    # while the 8.3 short-name form (C:\Users\NAME~1\...) is fine.
    #
    # (Measured live, both directions: a forward-slash conf value fails
    # the load with "reasoning plugin path is not canonical"; the
    # backslash short form and the backslash long form both load.)
    if os.name == "nt":
        slow_plugin = os.path.abspath(slow_plugin).replace("/", "\\")
    else:
        slow_plugin = os.path.realpath(slow_plugin)

    # The plugin the daemon is CURRENTLY using. The daemon's own boot
    # environment is the fallback for any conf key the file does not
    # carry, so an ABSENT key restores the boot plugin; an explicit one
    # restores exactly what the conf said. Either way the phase reads the
    # live value back through the admin tier and puts THAT back.
    original = ""

    env = dict(base_env)
    env.update({
        # A short drain so the phase does not need a long sleep. The
        # in-flight call outlives it, which is exactly the case the
        # drain must handle without hanging.
        "FSQL_MCP_SHUTDOWN_DRAIN_MS": "300",
        # FSQL_MOCK_SLOW_MS is the slow fixture's own delay knob, but it
        # is read from the DAEMON's environment -- the fixture is loaded
        # INTO the daemon, not into this server, so setting it here would
        # have no effect at all (measured: the fixture fell back to its
        # 3000ms default). The daemon's own environment is what the
        # harness set up in mdb_setup / Mdb-Setup; the phase therefore
        # does NOT set it, and instead sizes its own timing windows
        # against the fixture's DEFAULT (3000ms), which is what the
        # daemon will actually use.
        #
        # The drain window (300ms) is well inside the fixture's own
        # 3000ms sleep, so the request is provably still in flight when
        # the drain's wait body runs.
    })
    SLOW_MS = 3000      # the fixture's own default (tests/slow_reasoning_plugin.c)

    log_path = os.path.join(server_cwd, "mcp_shutdown_drain.log")
    log = open(log_path, "w", encoding="utf-8")
    proc = None
    try:
        proc = subprocess.Popen(
            [mcp_exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, cwd=server_cwd, env=env, text=True, bufsize=1)
        out: list = []
        threading.Thread(
            target=lambda: [out.append(l) for l in proc.stdout],
            daemon=True).start()

        def send(msg: dict) -> None:
            proc.stdin.write(json.dumps(msg) + "\n")
            proc.stdin.flush()

        def recv(deadline: float) -> dict | None:
            end = time.monotonic() + deadline
            while time.monotonic() < end:
                if out:
                    line = out.pop(0)
                    try:
                        return json.loads(line)
                    except ValueError:
                        continue
                time.sleep(0.02)
            return None

        def wait_for(rid: int, timeout: float = 90.0) -> dict | None:
            """Queue-backed read keyed by request id, so a reply that is
            NOT the one being waited for (the slow call's own reply,
            arriving while the main thread waits for something else) is
            put back rather than swallowed."""
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                if out:
                    line = out.pop(0)
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if rec.get("id") == rid:
                        return rec
                    # Someone else's reply: keep it for its own waiter.
                    out.insert(0, line)
                    time.sleep(0.02)
                    continue
                time.sleep(0.02)
            return None

        def call(name: str, args: dict, rid: int) -> dict | None:
            send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                  "params": {"name": name, "arguments": args}})
            return wait_for(rid)

        def call_structured(name: str, args: dict, rid: int) -> dict:
            r = call(name, args, rid)
            if r is None:
                return {}
            return ((r.get("result") or {}).get("structuredContent")
                    or {})

        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "drain-probe", "version": "0"}}})
        init = recv(30)
        if not check("shutdown drain: the drain server completed its "
                     "initialize handshake", init is not None):
            return

        # What is the daemon using right now? Read it back through the
        # admin tier so the restore puts back exactly this.
        before = call_structured("fractal_daemon_config_get",
                                 {"key": "reasoning_plugin"}, 2)
        original = str(before.get("value") or "")
        if not original:
            # The conf does not carry the key, so the daemon is using
            # its boot-environment fallback. There is no boot value the
            # MCP can see, so the phase cannot put the conf back to
            # "absent" by setting it -- it would have to REMOVE the line.
            # The admin tier has no delete verb, so this phase is only
            # possible when the conf carries the key explicitly.
            check("shutdown drain: the daemon's config carries a "
                  "reasoning_plugin key the phase can swap and restore "
                  "(the harness's conf must name the plugin explicitly)",
                  False)
            return

        # Swap the daemon onto the slow fixture. The edit goes through
        # the admin tier's own tool, which writes the conf file AND
        # asks the daemon to reload it -- the same live-reload path the
        # S-FT-004 case above exercises.
        swap = call_structured("fractal_daemon_config_set",
                               {"key": "reasoning_plugin", "value": slow_plugin}, 3)
        swapped = swap.get("reloaded") is True
        if not check("shutdown drain: the daemon accepted the live swap to "
                     "the slow reasoning plugin",
                     swapped and "slow_reasoning" in str(swap.get("new_value", ""))):
            if not swapped:
                print("  [swap-refused] " + json.dumps(swap)[:400])
            return

        # The hold: a reasoning call now runs inside the slow plugin's
        # artificial sleep, inside the DAEMON, with the MCP request still
        # in flight across it.
        #
        # The slow call rides the SAME id-keyed queue as every other call
        # (wait_for, below) -- a separate reader thread would race the
        # main thread for the queue and could swallow the drain server's
        # own replies.
        slow_result: dict = {}

        def fire_slow_call() -> None:
            slow_result["resp"] = call("fractal_reason", {"query": "drain"}, 4)

        t = threading.Thread(target=fire_slow_call, daemon=True)
        t.start()
        # Let the request get INTO the server (past the dispatch, into
        # the shim, into the daemon, into the plugin's sleep) before the
        # shutdown starts. Well inside the fixture's own SLOW_MS window,
        # so the request is provably still in flight at the shutdown
        # instant rather than racing its own completion.
        time.sleep(0.8)

        t0 = time.monotonic()
        # EOF on stdin is the stdio transport's shutdown trigger: it
        # stops reading, calls beginShutdown(), and drains.
        try:
            proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            rc = proc.wait(timeout=25)
        except Exception:  # noqa: BLE001
            proc.kill()
            rc = proc.wait(timeout=10)
        elapsed = time.monotonic() - t0

        check("shutdown drain: a request still in flight does not stop the "
              "server from exiting cleanly",
              rc == 0)
        # THE assertion that makes this phase worth anything: the drain's
        # WAIT BODY ran. The transport waits up to FSQL_MCP_SHUTDOWN_DRAIN_MS
        # (300 here) for the in-flight count to reach zero, and the in-flight
        # call is held open for the fixture's own ~3s sleep by the slow
        # plugin -- so the server MUST spend at least the drain window
        # before it can exit. An exit faster than that means the loop's
        # condition was never true: the request was not in flight, and the
        # drain path proved nothing.
        #
        # (Measured live: the previous version of this phase used an SFS
        # refinement run as its hold, which finished in 0.88ms -- the server
        # exited in 0.02s and the phase "passed" while proving nothing at
        # all. The elapsed-time assertion is what catches that class of
        # false pass.)
        check("shutdown drain: the drain WAIT BODY actually ran (the server "
              "spent at least the {}-ms drain window waiting on the in-flight "
              "request; exited in {:.2f}s)"
              .format(int(env["FSQL_MCP_SHUTDOWN_DRAIN_MS"]), elapsed),
              elapsed >= int(env["FSQL_MCP_SHUTDOWN_DRAIN_MS"]) / 1000.0)
        check("shutdown drain: the drain wait is BOUNDED, not a hang "
              "(exited in {:.2f}s, well under the 25s the harness allows)"
              .format(elapsed), elapsed < 20.0)

        # The slow call itself must have been the thing that was in
        # flight: the server's own per-call log records the tool's
        # latency, and a latency at the fixture's own sleep length is
        # the positive evidence that the request really did sit inside
        # the plugin for its whole window (rather than the drain
        # happening to be slow for some unrelated reason).
        t.join(timeout=15)
        try:
            with open(log_path, "r", encoding="utf-8", errors="replace") as f:
                log_text = f.read()
        except OSError:
            log_text = ""
        slow_ms = 0.0
        for line in log_text.splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("event") == "tool_call" and rec.get("tool") == "fractal_reason":
                slow_ms = max(slow_ms, float(rec.get("latency_ms") or 0.0))
        check("shutdown drain: the in-flight request really was held open by "
              "the slow plugin (its own logged latency {:.0f}ms reached the "
              "fixture's ~{}-ms sleep)".format(slow_ms, SLOW_MS),
              slow_ms >= SLOW_MS * 0.5)
    finally:
        # RESTORE the daemon. The drain server has exited by now, so the
        # restore goes through a fresh server instance against the same
        # daemon and the same conf file. A phase that left the daemon
        # pointed at the 2-second-sleep fixture would silently degrade
        # every later reasoning gate in the same run -- and the gate that
        # runs after this one would be the first to notice.
        if original:
            restore_daemon_plugin(mcp_exe, server_cwd, env, original)
        if proc is not None and proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except Exception:  # noqa: BLE001
                pass
        log.close()


# Every tools/call the main session sent, handed to mcp_mutate.py afterwards.
_RECORDED_CALLS: list = []


def finish(proc, server_log) -> None:  # noqa: ANN001
    # End of input is the stdio transport's normal ending: the server drains
    # what is in flight and exits through its ordinary shutdown path, which is
    # also where an instrumented build writes its coverage data. Terminating
    # the process is the fallback for a server that does not stop.
    try:
        try:
            proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        proc.wait(timeout=15)
    except Exception:  # noqa: BLE001
        try:
            proc.terminate()
            proc.wait(timeout=15)
        except Exception:  # noqa: BLE001
            proc.kill()
    server_log.close()


if __name__ == "__main__":
    raised = None
    try:
        code = main()
    except SystemExit as exc:
        # SystemExit(str) exits 1 but carries the message -- don't int()
        # it, but keep the message visible (a fixture-SQL failure says
        # exactly which statement the cluster rejected).
        try:
            code = int(exc.code or 0)
        except (TypeError, ValueError):
            print(str(exc.code))
            code = 1
    # Engine-agnostic robustness probes (mcp_robustness.py, same directory): odd
    # and malformed request lines, non-object bodies over stdio and HTTP,
    # explicit-null optionals and very long strings across the whole tool
    # catalog, read-only refusal, and the sanitizeSecrets differential probe.
    # They ride this client, so the existing gate (POSIX and PowerShell) runs them.
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import mcp_robustness
        mcp_robustness.run(check)
    except ImportError:
        print("SKIP robustness probes (mcp_robustness.py not present)")
    # The recorded calls and one valid call for every other tool
    # (mcp_fixtures.py), each again with one argument at a time changed, plus
    # the resource, prompt and protocol methods (mcp_mutate.py).
    try:
        import mcp_fixtures
        import mcp_mutate
        mcp_mutate.run(check, _RECORDED_CALLS + mcp_fixtures.FIXTURE_CALLS)
    except ImportError:
        print("SKIP mutation sweep (mcp_mutate.py not present)")
    if _failures and code == 0:
        code = 1
    print(f"mcp-smoke-client: {'ALL GREEN' if code == 0 else 'FAILED'}; "
          f"{_failures} failure(s)")
    sys.exit(code)