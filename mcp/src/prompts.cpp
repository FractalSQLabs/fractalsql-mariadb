// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "prompts.h"
#include "errors.h"
#include <vector>
#include <string>

namespace fsqlmcp
{
    struct PromptArg { const char* name; const char* desc; bool required; };
    struct PromptDef { const char* name; const char* desc; std::vector<PromptArg> args; const char* templateStr; };

    static const char* const kLeastPriv =
        "\n\nSafety: point this connection at a least-privilege account (column-level grants, RLS where available). "
        "This server enforces nothing beyond whatever role it was opened as. If this flow reaches "
        "fractal_sql_agent/fractal_text_to_sql, auto_execute defaults OFF; only pass auto_execute:true if you "
        "intend this agent to run the generated SQL under that same role.";

    static const std::vector<PromptDef> kPrompts{
        { "incident_triage", "DevOps/SRE: triage drift on one entity's metric series.",
          { {"log_table","Table holding the metric series.",true}, {"metric_col","Metric column.",true},
            {"time_col","Time-ordering column.",true}, {"filter_col","Entity filter column.",true}, {"filter_val","Entity filter value.",true} },
          "Call fractal_agent_anomaly_triage(log_table={log_table}, metric_col={metric_col}, time_col={time_col}, "
          "filter_col={filter_col}, filter_val={filter_val}). If it flags an anomaly, consider chaining into "
          "fractal_agent_route_task and fractal_agent_outlier_intercept." },
        { "portfolio_rebalance", "FinTech: rebalance a portfolio against its own history.",
          { {"mu","Expected returns.",true}, {"cov","Flattened covariance.",true}, {"cardinality","Max nonzero assets.",true}, {"alloc_table","Allocation-snapshots table.",true} },
          "Call fractal_agent_rebalance_sibling(mu={mu}, cov={cov}, cardinality={cardinality}, alloc_table={alloc_table}, ...). "
          "For a multi-candidate view, also try fractal_agent_diverse_portfolios (Enterprise)." },
        { "patient_triage", "MedTech: cohort-restricted patient deterioration triage.",
          { {"patient_table","Patient table.",true}, {"vec_col","Embedding column.",true}, {"query_vec","Query vector.",true}, {"cohort_predicate","Optional cohort filter.",false} },
          "Call fractal_agent_patient_deterioration_triage(patient_table={patient_table}, vec_col={vec_col}, query_vec={query_vec}, "
          "cohort_doc_ids=<rowids matching {cohort_predicate}>)." },
        { "fleet_detour_check", "Fleet-logistics: classify a vehicle detour.",
          { {"vehicle_table","Fleet table.",true}, {"baseline_vec","Baseline vector.",true}, {"current_vec","Current vector.",true}, {"gps_trace","GPS trace.",true} },
          "Call fractal_agent_detour_classify(vehicle_table={vehicle_table}, baseline_vec={baseline_vec}, current_vec={current_vec}, gps_trace={gps_trace})." },
        { "track_anomaly_check", "Maritime/cybersecurity: track-deviation / beaconing check.",
          { {"track_table","Track table.",true}, {"baseline_vec","Baseline vector.",true}, {"current_vec","Current vector.",true}, {"heading_series","Heading series.",true} },
          "Call fractal_agent_track_anomaly(track_table={track_table}, baseline_vec={baseline_vec}, current_vec={current_vec}, heading_series={heading_series})." },
        { "sensor_grid_health", "Smart-cities: sensor-grid coverage alert.",
          { {"point_cloud","Sensor-grid point cloud.",true}, {"drift_series","Drift series.",true} },
          "Call fractal_agent_network_coverage_alert(point_cloud={point_cloud}, drift_series={drift_series})." },
        { "churn_recovery", "Customer-Support: recall + diverse recommend for a churn-risk customer.",
          { {"customer_id","Customer id.",true}, {"mem_table","Memory table.",true}, {"catalog_table","Catalog table.",true} },
          "Call fractal_agent_recall_hybrid against {mem_table} for {customer_id}'s history, then "
          "fractal_agent_recommend_diverse against {catalog_table}." },
        { "ask_my_data", "Horizontal catch-all: ask a natural-language question of your data.",
          { {"question","Natural-language question.",true}, {"table_names","Tables to scope to (comma-separated).",false} },
          "Call fractal_agent_data_analyst(question={question}, table_names={table_names})." },
        { "safe_sql_question", "Just show me the SQL. Never auto-executes.",
          { {"question","Natural-language question.",true}, {"table_names","Tables to scope to (comma-separated).",false} },
          "Call fractal_text_to_sql(question={question}), or fractal_sql_agent with auto_execute explicitly OFF, "
          "and show the generated statement without running it." },
        { "diversity_audit", "Self-contained Diversify health-check cycle.",
          { {"catalog_table","Catalog table.",true}, {"emb_col","Embedding column.",true}, {"warmup_table","Warmup table.",true} },
          "Call fractal_agent_feedback_audit(catalog_table={catalog_table}, emb_col={emb_col}, warmup_table={warmup_table})." },
        { "ciso_ledger_check", "Enterprise: periodic ledger-chain integrity audit.",
          { {"kind","1 (QTL) or 2 (decision audit).",true} },
          "Call fractal_ledger_verify(kind={kind}) and report ok / rows_verified or the first_failure_id and reason." }
    };

