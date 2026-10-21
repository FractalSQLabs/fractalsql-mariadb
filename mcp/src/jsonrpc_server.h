// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <optional>
#include <set>
#include <string>
#include <functional>
#include <memory>
#include <unordered_set>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include "mcp_json.h"
#include "tool_registry.h"
#include "rows.h"
#include "concurrency.h"

namespace fsqlmcp
{
    // Which protocol era a request belongs to. The modern era (MCP revision
    // 2026-07-28) is stateless: every request carries its own metadata and
    // there is no protocol session. The legacy era (2024-11-05 .. 2025-11-25)
    // keeps the initialize handshake and the Mcp-Session-Id header.
    enum class ProtocolEra { Legacy, Modern };

    // Per-request options the transport fills in and the dispatch core reads.
    struct CallOptions
    {
        ProtocolEra era = ProtocolEra::Legacy;
        // The context handle this request runs under (the modern era's
        // explicit per-client state handle). Empty in the legacy era, where
        // the protocol session supplies the context.
        std::string contextId;
        // The presenting credential's tool allowlist; unset means every tool.
        std::optional<std::set<std::string>> toolAllow;
    };

    struct ServerConfig
    {
        std::string serverName    = "fractalsql-mcp";
        std::string serverVersion = "0.0.0";
        RowLimitConfig rowLimits;
        // HTTP sessions build one JsonRpcServer each; the concurrency caps must stay process-wide, not
        // multiply with the number of sessions. When set, every server shares this manager.
        ConcurrencyManager* sharedConcurrency = nullptr;
        bool readOnlyMode = false;    // FSQL_MCP_READ_ONLY=true refuses every destructive call
        // FSQL_MCP_PROTOCOL_ERA=modern: refuse the legacy handshake outright
        // and answer GET/DELETE with 405 for every request.
        bool modernOnly = false;

        // Optional per-request hook (transport-agnostic, core-generic): HTTP's
        // per-session servers bind the session's engine state to the dispatching
        // thread before tools/resources touch it; stdio sets none.
        std::function<void()> requestHook = nullptr;

        // $/cancel side effect, called by cancel() while the cancelled
        // request is actually in flight: aborts this session's engine
        // statement, KILL QUERY here against the session's own connection id
        // (never this connection's own). stdio binds the one Db; an HTTP
        // session binds its own via the sessionFactory.
        std::function<void()> cancelHook = nullptr;
    };

    // Transport-agnostic dispatch core, called identically from
    // transport_stdio.cpp (per-line) and transport_http.cpp (per-POST-body).
    class JsonRpcServer
    {
    public:
        JsonRpcServer( ServerConfig cfg, std::vector<ToolSpec> tools, ConcurrencyConfig concCfg );

        // Returns std::nullopt for a notification (never reply to one).
        std::optional<std::string> handleLine( std::string_view line, const std::string& clientKey );

        // The same, with the per-request options the transport resolved: the
        // protocol era, the context handle and the credential's tool
        // allowlist.
        std::optional<std::string> handleLine( std::string_view line, const std::string& clientKey,
                                               const CallOptions& opts );

        void cancel( const std::string& requestId );      // notifications/cancelled side effect
        void beginShutdown();
        bool isShuttingDown() const { return shuttingDown_; }
        std::size_t activeRequestCount();

        const std::vector<ToolSpec>& tools() const { return tools_; }

    private:
        // The body of handleLine, split out so handleLine() can wrap it in
        // a catch-all backstop: an exception escaping the dispatch is
        // std::terminate on a worker thread (the whole server dies).
        std::optional<std::string> handleLineImpl( std::string_view line, const std::string& clientKey,
                                                   const CallOptions& opts );
        Json handleInitialize( const Json& params );
        Json handleServerDiscover();
        Json handleToolsList( const CallOptions& opts );
        Json handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId,
                              const CallOptions& opts );
        Json handleResourcesList();
        Json handleResourcesRead( const Json& params );
        Json handlePromptsList();
        Json handlePromptsGet( const Json& params );

        ServerConfig cfg_;
        std::vector<ToolSpec> tools_;
        std::unordered_map<std::string, const ToolSpec*> byName_;
        std::unique_ptr<ConcurrencyManager> ownedConc_;   // stdio: this server owns its caps
        ConcurrencyManager* conc_ = nullptr;               // HTTP sessions: the process-wide shared manager
    public:
        // Opaque ownership pin for per-session engine state (e.g. the dedicated
        // Db behind an HTTP session): freed when the server is destroyed, so a
        // session teardown closes its own connection, never another's.
        std::shared_ptr<void> statePin;
    private:
        std::mutex inflightMu_;
        std::unordered_set<std::string> inflightIds_;
        std::unordered_set<std::string> cancelledIds_;
        // Written by the main thread (beginShutdown(), once, at shutdown)
        // and read by every per-connection thread's own isShuttingDown()
        // check on each request -- a plain bool here is a genuine data race
        // (confirmed by TSan against a fully thread-instrumented build).
        std::atomic<bool> shuttingDown_{ false };
        std::atomic<std::size_t> active_{ 0 };
    };
}