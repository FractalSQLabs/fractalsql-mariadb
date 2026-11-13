// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Admin / config tier tools.
//
// On this plugin the admin tools are the one place that talks to a SEPARATE
// process from the database connection: fractalsqld, via the FSQ protocol
// over its own socket/named pipe, authenticated with its own HMAC key file
// (FSQLCTL_SOCKET / FSQLCTL_KEY) -- nothing to do with the MariaDB server's
// own auth. The tool descriptions state this explicitly.
//
// the openWorldHint marks a call that reaches an entity outside this
// database connection -- a chat-LLM or an embedding provider. The daemon is
// a LOCAL process on the same host, so the admin tier makes no such
// dispatch and openWorldHint stays OFF for every tool here. The daemon's
// own HMAC-authenticated boundary is stated in the tool text instead, and
// the set-side tools keep destructiveHint + secretHint.
//
// Config storage: fractalsqld.conf (the daemon's own file; the daemon is the
// config's authoritative home -- never the MariaDB connection, and never SET
// GLOBAL). Keys live-reloadable for the provider/text-to-sql tiers take
// effect on the tier's NEXT call; a reload never performs a plugin/library
// load itself; socket_path/hmac_key_file are refused at reload (startup-only).
//
// never touches enterprise keys or the ledger HMAC key (operator
// territory), and every set-side tool carries the destructive-hint
// annotation plus old/new-value logging (the silent-endpoint-swap guard).

#include "admin.h"
#include "helpers.h"
#include "../db.h"
#include "../config.h"
#include "../fsqlctl.h"
#include "../conf_file.h"
#include "../logging.h"
#include "../policy.h"
#include "../tool_param_helpers.h"
#include <cstdio>
#include <functional>
#include <map>
#include <optional>

namespace fsqlmcp
{
    // The engine's scalar UDF results arrive as {"value": <text>} when the
    // text is not itself JSON (db.cpp's parseJsonOrValue). Unwrap before
    // reading, so a plain 'ok' is a plain string here. File scope, so the
    // handlers below can use it without capturing it.
    static Json unwrapScalar( const Json& j )
    {
        if( j.is_object() && j.contains( "value" ) && j.at( "value" ).is_string() )
            return j.at( "value" );
        return j;
    }

    // A JSON value as TEXT, for the surfaces whose "value" field is a
    // configuration value: a config file holds text, so the field is text
    // whatever the underlying source typed it as. A JSON null has no text
    // form and stays null.
    static std::optional<std::string> jsonToText( const Json& v )
    {
        if( v.is_null() ) return std::nullopt;
        if( v.is_string() ) return v.get<std::string>();
        return v.dump();
    }

    // ------------------------------------------------------------------
    // The config-writes switch (FSQL_MCP_CONFIG_WRITES).
    //
    // off: no configuration key may be written through this boundary at
    // all. safe (the default): only the low-risk keys -- the chat model
    // name, the embedding model name and the think mode -- may be; every
    // other key is refused, including one this build does not know about.
    // all: every key may be (the operator-only and secret keys still carry
    // their own refusals).
    //
    // The refusal names the key, says what the key is set to now, and says
    // where to set it instead: the daemon's own configuration file, not a
    // tool call a model can make.
    // ------------------------------------------------------------------

    // A short, non-reversible tag of the calling client, for the refusal
    // log: enough to tell two clients apart in an incident, never the
    // credential itself.
    static std::string clientTag( const std::string& clientKey )
    {
        if( clientKey.empty() ) return std::string();
        char buf[ 24 ];
        std::snprintf( buf, sizeof buf, "c-%08zx",
                       std::hash<std::string>{}( clientKey ) & 0xffffffffu );
        return buf;
    }