    Json Prompts::list()
    {
        Json arr = Json::array();
        for( const PromptDef& p : kPrompts )
        {
            Json args = Json::array();
            for( const PromptArg& a : p.args )
                args.push_back( Json{ {"name",a.name}, {"description",a.desc}, {"required",a.required} } );
            arr.push_back( Json{ {"name",p.name}, {"description",p.desc}, {"arguments",args} } );
        }
        return Json{ { "prompts", arr } };
    }

    Json Prompts::get( const std::string& name, const Json& args )
    {
        for( const PromptDef& p : kPrompts )
        {
            if( p.name != name ) continue;
            std::string filled = p.templateStr;
            for( const PromptArg& a : p.args )
            {
                const std::string placeholder = "{" + std::string( a.name ) + "}";
                std::string value;
                if( args.contains( a.name ) && !args.at( a.name ).is_null() )
                    value = args.at( a.name ).is_string()
                        ? args.at( a.name ).get<std::string>()
                        : args.at( a.name ).dump();
                else if( a.required )
                    throw ToolError( ErrorClass::Schema, std::string( "missing required prompt argument: " ) + a.name );
                else
                    value = "(not provided)";
                // Caller-supplied text is DATA, not instructions: it is rendered as a JSON string literal
                // (quoted, with newlines/quotes/control characters escaped) so it cannot break out of its
                // slot or pose as a new instruction line inside the user message.
                if( args.contains( a.name ) && !args.at( a.name ).is_null() )
                    value = Json( value ).dump( -1, ' ', false, Json::error_handler_t::replace );
                // Substitute in ONE left-to-right pass over the original
                // template. The obvious "replace every occurrence, then
                // look again" loop never terminates when the argument's
                // own value contains the placeholder -- a caller that
                // passes "{sql}" as the value of the "sql" argument makes
                // the server spin forever on a request that is supposed
                // to be cheap. A single pass cannot re-scan what it just
                // inserted, so the inserted value is never a candidate.
                std::string out;
                std::size_t pos = 0;
                while( true )
                {
                    const std::size_t hit = filled.find( placeholder, pos );
                    if( hit == std::string::npos ) break;
                    out.append( filled, pos, hit - pos );
                    out += value;
                    pos = hit + placeholder.size();
                }
                out.append( filled, pos, std::string::npos );
                filled.swap( out );
            }
            if( name == "incident_triage" || name == "ask_my_data" || name == "safe_sql_question" )
                filled += kLeastPriv;
            return Json{ { "description", p.desc },
                { "messages", Json::array( { Json{ { "role", "user" }, { "content", { { "type", "text" }, { "text", filled } } } } } ) } };
        }
        throw ToolError( ErrorClass::Schema, "unknown prompt: " + name );
    }
}