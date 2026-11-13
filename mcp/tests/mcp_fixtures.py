#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""One valid argument set for each tool the smoke client does not call itself.

The tables are the ones mcp_smoke_client.py builds: mcp_sm_docs (id, title, emb
as '[x,y,z]' text) and mcp_sm_logs (ts, host, metric). A call here does not have
to succeed (an engine refusal still exercises the handler's error path); it has
to be well formed enough to get past argument validation. mcp_mutate.py changes
one argument of each at a time.

Zero dependencies beyond the stdlib."""

from __future__ import annotations

_SERIES = [round(50.0 + (i % 8) * 1.3 + (30.0 if i > 48 else 0.0), 3) for i in range(1, 97)]
_SQUARE = [0, 0, 1, 0, 0, 1, 1, 1, 0.5, 0.5, 0.2, 0.8, 0.8, 0.2, 0.3, 0.3]
_CUBE_V = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1]
_CUBE_F = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 2, 6, 3, 6, 7, 0, 3, 7, 0, 7, 4, 1, 2, 6, 1, 6, 5]
_MU = [0.05, 0.08, 0.03, 0.12, 0.07, 0.01]
_COV = [0.02 if i == j else 0.0 for i in range(6) for j in range(6)]
_Q = [1.0, 0.0, 0.0]
_B = [0.0, 1.0, 0.0]
_TBL = {"table_name": "mcp_sm_docs", "vector_col": "emb"}

FIXTURE_CALLS = [
    ("fractal_search_debug", {"query": _Q, "iterations": 5, "population_size": 8, "seed": 7, "diffusion_factor": 2}),
    ("fractal_search_explore", {"corpus": [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7], "query": [0, 0],
                                "params": {"population_size": 4, "iterations": 3}}),
    ("fractal_search_trajectory", {**_TBL, "baseline_vector": _Q, "current_vector": _B, "k": 3, "limit": 5}),
    ("fractal_cross_modal_search", {**_TBL, "clinical_vector": _Q, "morphology_vector": _B, "alpha_weight": 0.5,
                                    "k": 3, "limit": 5}),
    ("fractal_diversify_enable", {}),
    ("fractal_diversify_set_params", {"window_n": 5, "repulsion_sigma": 0.3, "repulsion_weight": 0.5,
                                      "max_shadows_considered": 8, "stall_threshold": 0.1, "tail_buffer_cap": 16}),
    ("fractal_detect_collapse", {}),
    ("fractal_explain_result", {}),
    ("fractal_feedback_report", {"kind": "positive", "result_handle": 1, "dwell_ms": 4000}),
    ("fractal_isolate_background", {"result_handle": 2}),
    ("fractal_diversify_disable", {}),
    ("fractal_session_close", {}),
    ("fractal_embed", {"input": "hello world"}),
    ("fractal_schema_context", {"table_names": ["mcp_sm_docs"]}),
    ("fractal_schema_context", {}),
    ("fractal_agent_track_anomaly", {"baseline_vec": _Q, "current_vec": _B, "emb_col": "emb",
                                     "heading_series": _SERIES[:32], "track_table": "mcp_sm_docs"}),
    ("fractal_agent_detour_classify", {"baseline_vec": _Q, "current_vec": _B, "emb_col": "emb", "boxcount_dim": 2,
                                       "gps_trace": _SQUARE, "vehicle_table": "mcp_sm_docs"}),
    ("fractal_agent_network_coverage_alert", {"boxcount_dim": 2, "point_cloud": _SQUARE, "drift_series": _SERIES[:40],
                                              "drift_threshold": 0.1, "drift_win": 8, "context": "coverage"}),
    ("fractal_agent_allocate", {"mu": _MU, "cov": _COV, "cardinality": 2, "context": "allocation"}),
    ("fractal_agent_rebalance_sibling", {"mu": _MU, "cov": _COV, "cardinality": 2, "alloc_table": "mcp_sm_docs",
                                         "alloc_emb_col": "emb", "baseline_vec": _Q, "seed": 3}),
    ("fractal_agent_diverse_portfolios", {"mu": _MU, "cov": _COV, "cardinality": 2, "n_restarts": 3,
                                          "objective_mode": "sharpe", "overlap_threshold": 0.5, "quality_frac": 0.9}),
    ("fractal_agent_route_task", {"task_emb": _Q, "cap_table": "mcp_sm_docs", "cap_emb_col": "emb", "budget": 10,
                                  "cost_per_route": 2}),
    ("fractal_agent_schedule_workload", {"task_vec": _Q, "node_table": "mcp_sm_docs", "node_emb_col": "emb",
                                         "population": 6, "iterations": 3, "k": 2, "context": "schedule"}),
    ("fractal_agent_outlier_intercept", {"state_vec": _Q, "history_table": "mcp_sm_docs", "emb_col": "emb",
                                         "metric": "l2", "threshold": 0.5}),
    ("fractal_agent_patient_deterioration_triage", {"baseline_vec": _Q, "current_vec": _B, "query_vec": _Q,
                                                    "patient_table": "mcp_sm_docs", "vec_col": "emb", "k": 3,
                                                    "cohort_doc_ids": [1, 2, 3]}),
    ("fractal_agent_data_analyst", {"question": "how many rows are in mcp_sm_docs", "table_names": ["mcp_sm_docs"],
                                    "max_retries": 1, "context": "analysis"}),
    ("fractal_agent_recommend_diverse", {"catalog_table": "mcp_sm_docs", "emb_col": "emb", "query_vec": _Q, "k": 3}),
    ("fractal_agent_feedback_audit", {"catalog_table": "mcp_sm_docs", "emb_col": "emb", "query_vec": _Q, "k": 3,
                                      "warmup_table": "mcp_sm_docs", "warmup_vec_col": "emb", "warmup_count": 2}),
    ("fractal_search_agent", {"query": "alpha", "table_name": "mcp_sm_docs", "vector_col": "emb", "iterations": 5,
                              "pop_size": 8}),
    ("fractal_rag_agent", {"query": "alpha", "table_name": "mcp_sm_docs", "vector_col": "emb",
                           "meta_filter": "title LIKE 'a%'"}),
    ("fractal_sql_agent", {"question": "list all titles in mcp_sm_docs", "table_names": ["mcp_sm_docs"],
                           "auto_execute": False, "max_retries": 1}),
    ("fractal_sql_agent", {"question": "list all titles in mcp_sm_docs", "table_names": ["mcp_sm_docs"],
                           "auto_execute": True, "max_retries": 1}),
    ("fractal_agent_plan_explore", {"initial_state": "a calm market open", "max_branches": 2,
                                    "strategy_table": "mcp_sm_docs", "vector_col": "emb"}),
    ("fractal_agent_trajectory_predict", {**_TBL, "baseline_id": 1, "forecast_steps": 3, "risk_threshold": 0.5}),
    ("fractal_agent_detect_loop", {"agent_id": "agent-1", "state_log": _SERIES[:24], "hamming_threshold": 4,
                                   "n_bits": 64, "seed": 1.0}),
    ("fractal_dimension_dfa", {"series": _SERIES}),
    ("fractal_dimension_boxcount", {"dim": 2, "points": _SQUARE}),
    ("fractal_change_point_detect", {"series": _SERIES, "window": 8, "threshold": 2.0, "max_points": 8}),
    ("fractal_periodogram", {"series": _SERIES, "max_peaks": 4}),
    ("fractal_tda_persistence_diagram", {"points": _SQUARE, "dim": 2, "max_dim": 1, "max_h0_bars": 8,
                                         "max_thresh": 2.0}),
    ("fractal_state_fingerprint", {"vector": _Q, "n_bits": 64, "seed": 42}),
    ("fractal_cycle_detect", {"fingerprints": [1, 2, 3, 1, 2, 3, 1, 2], "n_bytes": 1, "hamming_threshold": 0}),
    ("fractal_vector_lp_distance", {"a": _Q, "b": _B, "p": 2.0}),
    ("fractal_vector_quantize_int8", {"vector": [1.0, -2.0, 3.0]}),
    ("fractal_vector_quantize_binary", {"vector": [1.0, -2.0, 3.0]}),
    ("fractal_vector_hamming_distance", {"a": [1, 2, 3], "b": [3, 2, 1]}),
    ("fractal_vector", {"dim": 3}),
    ("fractal_vector_from_text", {"text": "[1,2,3]"}),
    ("fractal_vector_to_json", {"vector": "[1,2,3]"}),
    ("fractal_vascular_network", {"node_coords": [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1], "edges": [0, 1, 1, 2, 2, 3],
                                  "arc_length": [1.0, 1.0, 1.0]}),
    ("fractal_cortical_folding", {"vertices": _CUBE_V, "faces": _CUBE_F}),
    ("fractal_nerve_plexus_metric", {"dim": 3, "node_coords": [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1],
                                     "edges": [0, 1, 1, 2, 2, 3]}),
    ("fractal_morphological_complexity", {"dim": 3, "points": _CUBE_V}),
    ("fractal_optimize_portfolio", {"mu": _MU, "cov": _COV, "k": 2, "params": {"seed": 42}}),
    ("fractal_optimize_portfolio_multimodal", {"mu": _MU, "cov": _COV, "k": 2, "n_restarts": 3,
                                               "overlap_threshold": 0.5, "quality_frac": 0.9, "seed": 42}),
    ("fractal_optimize_portfolio_multimodal_ex", {"mu": _MU, "cov": _COV, "k": 2, "n_restarts": 3,
                                                  "overlap_threshold": 0.5, "quality_frac": 0.9, "seed": 42,
                                                  "diffusion_mode": "levy", "use_obl": 1}),
    ("fractal_optimize_portfolio_multimodal_pareto", {"mu": _MU, "cov": _COV, "k": 2, "n_restarts": 3, "seed": 42,
                                                      "max_front": 4, "diffusion_mode": "levy", "use_obl": 1}),
    ("fractal_optimize_subset", {"item_values": [0.12, 0.09, 0.15, 0.06, 0.11], "k": 2,
                                 "upper_bounds": [0.6, 0.6, 0.6, 0.6, 0.6], "params": {}}),
    ("fractal_store_morphology", {"doc_id": 1, "feature_array": [0.1, 0.2, 0.3]}),
    ("fractal_mine_topology_negatives", {"surrogate_vector": _Q, "k": 3, "limit": 5}),
    ("fractal_ledger_load", {}),
    ("fractal_ledger_truth_count", {}),
    ("fractal_ledger_shadow_count", {}),
    ("fractal_audit_log", {"entry_type": "probe", "payload": "{\"a\": 1}"}),
    ("fractal_audit_unpack", {"blob": "00ff"}),
    ("fractal_vectorizer_create", {"source_table": "mcp_sm_docs", "text_col": "title", "embedding_col": "emb",
                                   "options": {}}),
    ("fractal_vectorizer_pause", {"id": 1}),
    ("fractal_vectorizer_resume", {"id": 1}),
    ("fractal_vectorizer_enqueue", {"id": 1, "pk_value": 1}),
    ("fractal_vectorizer_process_queue", {"batch_size": 4, "stale_after": 60}),
    # Replayed only against a throwaway daemon and a Community install (mcp_mutate.py).
    ("fractal_configure_reasoning", {"provider_url": "http://127.0.0.1:1/v1/chat/completions", "model": "m",
                                        "embed_url": "http://127.0.0.1:1/v1/embeddings", "embed_model": "e",
                                        "think_mode": "high", "allow_plaintext": True}),
    ("fractal_ledger_flush", {}),
    ("fractal_ledger_compact", {}),
    ("fractal_ledger_reset_soft", {}),
    ("fractal_vectorizer_drop", {"id": 1}),
]
