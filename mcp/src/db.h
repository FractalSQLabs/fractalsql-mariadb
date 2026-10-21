// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <optional>
#include <string>
#include <vector>
#include <mutex>
#include <variant>
#include <mysql.h>
#include "mcp_json.h"
#include "errors.h"
#include "config.h"

namespace fsqlmcp
{
    // Every argument value reaches the engine through this variant, bound via
    // mysql_stmt_bind_param: no user-supplied data is ever formatted,
    // concatenated or interpolated into SQL text. The only non-parameter text
    // ever in a template is the procedure name (tool code) and the fixed
    // @fsq_out_N OUT-variable tokens.
    using SqlValue = std::variant<std::nullptr_t, std::int64_t, double, std::string>;

    enum class MergeMode { Single, Fields, None, ResultSet };

    // One MariaDB connection == one session context. A stdio server holds
    // exactly one for its process lifetime; an HTTP-mode session gets its own,
    // never reused across sessions. MariaDB-specific structural truths:
    // table-backed primitives and every agent are stored PROCEDUREs with a
    // trailing OUT, called as CALL fn(..., @fsq_result); SELECT @fsq_result;
    // session-scoped state is keyed by CONNECTION_ID() and UDFs get no
    // on-disconnect hook, so graceful shutdown issues fractal_session_close.
    class Db
    {
    public:
        Db() = default;
        ~Db() { close(); }
        Db( const Db& ) = delete;
        Db& operator=( const Db& ) = delete;

        void connect( const EngineConfig& cfg );
        void connect( const std::string& host, int port, const std::string& user,
                       const std::string& password, const std::string& database );

        // CALL proc(<binds>, @fsq_out_0[, @fsq_out_1]); then SELECT the OUT vars.
        // merge semantics (per tool, adapter-chosen, client-invisible):
        //   Single: one OUT var holding a JSON doc/array -> parsed result.
        //   Fields: several OUT vars, returned as an object keyed by outVars
        //           (e.g. text_to_sql's out_sql/out_error).
        //   None:   no OUT vars (void procedure).
        Json callProc( const std::string& proc, const std::vector<SqlValue>& params,
                        const std::vector<std::string>& outVars, MergeMode mode );

        // MergeMode::ResultSet: for the one procedure whose result arrives as an
        // ordinary SELECT result set rather than an OUT variable
        // (fractal_vectorizer_process_queue). Captures the FIRST result set's
        // first row via a bound fetch BEFORE draining the rest, so it is never
        // discarded.
        Json callProcResultSet( const std::string& proc, const std::vector<SqlValue>& params,
                                 const std::string& column = "n_processed" );

        // Plain single-value SELECT with prepared binds used by the resource
        // layer and admin handlers: the SQL text is a constant template, every
        // value reaches the engine through the driver bind.
        Json callScalarBind( const std::string& sql, const std::vector<SqlValue>& binds );

        // The same read as callScalarBind, but the value comes back as TEXT:
        // the server's bytes, exactly as sent, never re-interpreted as JSON.
        // A missing row or a SQL NULL is std::nullopt.
        //
        // WHY: some of the engine's surfaces are textual by nature -- a
        // configuration value is a string in the config file and a string in
        // the overlay, and a refusal reason is a sentence. callScalarBind
        // runs every result through parseJsonOrValue, so a configuration
        // value that happens to LOOK like a JSON number ("8192") comes back
        // as a number, and the same tool's "value" field changes type
        // depending on what the operator typed. This path keeps the type
        // stable, and keeps the text exact (no re-serialisation).
        std::optional<std::string> callScalarBindText( const std::string& sql,
                                                        const std::vector<SqlValue>& binds );

        // Constant-SQL multi-row read (no binds) used by the vectorizer-status
        // resource: SELECT * FROM a view, decoded to named-column JSON objects.
        Json selectRowsRaw( const std::string& sql );

        // Plain single-value SELECT (version/edition/skew checks; UDF reads).
        Json selectScalarJson( const std::string& expr );   // constant SQL text only

        void cancelInflight( unsigned long connectionIdToKill );
        void sessionClose();

        // Version-skew guard: warn, never hard-fail. The engine's
        // fractal_version() is compared against the version this plugin was
        // built against; a mismatch is a startup WARN line, because the SQL
        // surface is stable across the compat matrix.
        void checkVersionSkew( const std::string& engineVersionExpected );

        void close();   // sessionClose() first, then the socket

        unsigned long threadId() const { return conn_ ? mysql_thread_id( conn_ ) : 0; }
        bool probeAlive();
        MYSQL* raw() const { return conn_; }
        std::mutex& mutex() { return mu_; }

    private:
        // connect()'s phases, broken out 1:1 (same order, same behavior,
        // same exceptions) so each stays small on its own.

        // Opens the socket and authenticates. Throws Connectivity on refusal.
        void openDatabase( const EngineConfig& cfg );

        // Partial-result mode: the per-session opt-in run at the end of connect(), a
        // bound SELECT against the agent_partial_reasoning_fail session flag
        // (EngineConfig::agentPartialReasoningFail / FSQL_MCP_AGENT_PARTIAL).
        // Never fatal: an engine build without the flag UDF just keeps the
        // engine's raise behavior, recorded as a startup WARN line.
        void bootstrapSession( const EngineConfig& cfg );

        // FSQL_MCP_READ_ONLY=true: one bound SELECT fractal_lock_destructive(?)
        // against this connection's id. Never fatal: an engine build without the
        // UDF is recorded as a WARN and the server's own refusal stays in force.
        void applyDestructiveLatch( const EngineConfig& cfg );

        Json parseJsonOrValue( const char* text ) const;
        ToolError classify( const std::string& msg, unsigned int code ) const;
        // The bound single-value read, returning the first column's TEXT
        // exactly as the server sent it (no JSON interpretation). False
        // means no row or a SQL NULL. CALLER CONTRACT: mu_ already held.
        bool scalarTextLocked( const std::string& sql, const std::vector<SqlValue>& binds,
                               std::string& out );
        // CALLER CONTRACT: mu_ already held (callProc's tail under its
        // lock; see decodeOutVars' own comment in db.cpp).
        Json decodeOutVars( const std::vector<std::string>& outVars, MergeMode mode );

        MYSQL* conn_ = nullptr;
        EngineConfig cfg_;      // kept for cancelInflight's control connection
        std::mutex mu_;
    };

    // One-shot KILL QUERY on a short-lived control connection: never the
    // connection running the call itself.
    void killQuery( const EngineConfig& cfg, unsigned long connectionId );
}