    // The daemon-wide value of a configuration key, as the refusal message
    // shows it: a secret key's value is never shown, and a key that is not
    // set reads as "(unset)".
    static std::string currentConfValue( const EngineConfig& ecfg, const std::string& key )
    {
        std::map<std::string, std::string> conf;
        try { conf = conffile::readConf( ecfg.daemonConfPath ); }
        catch( ... ) { return "(unavailable)"; }
        auto it = conf.find( key );
        if( it == conf.end() ) return "(unset)";
        if( conffile::isSecretKey( key ) ) return "<redacted>";
        return it->second;
    }

    // The refusal itself. Thrown for the tools that answer a refusal as an
    // error; the session overlay answers it in its own {ok:false, reason}
    // shape instead, so that tool's documented contract is kept.
    static std::string configWriteRefusalText( const std::string& key, const std::string& current )
    {
        return "config write refused: '" + key + "' may not be written through this tool while "
               "FSQL_MCP_CONFIG_WRITES=" + std::string( configWritesModeName() ) + ". The safe set is the "
               "chat model name (reasoning_model), the embedding model name (embed_model) and the think mode "
               "(think); the endpoint URLs, the plaintext flag, the plugin path, the token and the "
               "enterprise keys are not in it. '" + key + "' is currently set to '" + current + "'. Set it in "
               "the daemon's own configuration file (fractalsqld.conf, the path FSQLCTL_CONF points at) or in "
               "the operator's environment instead of through this tool, or run the server with "
               "FSQL_MCP_CONFIG_WRITES=all if you really want this tool to write it.";
    }

    static void refuseConfigWrite( const std::string& key, const std::string& current, const CallCtx& ctx )
    {
        logging::event( "config_write_refused", Json{
            { "key", key },
            { "mode", configWritesModeName() },
            { "client", clientTag( ctx.clientKey ) } } );
        throw ToolError( ErrorClass::Schema, configWriteRefusalText( key, current ) );
    }

