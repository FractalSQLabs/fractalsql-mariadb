// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "resources.h"
#include "db.h"
#include "config.h"
#include "fsqlctl.h"
#include "conf_file.h"
#include "errors.h"
#include "version.h"
#include <string>

namespace fsqlmcp
{
    static Db* g_db = nullptr;
    static thread_local Db* t_db = nullptr;    // per-HTTP-session binding
    static EngineConfig g_cfg;

    static Db* currentDb()
    {
        if( t_db ) return t_db;
        return g_db;
    }

    void Resources::setEngineDb( Db* db ) { g_db = db; }
    void Resources::setEngineConfig( const EngineConfig& cfg ) { g_cfg = cfg; }
    void Resources::bindThreadDb( Db* db ) { t_db = db; }

    Json Resources::list()
    {
        return Json{ { "resources", Json::array( {
            Json{ { "uri", "fractalsql://agents" },
                  { "name", "FractalSQL agents catalog" },
                  { "description", "Static, generated-from-docs catalog resource: the full \"which agent "
                                   "should I use\" decision table (the sixteen installable agents + six "
                                   "Universal Agents with their one-line recipes), so a client can pull "
                                   "the whole picture in one read instead of reconstructing it from "
                                   "twenty-two tool descriptions." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://schema" },
                  { "name", "Live schema context" },
                  { "description", "fractal_schema_context()'s own live output (all visible tables). Read "
                                   "the schema before composing a fractal_text_to_sql / fractal_sql_agent "
                                   "call, exactly the way the docs recommend auditing it first. Not cached." },
                  { "mimeType", "text/plain" } },
            Json{ { "uri", "fractalsql://config" },
                  { "name", "Resolved config surface (non-secret)" },
                  { "description", "The resolved, non-secret subset of the reasoning/text-to-sql/enterprise "
                                   "config surface: model names, plugin path, allowed-statements mode, "
                                   "edition/version, whether the daemon reports an enterprise library. "
                                   "NEVER the reasoning token or the ledger HMAC key, which are secrets "
                                   "and are never read back through any resource or tool." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://vectorizer/status" },
                  { "name", "Vectorizer status view" },
                  { "description", "fractal_vectorizer_status's own view contents: one row per "
                                   "(vectorizer_id, status) pair with counts and the most recent failure "
                                   "detail. A resource rather than a tool: pure monitoring state with no "
                                   "arguments." },
                  { "mimeType", "application/json" } },
        } ) } };
    }

    Json Resources::templates()
    {
        return Json{ { "resourceTemplates", Json::array( {
            Json{ { "uriTemplate", "fractalsql://ledger/{kind}" },
                  { "name", "Ledger audit report" },
                  { "description", "fractal_ledger_verify(kind)'s own JSON audit report, exposed as a "
                                   "resource too (not just a tool) so a periodic-context-refresh flow can "
                                   "pull the compliance state the same way it pulls the schema. kind=1 is "
                                   "the QTL chain, kind=2 the general decision-audit chain. Pure read-only "
                                   "forensic query that works on every tier. Returns the clean 'enterprise "
                                   "tier not loaded' family condition for the write-path tools; verify "
                                   "itself needs no license." },
                  { "mimeType", "application/json" } },
        } ) } };
    }

    static Json wrapRead( const std::string& uri, const char* mime, const std::string& text )
    {
        return Json{ { "contents", Json::array( { Json{ { "uri", uri }, { "mimeType", mime }, { "text", text } } } ) } };
    }

    static const char* const kAgentsJson =
        "{\n"
        "  \"installable_agents\": [\n"
        "    {\"name\": \"fractal_agent_anomaly_triage\", \"recipe\": \"Drift exponent on one entity's table-backed metric series -> LLM triage\", \"vertical\": \"SRE / IT ops / anything with a log table and a metric column\"},\n"
        "    {\"name\": \"fractal_agent_regime_triage\", \"recipe\": \"DFA + drift over a single array-in series (no table) -> LLM triage\", \"vertical\": \"quick regime checks over an in-memory series\"},\n"
        "    {\"name\": \"fractal_agent_track_anomaly\", \"recipe\": \"Trajectory deviation vs. fleet + heading-series DFA -> LLM triage\", \"vertical\": \"maritime / cybersecurity\"},\n"
        "    {\"name\": \"fractal_agent_detour_classify\", \"recipe\": \"Trajectory deviation + GPS-trace box-counting complexity -> LLM classify\", \"vertical\": \"fleet logistics\"},\n"
        "    {\"name\": \"fractal_agent_network_coverage_alert\", \"recipe\": \"Spatial morphology (box-count + lacunarity) + telemetry drift -> LLM alert\", \"vertical\": \"smart cities / IoT sensor grids\"},\n"
        "    {\"name\": \"fractal_agent_allocate\", \"recipe\": \"SFS cardinality-constrained Sharpe optimizer -> LLM rationale\", \"vertical\": \"quant finance\"},\n"
        "    {\"name\": \"fractal_agent_rebalance_sibling\", \"recipe\": \"Optimizer + nearest-historical-allocation trajectory search -> LLM rationale\", \"vertical\": \"quant finance\"},\n"
        "    {\"name\": \"fractal_agent_diverse_portfolios\", \"recipe\": \"Multi-restart diverse-candidate optimizer (sharpe or pareto mode) -> one LLM tradeoff summary over all candidates\", \"vertical\": \"quant finance\", \"tier\": \"enterprise\"},\n"
        "    {\"name\": \"fractal_agent_route_task\", \"recipe\": \"Nearest-capability search + token-budget accounting -> LLM rationale\", \"vertical\": \"agentic ops / dispatch\"},\n"
        "    {\"name\": \"fractal_agent_schedule_workload\", \"recipe\": \"Refinement + nearest-node lookup -> LLM rationale\", \"vertical\": \"workload placement / scheduling\"},\n"
        "    {\"name\": \"fractal_agent_outlier_intercept\", \"recipe\": \"Distance-to-known-bad-state safety barrier (cosine or l2) -> LLM justification\", \"vertical\": \"the Guard stage in any chain\"},\n"
        "    {\"name\": \"fractal_agent_patient_deterioration_triage\", \"recipe\": \"Cohort search + baseline->current drift -> LLM triage\", \"vertical\": \"medtech / clinical\"},\n"
        "    {\"name\": \"fractal_agent_data_analyst\", \"recipe\": \"NL question -> SQL -> execute -> LLM analysis. The horizontal catch-all agent\", \"vertical\": \"everything else (business intelligence, ad-hoc exploration)\"},\n"
        "    {\"name\": \"fractal_agent_recall_hybrid\", \"recipe\": \"Cohort-restricted vector recall. No LLM step.\", \"vertical\": \"customer support / memory\"},\n"
        "    {\"name\": \"fractal_agent_recommend_diverse\", \"recipe\": \"Repulsion-diverse top-k, avoiding recently-rejected items. No LLM step. Leaves Diversify ON for the session.\", \"vertical\": \"recommendation / catalog\"},\n"
        "    {\"name\": \"fractal_agent_feedback_audit\", \"recipe\": \"Self-contained Diversify health-check cycle (warm -> isolate -> read back -> self-disable). No LLM step.\", \"vertical\": \"verifying the stateful search layer is alive\"}\n"
        "  ],\n"
        "  \"universal_agents\": [\n"
        "    {\"name\": \"fractal_search_agent\", \"purpose\": \"Embed a query -> Scout-search a table -> reason over the matched rows' real content -> {answer, source_doc_ids, execution_time_ms}\"},\n"
        "    {\"name\": \"fractal_rag_agent\", \"purpose\": \"Lighter single-turn RAG sibling: embed -> Scout -> reason -> {answer} only\"},\n"
        "    {\"name\": \"fractal_sql_agent\", \"purpose\": \"Self-correcting NL->SQL with an explicit auto_execute flag (default off) -> {generated_sql, execution_status, result_json}\"},\n"
        "    {\"name\": \"fractal_agent_plan_explore\", \"purpose\": \"MCTS-style exploration of non-overlapping strategy trajectories -> one entry per branch\"},\n"
        "    {\"name\": \"fractal_agent_trajectory_predict\", \"purpose\": \"Forecast state by matching (current - baseline) against a table's own history\"},\n"
        "    {\"name\": \"fractal_agent_detect_loop\", \"purpose\": \"SimHash fingerprint + Brent's streaming cycle detector over a state-vector log, plus a DFA drift check\"}\n"
        "  ],\n"
        "  \"composition_principle\": \"Retrieve -> Reason -> [Act] -> [Guard]. Pick the installable agent that matches the vertical; when none does, assemble the pipeline yourself from the Universal Agents. Guard uses fractal_agent_outlier_intercept and/or fractal_agent_detect_loop after any acting step.\"\n"
        "}\n";

    Json Resources::read( const std::string& uri )
    {
        Db* db = currentDb();
        if( !db )
            throw ToolError( ErrorClass::ServerInternal, "no engine connection bound for resources" );

        if( uri == "fractalsql://schema" )
        {
            Json res = db->callProc( "fractal_schema_context", { SqlValue( nullptr ) },
                                      { "out_context" }, MergeMode::Fields );
            // The context is SCALAR text, so decodeOutVars hands back the
            // 1.5 {"value": ...} envelope -- unwrap before the text/plain
            // wrap (same live-caught shape as fractal_text_to_sql's out_sql).
            Json ctx = res.is_object() ? res.value( "out_context", Json( nullptr ) ) : Json( nullptr );
            if( ctx.is_object() && ctx.contains( "value" ) && ctx.at( "value" ).is_string() )
                ctx = ctx.at( "value" );
            return wrapRead( uri, "text/plain",
                              ctx.is_string() ? ctx.get<std::string>() : std::string() );
        }
        if( uri == "fractalsql://config" )
        {
            Json t2s = db->selectScalarJson( "SELECT fractal_t2s_config()" );
            // selectScalarJson routes non-JSON scalars through the
            // {"value": ...} envelope (db.cpp's parseJsonOrValue), so the
            // raw values here are OBJECTS, not strings. The ternary below
            // must not fall through to a Json branch: with
            // JSON_USE_IMPLICIT_CONVERSIONS on, mixing std::string and Json
            // in one conditional makes the Json branch convert implicitly to
            // std::string, and get<std::string>() on a non-string throws
            // type_error.302 ("type must be string, but is object") --
            // caught live: this resource failed outright on a stock install.
            // Unwrap the envelope first, exactly as db.cpp's version-skew
            // guard and admin.cpp's unwrap() do.
            auto unwrap = []( const Json& j ) -> Json
            {
                if( j.is_object() && j.contains( "value" ) && j.at( "value" ).is_string() )
                    return j.at( "value" );
                return j;
            };
            auto asString = []( const Json& j ) -> std::string
            {
                return j.is_string() ? j.get<std::string>() : std::string();
            };
            const Json engineVersion = unwrap( db->selectScalarJson( "SELECT fractal_version()" ) );
            const Json edition = unwrap( db->selectScalarJson( "SELECT fractal_edition()" ) );
            Json out{
                { "plugin", FSQL_MCP_PROTOCOL_NAME },
                { "plugin_version", FSQL_MCP_VERSION },
                { "engine_version", asString( engineVersion ) },
                { "edition", asString( edition ) },
                { "t2s", t2s.is_object() ? t2s : Json::object() },
                { "daemon_conf", Json::object() },
            };
            try
            {
                const std::map<std::string, std::string> conf = conffile::readConf( g_cfg.daemonConfPath );
                Json c = Json::object();
                // Allowlist, not denylist: only the documented live-editable provider/text-to-sql keys are
                // shown, and never a secret one. Anything else in the conf file (key-file paths, ledger
                // paths, future keys) is withheld by default. The conf file's own path is not published.
                for( const auto& kv : conf )
                    c[ kv.first ] = ( conffile::isEditableKey( kv.first ) && !conffile::isSecretKey( kv.first ) )
                                        ? kv.second : std::string( "<redacted>" );
                out[ "daemon_conf" ] = c;
            }
            catch( const ToolError& e )
            {
                out[ "daemon_conf" ] = Json{ { "error", e.message } };
            }
            try
            {
                FsqlCtl daemon( g_cfg.daemonSocket, g_cfg.daemonKeyPath );
                daemon.ping();
                out[ "daemon_protocol" ] = daemon.version();
            }
            catch( const ToolError& ) { out[ "daemon_protocol" ] = nullptr; }
            return wrapRead( uri, "application/json", out.dump( 2 ) );
        }
        if( uri.rfind( "fractalsql://ledger/", 0 ) == 0 )
        {
            const std::string kind = uri.substr( std::string( "fractalsql://ledger/" ).size() );
            if( kind != "1" && kind != "2" )
                throw ToolError( ErrorClass::Schema, "ledger kind must be 1 (QTL) or 2 (decision-audit)" );
            Json doc = db->callScalarBind( "SELECT fractal_ledger_verify(?, ?)",
                                            { SqlValue( static_cast<std::int64_t>( db->threadId() ) ),
                                              SqlValue( static_cast<std::int64_t>( std::stoll( kind ) ) ) } );
            return wrapRead( uri, "application/json", doc.dump( 2 ) );
        }
        if( uri == "fractalsql://vectorizer/status" )
        {
            Json rows = db->selectRowsRaw( "SELECT * FROM fractal_vectorizer_status" );
            return wrapRead( uri, "application/json", rows.dump( 2 ) );
        }
        if( uri == "fractalsql://agents" )
            return wrapRead( uri, "application/json", kAgentsJson );
        throw ToolError( ErrorClass::Schema, "unknown resource: " + uri );
    }
}