    std::vector<ToolSpec> buildAdminTools( Db& db, const EngineConfig& ecfg )
    {
        using namespace adap;
        std::vector<ToolSpec> t;

        auto daemonOrNull = [ &ecfg ]() -> std::unique_ptr<FsqlCtl>
        {
            return std::unique_ptr<FsqlCtl>( new FsqlCtl( ecfg.daemonSocket, ecfg.daemonKeyPath ) );
        };

        // _reload_and_report: fsqlctl reload carried through verbatim. Provider
        // keys reload live but the actual plugin/library load happens lazily on
        // the tier's next call, never during the reload itself (and enterprise_lib
        // specifically refuses a live change while a library is already loaded --
        // restart-only). The result states which case just happened.
        auto reloadAndReport = [ daemonOrNull ]() -> Json
        {
            Json out{ { "changed_keys", Json::array() } };
            try
            {
                std::unique_ptr<FsqlCtl> daemon = daemonOrNull();
                daemon->ping();   // fail fast and clean when the daemon is down
                daemon->reload();
                out[ "reloaded" ] = true;
                out[ "outcome" ] = "reloaded into the daemon; the changed tier's NEXT call picks the new "
                                   "configuration up (a reload never performs a plugin/library load itself)";
            }
            catch( const ToolError& e )
            {
                out[ "reloaded" ] = false;
                out[ "outcome" ] = "the config file was updated, but the daemon did NOT accept the reload: "
                                    + e.message + " -- the daemon kept its previous configuration (all-or-nothing)";
            }
            return out;
        };

        // Redacted old/new value for the tool result.
        auto redact = []( const std::map<std::string, std::string>& conf, const std::string& key ) -> std::string
        {
            auto it = conf.find( key );
            if( conffile::isSecretKey( key ) ) return "<redacted>";
            return it == conf.end() ? "" : it->second;
        };

        ToolSpec getVersion = mkTool( "fractal_version", "admin", "pure", ToolClass::Cheap,
            "Confirms the FractalSQL install is alive and which edition is active: "
            "{edition ('Community'/'Enterprise'), version} from the engine's own "
            "fractal_edition()/fractal_version() UDFs. The plugin's version-skew guard "
            "compares the engine's reported version against what this server was built "
            "against at startup (a warn, not a fail). daemon_version reports the "
            "fractalsqld daemon's own string (null when the daemon is unreachable).",
            {},
            [ &db, daemonOrNull ]( const Json&, CallCtx& )
            {
                // selectScalarJson routes non-JSON scalars through the
                // {"value": ...} envelope (the wrapScalar) -- unwrap
                // before reading the strings (caught live: a matching
                // install reported edition=''/version='' because the
                // handler tested the envelope object, not the string).
                auto unwrap = []( const Json& j ) -> Json
                {
                    if( j.is_object() && j.contains( "value" ) && j.at( "value" ).is_string() )
                        return j.at( "value" );
                    return j;
                };
                Json ver = unwrap( db.selectScalarJson( "SELECT fractal_version()" ) );
                Json ed  = unwrap( db.selectScalarJson( "SELECT fractal_edition()" ) );
                Json daemonVersion = nullptr;
                try
                {
                    std::unique_ptr<FsqlCtl> daemon = daemonOrNull();
                    daemonVersion = daemon->version();
                }
                catch( const ToolError& ) {}
                return Json{ { "edition", ed.is_string() ? ed.get<std::string>() : "" },
                              { "version", ver.is_string() ? ver.get<std::string>() : "" },
                              { "daemon_version", daemonVersion } };
            }, true, false );

        t.push_back( std::move( getVersion ) );

        t.push_back( mkTool( "fractal_daemon_config_get", "admin", "pure", ToolClass::Cheap,
            "Reads back a config key's resolved value, or the whole non-secret surface when no "
            "key is given. IMPORTANT (5.2): this tool reads TWO credential realms -- the "
            "text-to-sql keys come from the database connection's own fractal_t2s_config() "
            "introspection (live engine values), while the provider keys are read from the "
            "DAEMON's config file (fractalsqld.conf; this server process needs read access; set "
            "FSQLCTL_CONF to its path). Secret keys (reasoning_token, http_token, "
            "enterprise_ledger_key) are never read back: asking for one by name is refused with "
            "an error that says it is a secret, and the whole-surface read reports it as "
            "<redacted>. A single key's 'value' is always "
            "a STRING (the config file holds text, so the field is text even where the live "
            "engine value is typed) -- or null when the key is not set.",
            { Str( "key", false, "reasoning_url, reasoning_model, embed_url, embed_model, "
                                 "reasoning_allow_plaintext, think, think_provider, think_native_url, "
                                 "think_num_ctx, t2s_max_attempts, t2s_allowed_statements, "
                                 "t2s_use_review, ...; omit for the full non-secret surface" ) },
            [ &db, &ecfg ]( const Json& a, CallCtx& )
            {
                Json t2s = db.selectScalarJson( "SELECT fractal_t2s_config()" );
                Json surface{ { "t2s", Json::object() } };
                if( t2s.is_object() )
                    surface[ "t2s" ] = Json{ { "max_attempts", t2s.value( "max_attempts", Json( nullptr ) ) },
                                              { "allowed_statements", t2s.value( "allowed_statements", Json( nullptr ) ) },
                                              { "use_review", t2s.value( "use_review", Json( nullptr ) ) } };

                const bool hasKey = a.contains( "key" ) && !a.at( "key" ).is_null();
                const std::string key = hasKey ? a.at( "key" ).get<std::string>() : "";
                if( hasKey && key.rfind( "t2s_", 0 ) == 0 )
                {
                    const std::string shortKey = key.substr( 4 );
                    const Json sub = surface[ "t2s" ].value( shortKey, Json( nullptr ) );
                    const std::optional<std::string> text = jsonToText( sub );
                    return Json{ { "key", key },
                                 { "value", text ? Json( *text ) : Json( nullptr ) },
                                 { "source", "fractal_t2s_config()" } };
                }
                // The refusals come BEFORE the file is read: a key that must
                // never be read back is refused whether or not the daemon's
                // config file happens to be readable.
                if( conffile::isOperatorOnlyKey( key ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is operator territory: enabling/disabling the enterprise tier or touching "
                        "its ledger/signature posture is taken directly against the daemon's config by the "
                        "operator, never from an MCP tool call (the ledger HMAC key is a secret and is likewise "
                        "never read back or written through this surface)" );
                if( conffile::isSecretKey( key ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is a secret and is never read back through any MCP tool or resource; "
                        "set it in the daemon's own configuration file (fractalsqld.conf, the path FSQLCTL_CONF "
                        "points at) or in the operator's environment instead" );
                const std::map<std::string, std::string> conf = conffile::readConf( ecfg.daemonConfPath );
                if( !hasKey )
                {
                    Json dc = Json::object();
                    for( const auto& kv : conf )
                        dc[ kv.first ] = conffile::isSecretKey( kv.first ) ? "<redacted>" : kv.second;
                    surface[ "daemon_conf" ] = dc;
                    return surface;
                }
                Json val = nullptr;
                auto it = conf.find( key );
                if( it != conf.end() ) val = Json( it->second );
                return Json{ { "key", key },
                              { "value", val },
                              { "source", "fractalsqld.conf" } };
            }, true, false ) );

        t.push_back( mkTool( "fractal_daemon_config_set", "admin", "stateful", ToolClass::Cheap,
            "Edits ONE key of the daemon's config file and asks the daemon to reload it. TWO "
            "credential realms in one tool (5.2): the file write is local filesystem (the "
            "config's authoritative home), the reload rides the FSQ protocol authenticated by "
            "the daemon's own HMAC key -- nothing to do with MariaDB user auth. Editable keys "
            "are the reasoning provider set and the text-to-sql knobs; the enterprise keys are "
            "refused as operator territory; socket_path/hmac_key_file are startup-only and the "
            "daemon would refuse them at reload anyway. Secret keys are write-only. "
            "destructiveHint: it re-points what LLM traffic hits (10.4) -- every call is logged "
            "with the key's old AND new value. When the daemon refuses the reload (its "
            "all-or-nothing validation), the exact refusal reason is surfaced and the live "
            "config is unchanged in behavior.",
            { Str( "key", true, "one of the editable keys (reasoning_plugin, reasoning_url, reasoning_token, "
                                 "reasoning_model, reasoning_allow_plaintext, embed_url, embed_model, think, "
                                 "think_provider, think_native_url, think_num_ctx, t2s_max_attempts, "
                                 "t2s_allowed_statements, t2s_use_review)" ),
              Str( "value", true, "the new value (as a string, as the conf file stores it)" ) },
            [ &db, &ecfg, reloadAndReport ]( const Json& a, CallCtx& ctx )
            {
                const std::string key = a.at( "key" ).get<std::string>();
                std::string value = a.at( "value" ).get<std::string>();
                if( conffile::isOperatorOnlyKey( key ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is operator territory: enabling/disabling the enterprise tier or touching "
                        "its ledger/signature posture is taken directly against the daemon's config by the "
                        "operator, never from an MCP tool call (the ledger HMAC key is likewise never read "
                        "back or written through this surface)" );
                if( !conffile::isEditableKey( key ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is not one of this surface's editable keys (reasoning_plugin, reasoning_url, "
                        "reasoning_token, reasoning_model, reasoning_allow_plaintext, embed_url, embed_model, think, "
                        "think_provider, think_native_url, think_num_ctx, t2s_max_attempts, t2s_allowed_statements, "
                        "t2s_use_review); socket_path/hmac_key_file are startup-only by design, and the daemon "
                        "would refuse them at reload anyway" );
                // The config-writes switch: a key this deployment's setting
                // does not allow is refused BEFORE the file is written, so a
                // refused call leaves the daemon's configuration exactly as
                // it was.
                if( !configWriteAllowed( key ) )
                    refuseConfigWrite( key, currentConfValue( ecfg, key ), ctx );
                if( key == "t2s_max_attempts" )
                {
                    char* end = nullptr;
                    const long n = std::strtol( value.c_str(), &end, 10 );
                    if( !end || *end != '\0' || n < 1 || n > 10 )
                        throw ToolError( ErrorClass::Schema, "t2s_max_attempts must be an integer in 1-10 (the daemon "
                                                              "rejects out-of-range values by name)" );
                }
                if( key == "t2s_allowed_statements" && value != "select" && value != "select_insert_update" )
                    throw ToolError( ErrorClass::Schema,
                        "t2s_allowed_statements must be 'select' or 'select_insert_update' (the daemon rejects other values)" );
                if( key == "t2s_use_review" )
                    value = ( value != "0" && value != "false" && value != "no" ) ? "1" : "0";
                if( key == "think_num_ctx" )
                {
                    char* end = nullptr;
                    const long long n = std::strtoll( value.c_str(), &end, 10 );
                    if( !end || *end != '\0' || n < 1 || n > 10000000 )
                        throw ToolError( ErrorClass::Schema, "think_num_ctx must be an integer in 1-10000000" );
                }
                // Path keys are shape-checked BEFORE the file is written:
                // a relative path or a ".." segment would be refused by the
                // daemon at reload, but by then the bad value is already on
                // disk. The daemon's validation stays as the backstop.
                {
                    const std::string problem = conffile::pathProblem( key, value );
                    if( !problem.empty() )
                        throw ToolError( ErrorClass::Schema,
                            "'" + key + "' " + problem + " (the daemon refuses such a path at load/reload "
                            "time as well -- a relative path resolves differently depending on how the "
                            "daemon was started, and a '..' segment makes the path's meaning depend on "
                            "the operator's directory tree)" );
                }
                bool allSpace = true;
                for( char c : value ) if( !std::isspace( static_cast<unsigned char>( c ) ) ) { allSpace = false; break; }
                if( allSpace )
                    throw ToolError( ErrorClass::Schema, "empty value: the daemon's config refuses empty values" );

                // The read, the merge and the write are one step: two
                // changes at the same time would each read the file before
                // the other wrote it, and the second write would drop the
                // first one's change. The lock is held until the daemon
                // has reloaded, so the reload sees what this call wrote.
                std::lock_guard<std::mutex> confLk( conffile::confLock() );
                const std::map<std::string, std::string> confOld = conffile::readConf( ecfg.daemonConfPath );
                std::map<std::string, std::string> conf = confOld;
                std::string oldValue;
                { auto it = confOld.find( key ); oldValue = it == confOld.end() ? "" : it->second; }
                conf[ key ] = value;
                const std::string path = conffile::writeConf( ecfg.daemonConfPath, conf );
                Json outcome = reloadAndReport();
                // log old AND new for a config change (secrets stay redacted).
                const std::string oldR = conffile::isSecretKey( key ) ? "<redacted>" : oldValue;
                const std::string newR = conffile::isSecretKey( key ) ? "<redacted>" : value;
                logging::configChange( key, oldR, newR );
                outcome[ "old_value" ] = oldR;
                outcome[ "new_value" ] = newR;
                outcome[ "config_path" ] = path;
                outcome[ "changed_keys" ] = Json::array( { key } );
                return outcome;
            }, false, true, false, true ) );

        t.push_back( mkTool( "fractal_configure_reasoning", "admin", "stateful", ToolClass::Cheap,
            "Sets the LLM provider configuration (provider_url, embed_url, model, embed_model, "
            "allow_plaintext, think_mode) in the daemon's config file and reloads it. "
            "destructiveHint: this re-points every subsequent reasoning/embedding/agent call at "
            "whatever URL you give it -- an attacker-controlled endpoint silently captures all "
            "future LLM traffic (10.4), so every call is logged with old and new values, and a "
            "human-consent client UI should ask first. Reasoning tokens and the enterprise keys "
            "are NEVER set by this tool. Take effect on the tier's next call (a reload never "
            "loads the plugin/library itself). allow_plaintext exists because a local dev model "
            "may legitimately serve plaintext http -- the value lands in the daemon conf, not in "
            "this server's own config.",
            { Str( "provider_url", false, "e.g. http://host:11434/v1/chat/completions" ),
              Str( "embed_url", false, "e.g. http://host:11434/v1/embeddings" ),
              Str( "model", false, "reasoning/chat model name" ),
              Str( "embed_model", false, "embedding model name" ),
              Bool_( "allow_plaintext", false, "required to point the daemon at plaintext http://" ),
              StrEnum( "think_mode", false, "'none' (default) | 'off' | 'low' | 'medium' | 'high'" ) },
            [ &ecfg, reloadAndReport ]( const Json& a, CallCtx& ctx )
            {
                const std::string kMapping[] =
                { "provider_url:reasoning_url", "embed_url:embed_url", "model:reasoning_model",
                  "embed_model:embed_model", "allow_plaintext:reasoning_allow_plaintext",
                  "think_mode:think" };
                std::map<std::string, std::string> changes;
                for( const std::string& m : kMapping )
                {
                    const std::size_t colon = m.find( ':' );
                    const std::string toolKey = m.substr( 0, colon );
                    const std::string confKey = m.substr( colon + 1 );
                    if( !a.contains( toolKey ) || a.at( toolKey ).is_null() ) continue;
                    std::string v;
                    if( toolKey == "allow_plaintext" )
                        v = a.at( toolKey ).get<bool>() ? "1" : "0";
                    else v = a.at( toolKey ).get<std::string>();
                    changes[ confKey ] = v;
                }
                if( changes.empty() )
                    throw ToolError( ErrorClass::Schema,
                        "nothing to configure: pass at least one of provider_url/embed_url/model/"
                        "embed_model/allow_plaintext/think_mode" );
                // The read, the merge and the write are one step: two
                // changes at the same time would each read the file before
                // the other wrote it, and the second write would drop the
                // first one's change. The lock is held until the daemon
                // has reloaded, so the reload sees what this call wrote.
                std::lock_guard<std::mutex> confLk( conffile::confLock() );
                const std::map<std::string, std::string> confOld = conffile::readConf( ecfg.daemonConfPath );
                // Collect first, apply second: a call that names a key this
                // deployment's config-writes setting does not allow changes
                // NOTHING -- not the other keys in the same call, and not the
                // daemon's configuration file.
                for( const auto& kv : changes )
                    if( !configWriteAllowed( kv.first ) )
                        refuseConfigWrite( kv.first, currentConfValue( ecfg, kv.first ), ctx );
                std::map<std::string, std::string> conf = confOld;
                Json oldNew = Json::object();
                for( const auto& kv : changes )
                {
                    std::string old;
                    { auto it = confOld.find( kv.first ); old = it == confOld.end() ? "" : it->second; }
                    oldNew[ kv.first ] = { { "old", conffile::isSecretKey( kv.first ) ? "<redacted>" : old },
                                            { "new", conffile::isSecretKey( kv.first ) ? "<redacted>" : kv.second } };
                    conf[ kv.first ] = kv.second;
                    logging::configChange( kv.first, conffile::isSecretKey( kv.first ) ? "<redacted>" : old,
                                            conffile::isSecretKey( kv.first ) ? "<redacted>" : kv.second );
                }
                const std::string path = conffile::writeConf( ecfg.daemonConfPath, conf );
                Json outcome = reloadAndReport();
                outcome[ "config_path" ] = path;
                Json changed = Json::array();
                for( const auto& kv : changes ) changed.push_back( kv.first );
                outcome[ "changed_keys" ] = changed;
                outcome[ "old_new" ] = oldNew;
                return outcome;
            }, false, true, false, true ) );

        // ------------------------------------------------------------------
        // Per-session configuration overlay.
        //
        // The daemon's own config file (fractalsqld.conf) is process-wide and
        // needs a filesystem edit plus a reload to change. The overlay below
        // is the CONNECTION-scoped counterpart: a session may change the
        // TUNING keys for its own work, live, without touching the shared
        // daemon. The keys a session may NOT change are refused BY NAME,
        // with the reason, by the engine itself -- this surface never
        // decides what is allowed, it just reports the refusal.
        //
        // The session key is this connection's own CONNECTION_ID(), the same
        // key every other session-scoped tool in this plugin uses.
        // ------------------------------------------------------------------

        // The engine's scalar UDF results arrive as {"value": <text>} when
        // the text is not itself JSON (db.cpp's parseJsonOrValue); unwrapScalar
        // (file scope, above) turns that back into the plain text.
        t.push_back( mkTool( "fractal_config_set", "admin", "stateful", ToolClass::Cheap,
            "Sets ONE configuration key for THIS CONNECTION only, layered over the daemon-wide "
            "value -- no config-file edit and no daemon reload. A session may change the TUNING "
            "keys (reasoning_model, embed_model, think, think_num_ctx, t2s_max_attempts, "
            "t2s_use_review) and nothing else: the keys that decide which code the daemon "
            "loads, where its outbound traffic goes, what credentials it uses, and its transport "
            "posture are refused BY NAME, with the reason, by the engine. Returns {ok:true} on "
            "success, or {ok:false, reason:...} for a refusal. destructiveHint: it re-points "
            "what LLM traffic this session asks for (10.4) -- every call is logged with the "
            "key's old and new value.",
            { Str( "key", true, "the configuration key to override for this connection" ),
              Str( "value", true, "the new value (as a string)" ),
              Bool_( "allow_secrets", false,
                     "Must be true to write a secret-bearing key (reasoning_token, "
                     "enterprise_ledger_key) through this boundary: an explicit operator "
                     "intent, never a default. This engine's session overlay refuses "
                     "those keys by name regardless, so the flag states the intent; it "
                     "does not widen what a session may write.", false ) },
            [ &db ]( const Json& a, CallCtx& ctx )
            {
                const std::string key = a.at( "key" ).get<std::string>();
                const std::string value = a.at( "value" ).get<std::string>();
                // A secret-bearing key needs the caller's explicit intent --
                // the same rule the other engines publish this flag for.
                if( conffile::isSecretKey( key )
                    && !( a.contains( "allow_secrets" ) && !a.at( "allow_secrets" ).is_null()
                          && a.at( "allow_secrets" ).is_boolean() && a.at( "allow_secrets" ).get<bool>() ) )
                    return Json{ { "ok", false }, { "key", key },
                                 { "reason", "'" + key + "' is a secret-bearing configuration key: pass "
                                              "allow_secrets=true to make the operator's explicit intent "
                                              "explicit. This engine's session overlay refuses secret and "
                                              "enterprise keys by name either way -- they are set in the "
                                              "daemon's own config file, not from a session." } };
                // The config-writes switch: a key this deployment's setting
                // does not allow is refused BEFORE the engine is asked, so
                // the connection's overrides stay exactly as they were.
                if( !configWriteAllowed( key ) )
                {
                    // The session's own effective value for the key, as the
                    // refusal message shows it. The engine's own reader
                    // already redacts a secret and reports an unset key.
                    std::string current = "(unavailable)";
                    try
                    {
                        const std::optional<std::string> effective = db.callScalarBindText(
                            "SELECT fractal_config_get(?, ?)",
                            { SqlValue( key ), SqlValue( sessionId( db ) ) } );
                        if( effective ) current = *effective;
                    }
                    catch( ... ) { }
                    logging::event( "config_write_refused", Json{
                        { "key", key },
                        { "mode", configWritesModeName() },
                        { "client", clientTag( ctx.clientKey ) } } );
                    return Json{ { "ok", false }, { "key", key },
                                 { "reason", configWriteRefusalText( key, current ) } };
                }
                // The TEXT read, not the JSON one: the answer is either the
                // literal "ok" or a refusal reason -- a sentence, never a
                // number. Reading it as JSON would turn a reason that
                // happens to look numeric into a number, and the refusal
                // would arrive at the client as a bare 1.
                const std::optional<std::string> raw = db.callScalarBindText(
                    "SELECT fractal_config_set(?, ?, ?)",
                    { SqlValue( key ), SqlValue( value ), SqlValue( sessionId( db ) ) } );
                const std::string text = raw ? *raw : std::string();
                if( text == "ok" )
                {
                    logging::configChange( key, "(session default)", value );
                    return Json{ { "ok", true }, { "key", key }, { "value", value } };
                }
                return Json{ { "ok", false }, { "key", key },
                             { "reason", text.empty() ? std::string( "refused" ) : text } };
            }, false, true, false, true ) );

        t.push_back( mkTool( "fractal_config_get", "admin", "pure", ToolClass::Cheap,
            "Reads one configuration key's EFFECTIVE value for THIS CONNECTION: the session's own "
            "override when it has one, otherwise the daemon-wide value. A secret's value is never "
            "returned -- the result is '<redacted>' (configured) or '<unset>' (not configured). The "
            "'value' field is always a STRING, or null when the key is not set, whatever the value "
            "itself looks like. The operator-only keys (the enterprise tier's library, ledger and "
            "signature posture) are refused by name here, exactly as they are on the config-file "
            "surface: they are the operator's, and reading them back through a session is not how an "
            "operator reads them.",
            { Str( "key", true, "the configuration key to read" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                const std::string key = a.at( "key" ).get<std::string>();
                if( conffile::isOperatorOnlyKey( key ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is operator territory: enabling/disabling the enterprise tier or touching "
                        "its ledger/signature posture is taken directly against the daemon's config by the "
                        "operator, never from an MCP tool call (the ledger HMAC key is likewise never read "
                        "back or written through this surface)" );
                // The TEXT read: a configuration value is a string in the
                // config file and a string in the overlay, so "value" is
                // ALWAYS a string here (or null when the key is unset).
                // Reading it as JSON would change the field's type
                // depending on what the operator typed -- "8192" would
                // arrive as a number, "gpt-4" as a string -- and a client
                // would have to handle both.
                const std::optional<std::string> raw = db.callScalarBindText(
                    "SELECT fractal_config_get(?, ?)",
                    { SqlValue( key ), SqlValue( sessionId( db ) ) } );
                if( !raw ) return Json{ { "key", key }, { "value", Json( nullptr ) } };
                return Json{ { "key", key }, { "value", Json( *raw ) } };
            }, true ) );

        t.push_back( mkTool( "fractal_config_reset", "admin", "stateful", ToolClass::Cheap,
            "Drops every configuration override THIS CONNECTION holds, so it falls back to the "
            "daemon-wide values. Returns the number of overrides dropped.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                const Json raw = db.callScalarBind( "SELECT fractal_config_reset(?)",
                    { SqlValue( sessionId( db ) ) } );
                const Json res = unwrapScalar( raw );
                const int dropped = res.is_number_integer() ? res.get<int>() : 0;
                return Json{ { "dropped", dropped } };
            }, false ) );

        t.push_back( mkTool( "fractal_config_list", "admin", "pure", ToolClass::Cheap,
            "Lists the configuration overrides THIS CONNECTION holds, as a JSON object. An empty "
            "object means the connection is running entirely on the daemon-wide configuration.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                const Json raw = db.callScalarBind( "SELECT fractal_config_list(?)",
                    { SqlValue( sessionId( db ) ) } );
                const Json res = unwrapScalar( raw );
                return Json{ { "overrides", res.is_object() ? res : Json::object() } };
            }, true ) );

        t.push_back( mkTool( "fractal_config_keys", "admin", "pure", ToolClass::Cheap,
            "Lists every configuration key this engine knows, as a JSON array of "
            "{name, type, session_overridable} objects -- so a caller can discover which knobs a "
            "session may change instead of hard-coding the list.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                const Json raw = db.callScalarBind( "SELECT fractal_config_keys()", {} );
                const Json res = unwrapScalar( raw );
                return Json{ { "keys", res.is_array() ? res : Json::array() } };
            }, true ) );

        return t;
    }
}