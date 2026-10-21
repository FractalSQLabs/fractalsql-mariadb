// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "transport_http.h"
#include "errors.h"
#include "logging.h"
#include "policy.h"
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>
#include <openssl/err.h>
#include <openssl/hmac.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <fstream>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>
#include <chrono>
#include <map>
#include <set>
#include <optional>
#include <vector>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <cctype>
#include <cerrno>
#include <csignal>
#include <algorithm>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>
  typedef int socklen_t;
  // Winsock2 has no inet_pton(); the WinSock spelling of the same call is
  // InetPtonA (Vista+). Same signature, same return convention.
  #define inet_pton InetPtonA
#else
  #include <sys/socket.h>
  #include <sys/resource.h>
  #include <sys/time.h>
  #include <poll.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #include <sys/stat.h>
#endif

// Close a socket, on either platform. The two spellings are genuinely
// different functions -- WinSock's closesocket() and POSIX's close() --
// so this is a small inline shim rather than a macro: a macro named
// `closesocket` that expanded to `::close` broke the one QUALIFIED call
// site (`::closesocket(fd)` expanded to `::::close`, which is not a
// valid expression), and a macro that expanded to a bare `close` would
// instead be open to a member-function lookup shadowing it. The shim has
// neither problem: the call is always unqualified and always resolves
// to the global function.
#ifdef _WIN32
  inline void fsqlCloseSocket( int fd ) { ::closesocket( fd ); }
  inline void fsqlHalfCloseSend( int fd ) { ::shutdown( fd, SD_SEND ); }
  inline void fsqlSetRecvTimeoutMs( int fd, int ms )
  { DWORD t = static_cast<DWORD>( ms ); ::setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>( &t ), sizeof( t ) ); }
#else
  inline void fsqlCloseSocket( int fd ) { ::close( fd ); }
  inline void fsqlHalfCloseSend( int fd ) { ::shutdown( fd, SHUT_WR ); }
  inline void fsqlSetRecvTimeoutMs( int fd, int ms )
  { timeval t{ ms / 1000, ( ms % 1000 ) * 1000 }; ::setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof( t ) ); }
#endif

// Closes after a refusal reply: half-closes, reads and discards the client's
// pending request for up to lingerMs, then closes. A plain close with unread
// data resets the connection, and the reset discards the reply that was just
// written -- the peer then sees a broken connection instead of the refusal it
// was owed (seen on Windows).
inline void fsqlCloseAfterReply( int fd, int lingerMs )
{
    fsqlHalfCloseSend( fd );
    fsqlSetRecvTimeoutMs( fd, 100 );
    char sink[ 4096 ];
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( lingerMs );
    while( std::chrono::steady_clock::now() < deadline )
    {
        const int n = static_cast<int>( ::recv( fd, sink, sizeof( sink ), 0 ) );
        if( n == 0 ) break;   // the peer closed: nothing more can arrive
        if( n < 0 )
        {
            // No data yet (or a signal landed mid-read): keep waiting for the
            // rest of the peer's request.
#ifdef _WIN32
            const int e = WSAGetLastError();
            if( e != WSAETIMEDOUT && e != WSAEWOULDBLOCK ) break;
#else
            if( errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR ) break;
#endif
        }
    }
    fsqlCloseSocket( fd );
}

// Minimal threaded HTTP/1.1 listener :
//   GET  /healthz -> 200, no auth, no DB touch
//   GET  /readyz  -> readinessProbe() ? 200 : 503, no auth
//   POST <path>    -> auth required; initialize mints Mcp-Session-Id, every
//                     other method requires it (400 missing / 404 unknown);
//                     body capped at 32 MiB; dispatched on the connection's
//                     worker thread, reply written only after dispatch returns
//                     (concurrency bounded by ConcurrencyManager, not thread
//                     count)
// One request per connection: the reply is written, then the connection is
// closed. The MCP HTTP transport is a request/response protocol, so a
// keep-alive loop bought nothing and cost a class of lifetime bugs.
//   DELETE <path>  -> closes the named session's dedicated DB connection
// SIGTERM/SIGINT -> sessions drain up to cfg.shutdownDrainMs, then the
// listening socket is closed. SIGHUP -> reload the auth token ONLY, never
// shutdown. The reload itself runs on the request path, not in the signal
// handler: the handler only raises a flag, because the reload is file I/O
// plus allocation and neither is async-signal-safe.

namespace fsqlmcp
{
    static constexpr std::size_t kBodyMax = 32 * 1024 * 1024;

    // The most body bytes the server reads and throws away for a request
    // it refuses before it looks at the body.
    static constexpr std::size_t kDrainMax = 64 * 1024;

    // SIGHUP means "reload the auth token", and that reload is file I/O plus
    // allocation. Doing that work inside the signal handler is not
    // async-signal-safe: it can deadlock against the malloc arena lock the
    // interrupted thread already held (observed as a TSan-reported hang
    // under a fully thread-instrumented build), and it can corrupt the
    // TokenStore's own mutex if the interrupted thread was inside reload().
    //
    // So the handler only sets a flag. The reload itself happens on the
    // ordinary request path (matches() -> maybeReload()), which is not
    // signal context and is free to block on I/O.
    static std::atomic<bool> g_sighupReload{ false };

    class TokenStore
    {
    public:
        // The config is held BY VALUE: a connection thread can outlive
        // runHttpTransport() (the shutdown path detaches whatever is still
        // in flight), and a reference to the caller's config would dangle
        // by then.
        explicit TokenStore( const HttpConfig& cfg ) : cfg_( cfg ) { reload( true ); }

        // What a presented credential turned out to be.
        struct Credential
        {
            bool ok = false;
            bool expired = false;
            std::string clientName;                        // the policy entry's name, or a token-derived key
            std::optional<std::set<std::string>> allow;    // unset = every tool
        };

        // The timing-safe compare lives here. One lock only: the reload
        // (mtime check) reads token state, so it happens under the same
        // guard as the compare.
        Credential check( const std::string& presented )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            // A SIGHUP asked for a forced reload; the request path performs
            // it here, outside signal context. The flag is consumed exactly
            // once, and exchange() (not load()) keeps two concurrent
            // requests from both forcing a redundant reload.
            const bool forced = g_sighupReload.exchange( false, std::memory_order_relaxed );
            if( forced || !cfg_.authTokenFile.empty() || !cfg_.tokenPolicyFile.empty() )
                reload( forced );
            if( presented.empty() ) return Credential{};

            if( !token_.empty() && presented.size() == token_.size() &&
                CRYPTO_memcmp( presented.data(), token_.data(), token_.size() ) == 0 )   // timing-safe
            {
                Credential c;
                c.ok = true;
                // The identity of a deployment-token holder: a short digest
                // of the token, never the token itself.
                c.clientName = "token:" + sha256Hex( presented ).substr( 0, 8 );
                return c;
            }

            if( policies_.empty() ) return Credential{};

            // Per-client credentials: the presented token's SHA-256 against
            // every entry. No early exit: the work per attempt stays the
            // same whether or not the hash matches.
            const std::string hex = sha256Hex( presented );
            Credential out;
            bool known = false;
            for( const PolicyEntry& e : policies_ )
            {
                if( e.sha256.size() != hex.size() ) continue;
                if( CRYPTO_memcmp( e.sha256.data(), hex.data(), hex.size() ) != 0 ) continue;
                known = true;
                if( e.expired() ) { out.expired = true; continue; }
                out.ok = true;
                out.clientName = e.name.empty() ? ( "client:" + hex.substr( 0, 8 ) ) : e.name;
                out.allow = e.allTools ? std::nullopt
                                       : std::optional<std::set<std::string>>( e.tools );
            }
            if( !known ) return Credential{};
            return out;
        }

        static std::string sha256Hex( const std::string& v )
        {
            unsigned char d[ SHA256_DIGEST_LENGTH ];
            SHA256( reinterpret_cast<const unsigned char*>( v.data() ), v.size(), d );
            static const char* const kHex = "0123456789abcdef";
            std::string out;
            for( int i = 0; i < SHA256_DIGEST_LENGTH; ++i )
            { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
            return out;
        }

        // A malformed policy file keeps the last good one and says so; the
        // caller surfaces the message at startup.
        std::string policyError()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            return policyError_;
        }

    private:
        struct PolicyEntry
        {
            std::string name;
            std::string sha256;
            bool allTools = false;
            std::set<std::string> tools;
            std::time_t expiresAt = 0;      // 0 = never expires
            bool expired() const
            {
                if( expiresAt == 0 ) return false;
                return std::time( nullptr ) >= expiresAt;
            }
        };

        // Parses an ISO-8601 expiry: "YYYY-MM-DD" or
        // "YYYY-MM-DDTHH:MM:SSZ". Returns 0 when the text is not a usable
        // expiry, which the caller treats as "no expiry given".
        static std::time_t parseExpiry( const std::string& text )
        {
            if( text.size() < 10 ) return 0;
            std::tm tm{};
            int y = 0, mo = 0, d = 0, h = 0, mi = 0, se = 0;
            if( std::sscanf( text.c_str(), "%d-%d-%dT%d:%d:%d", &y, &mo, &d, &h, &mi, &se ) < 3 &&
                std::sscanf( text.c_str(), "%d-%d-%d", &y, &mo, &d ) < 3 )
                return 0;
            if( y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31 ) return 0;
            tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d;
            tm.tm_hour = h; tm.tm_min = mi; tm.tm_sec = se;
            return utcToTimeT( tm );
        }

        // UTC calendar time -> time_t. timegm() is POSIX; the MSVC CRT has
        // _mkgmtime() instead.
#if defined( _WIN32 )
        static std::time_t utcToTimeT( std::tm& tm )
        { return static_cast<std::time_t>( _mkgmtime( &tm ) ); }
#else
        static std::time_t utcToTimeT( std::tm& tm )
        { return timegm( &tm ); }
#endif

        // Reads the per-client credential file. The file holds no secret
        // (only the SHA-256 of each token), so it is re-read whenever it
        // changes on disk.
        void loadPolicyLocked()
        {
            if( cfg_.tokenPolicyFile.empty() ) return;
            std::ifstream in( cfg_.tokenPolicyFile, std::ios::binary );
            if( !in ) { policyError_ = "cannot read the credential file " + cfg_.tokenPolicyFile; return; }
            const std::string text( ( std::istreambuf_iterator<char>( in ) ), std::istreambuf_iterator<char>() );
            std::vector<PolicyEntry> next;
            try
            {
                const Json doc = Json::parse( text );
                if( !doc.is_object() || !doc.contains( "tokens" ) || !doc.at( "tokens" ).is_array() )
                    throw std::runtime_error( "expected {\"tokens\":[...]}" );
                for( const Json& t : doc.at( "tokens" ) )
                {
                    PolicyEntry e;
                    if( t.contains( "name" ) && t.at( "name" ).is_string() )
                        e.name = t.at( "name" ).get<std::string>();
                    if( !t.contains( "sha256" ) || !t.at( "sha256" ).is_string() )
                        throw std::runtime_error( "each token needs a \"sha256\" string" );
                    e.sha256 = t.at( "sha256" ).get<std::string>();
                    if( e.sha256.size() != 64 ) throw std::runtime_error( "sha256 must be 64 hex digits" );
                    for( char& c : e.sha256 ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
                    if( !t.contains( "tools" ) ) throw std::runtime_error( "each token needs a \"tools\" list" );
                    const Json& tools = t.at( "tools" );
                    if( tools.is_string() && tools.get<std::string>() == "*" ) e.allTools = true;
                    else if( tools.is_array() )
                    {
                        for( const Json& n : tools )
                        {
                            if( !n.is_string() )
                                throw std::runtime_error( "each tool name in \"tools\" must be a string" );
                            e.tools.insert( n.get<std::string>() );
                        }
                    }
                    else throw std::runtime_error( "tools must be \"*\" or an array of tool names" );
                    if( t.contains( "expires" ) && t.at( "expires" ).is_string() )
                    {
                        e.expiresAt = parseExpiry( t.at( "expires" ).get<std::string>() );
                        if( e.expiresAt == 0 )
                            throw std::runtime_error( "expires must be an ISO-8601 date/time (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)" );
                    }
                    next.push_back( std::move( e ) );
                }
            }
            catch( const std::exception& ex )
            {
                policyError_ = std::string( "FSQL_MCP_TOKEN_POLICY_FILE is not valid: " ) + ex.what();
                return;   // keep the last good policy
            }
            policies_ = std::move( next );
            policyError_.clear();
        }

        // reload() runs with mu_ held; the mtime hot reload happens
        // whenever check() is called on the file-token form.
        void reload( bool force )
        {
            if( !cfg_.authTokenFile.empty() )
            {
                time_t cur = 0;
                if( fileMtime( cfg_.authTokenFile, cur ) )
                {
                    if( force || cur != lastMtime_ )
                    {
                        std::ifstream in( cfg_.authTokenFile, std::ios::binary );
                        if( in )
                        {
                            std::string t; std::getline( in, t );
                            if( !t.empty() && t.back() == '\r' ) t.pop_back();
                            // An unreadable/empty file never silently disables auth:
                            // token_ is only replaced when the file yields a token.
                            if( !t.empty() ) { token_ = t; lastMtime_ = cur; }
                        }
                    }
                }
                // stat failed: keep serving the last known token
            }
            else
                token_ = cfg_.authToken;    // plain env-var form: no hot-reload

            // The credential file is re-read whenever it changed on disk or
            // on a forced reload (SIGHUP): it is small and holds no secret.
            if( !cfg_.tokenPolicyFile.empty() )
            {
                time_t cur = 0;
                if( fileMtime( cfg_.tokenPolicyFile, cur ) )
                {
                    if( force || cur != lastPolicyMtime_ ) { loadPolicyLocked(); lastPolicyMtime_ = cur; }
                }
                else if( !policyLoaded_ ) { loadPolicyLocked(); policyLoaded_ = true; }
            }
            else if( !policyLoaded_ ) { policyLoaded_ = true; }
        }

        static bool fileMtime( const std::string& path, time_t& out )
        {
#ifdef _WIN32
            HANDLE h = CreateFileA( path.c_str(), FILE_READ_ATTRIBUTES,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr );
            if( h == INVALID_HANDLE_VALUE ) return false;
            FILETIME ft{};
            const bool ok = GetFileTime( h, nullptr, nullptr, &ft ) != 0;
            CloseHandle( h );
            if( !ok ) return false;
            out = ( static_cast<time_t>( ft.dwHighDateTime ) << 32 ) | ft.dwLowDateTime;
            return true;
#else
            struct stat st{};
            if( ::stat( path.c_str(), &st ) != 0 ) return false;
            out = st.st_mtime;
            return true;
#endif
        }

        HttpConfig cfg_;
        std::mutex mu_;
        std::string token_;
        time_t lastMtime_ = 0;
        std::vector<PolicyEntry> policies_;
        std::string policyError_;
        time_t lastPolicyMtime_ = 0;
        bool policyLoaded_ = false;
    };

    // The startup check for the per-client credential file.
    std::string tokenPolicyError( const HttpConfig& cfg )
    {
        TokenStore store( cfg );
        return store.policyError();
    }

    // SIGHUP means "reload the auth token", and that reload is file I/O plus
    // allocation. Doing that work inside the signal handler is not
    // async-signal-safe: it can deadlock against the malloc arena lock the
    // interrupted thread already held (observed as a TSan-reported hang
    // under a fully thread-instrumented build), and it can corrupt the
    // TokenStore's own mutex if the interrupted thread was inside reload().
    //
    // So the handler only sets a flag. The reload itself happens on the
    // ordinary request path (matches() -> maybeReload()), which is not
    // signal context and is free to block on I/O.
    static std::atomic<bool> g_httpSignalled{ false };
    static void onHttpTermSignal( int ) { g_httpSignalled.store( true ); }

    // Most connections served at once. Each one holds a thread and a
    // descriptor before it has authenticated, so the count is bounded:
    // FSQL_MCP_MAX_CONNECTIONS overrides the default of 256, and on POSIX
    // the result never exceeds half the process's descriptor limit.
    static std::size_t maxConnections()
    {
        long n = 256;
        if( const char* v = std::getenv( "FSQL_MCP_MAX_CONNECTIONS" ) )
        {
            const long x = std::strtol( v, nullptr, 10 );
            if( x > 0 ) n = x;
        }
#ifndef _WIN32
        rlimit rl{};
        if( getrlimit( RLIMIT_NOFILE, &rl ) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur > 8 )
            n = std::min<long>( n, static_cast<long>( rl.rlim_cur / 2 ) );
#endif
        return static_cast<std::size_t>( n );
    }

    // A refused connection is closed only after the peer's request has been
    // read and discarded, so the refusal itself is not lost. The window is
    // long enough for a client that is slow to write its request, and short
    // enough that a refused connection does not hold anything for long.
    static constexpr int kRefusalLingerMs = 1000;

    // How many refusals may be delivering themselves at once. A flood of
    // connections past the limit must not turn into a flood of threads.
    static constexpr int kMaxRefusalsInFlight = 64;

    // Bounds how long a read or write on this socket may block.
    static void setSocketTimeoutMs( int fd, int ms )
    {
#ifdef _WIN32
        DWORD v = static_cast<DWORD>( ms );
        setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>( &v ), sizeof( v ) );
        setsockopt( fd, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>( &v ), sizeof( v ) );
#else
        timeval tv{ ms / 1000, ( ms % 1000 ) * 1000 };
        setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof( tv ) );
        setsockopt( fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof( tv ) );
#endif
    }

    // Waits up to `ms` for a pending connection. A handler installed with
    // std::signal restarts a blocked accept(), so the accept loop waits here
    // in short slices and re-checks g_httpSignalled between them.
    static bool waitForConnection( int listenFd, int ms )
    {
#ifdef _WIN32
        WSAPOLLFD p{ static_cast<SOCKET>( listenFd ), POLLRDNORM, 0 };
        return WSAPoll( &p, 1, ms ) > 0;
#else
        pollfd p{ listenFd, POLLIN, 0 };
        return ::poll( &p, 1, ms ) > 0;
#endif
    }
#ifdef SIGHUP
    static void onSighup( int ) { g_sighupReload.store( true, std::memory_order_relaxed ); }
#endif

    // A context handle: 128 bits of randomness, hex.
    static std::string mintContextId()
    {
        unsigned char rnd[ 16 ] = {};
        if( RAND_bytes( rnd, sizeof( rnd ) ) != 1 )
        {
            RAND_poll();
            ( void ) RAND_bytes( rnd, sizeof( rnd ) );
        }
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( unsigned char c : rnd )
        {
            out.push_back( kHex[ c >> 4 ] );
            out.push_back( kHex[ c & 0xF ] );
        }
        return out;
    }

    // ---- client state registry: one JsonRpcServer per client state, each
    // built over its own dedicated DB connection via cfg.sessionFactory ----
    //
    // Three kinds of entry live here, and each one pins its own dedicated
    // engine connection:
    //
    //  - a protocol SESSION (the legacy era's Mcp-Session-Id). The session
    //    owns its context, and the context's handle IS the session id.
    //  - a CONTEXT (the modern era's explicit context_id handle): the state
    //    handle a client passes back to keep using the same engine state.
    //  - a CREDENTIAL context (the modern era's stateless calls): the
    //    credential's own connection.
    //
    // The registry as a whole is capped (FSQL_MCP_MAX_SESSIONS, default 64)
    // and every entry expires when idle (FSQL_MCP_SESSION_TTL_SECS, default
    // 3600), so neither the map nor the engine connections behind it can
    // grow without bound. Every entry is bound to the fingerprint of the
    // credential that created it: a request presenting a different token
    // neither sees nor tears it down, and is told the handle does not exist.
    class ClientRegistry
    {
    public:
        struct Entry
        {
            std::shared_ptr<JsonRpcServer> srv;
            std::string ownerFp;                                   // fingerprint of the creating credential
            std::chrono::steady_clock::time_point lastUse;
        };

        explicit ClientRegistry( const HttpConfig& cfg ) : cfg_( cfg ) {}

        // ---- legacy protocol sessions ----

        // Throws through with whatever the factory raised (e.g. Connectivity when
        // MariaDB rejects a new session's connection).
        std::shared_ptr<JsonRpcServer> createSession( const std::string& owner, std::string& idOut )
        {
            // Bound the registry: idle entries expire (FSQL_MCP_SESSION_TTL_SECS, default 3600) and the
            // number of live entries is capped (FSQL_MCP_MAX_SESSIONS, default 64), because every entry
            // pins a dedicated engine connection and an entry that is only removed by an explicit DELETE
            // would otherwise grow without bound.
            evictIdle();
            {
                std::lock_guard<std::mutex> lk( mu_ );
                if( sizeLocked() >= maxSessions() )
                    throw ToolError( ErrorClass::Connectivity, "too many open MCP sessions" );
            }
            std::unique_ptr<JsonRpcServer> srv = cfg_.sessionFactory();
            const std::string id = mintContextId();
            std::lock_guard<std::mutex> lk( mu_ );
            Entry e{ makeServer( std::move( srv ) ), owner, std::chrono::steady_clock::now() };
            sessions_[ id ] = e;
            idOut = id;
            return e.srv;
        }

        // Returns a SHARED reference, not a raw pointer. A raw pointer
        // handed back under the lock was a use-after-free waiting to
        // happen: the DELETE handler on another connection thread can
        // erase() this session -- destroying the server -- while the
        // request thread that resolved it is still inside handleLine().
        // The shared reference keeps the server alive until the in-flight
        // request is done with it; the session's Db (held by statePin)
        // closes on the last release.
        // A session belongs to the credential that created it: a request presenting a different
        // token (e.g. after a token rotation, or a second token) neither sees nor tears it down,
        // and gets the same "not found" as an unknown id so existence is not revealed.
        std::shared_ptr<JsonRpcServer> findSession( const std::string& id, const std::string& owner )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            auto it = sessions_.find( id );
            if( it == sessions_.end() ) return nullptr;
            if( it->second.ownerFp != owner ) return nullptr;
            it->second.lastUse = std::chrono::steady_clock::now();
            return it->second.srv;
        }

        bool eraseSession( const std::string& id, const std::string& owner )
        {
            std::shared_ptr<JsonRpcServer> dead;
            {
                std::lock_guard<std::mutex> lk( mu_ );
                auto it = sessions_.find( id );
                if( it == sessions_.end() ) return false;
                if( it->second.ownerFp != owner ) return false;
                dead = it->second.srv;
                sessions_.erase( it );
            }
            dead.reset();    // the session's Db (captured in its handlers) closes here
            return true;
        }

        // ---- modern contexts ----

        // Finds the context a request names. Returns nullptr when the handle
        // does not exist or belongs to another credential: the caller answers
        // "not found" either way, so a client can neither use nor probe for a
        // handle it does not own.
        std::shared_ptr<JsonRpcServer> findContext( const std::string& requested, const std::string& owner,
                                                     std::string& idOut )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            auto it = contexts_.find( requested );
            if( it == contexts_.end() || it->second.ownerFp != owner ) return nullptr;
            it->second.lastUse = std::chrono::steady_clock::now();
            idOut = requested;
            return it->second.srv;
        }

        // Mints a fresh context: its own dedicated engine connection, and a
        // handle the client passes back on the next call.
        std::shared_ptr<JsonRpcServer> createContext( const std::string& owner, std::string& idOut )
        {
            evictIdle();
            {
                std::lock_guard<std::mutex> lk( mu_ );
                if( sizeLocked() >= maxSessions() )
                    throw ToolError( ErrorClass::Connectivity, "too many open MCP sessions" );
            }
            std::unique_ptr<JsonRpcServer> srv = cfg_.sessionFactory();
            const std::string id = mintContextId();
            std::lock_guard<std::mutex> lk( mu_ );
            Entry e{ makeServer( std::move( srv ) ), owner, std::chrono::steady_clock::now() };
            contexts_[ id ] = e;
            idOut = id;
            return e.srv;
        }

        // The credential's own connection, for a modern call that keeps no
        // state of its own. Created on first use and reused after that.
        // The key is the credential AND its owner, so two credentials that
        // happen to share a name never share a connection.
        std::shared_ptr<JsonRpcServer> credentialContext( const std::string& credKey,
                                                           const std::string& owner )
        {
            {
                std::lock_guard<std::mutex> lk( mu_ );
                auto it = creds_.find( credKey );
                if( it != creds_.end() && it->second.ownerFp == owner )
                {
                    it->second.lastUse = std::chrono::steady_clock::now();
                    return it->second.srv;
                }
            }
            evictIdle();
            {
                std::lock_guard<std::mutex> lk( mu_ );
                if( sizeLocked() >= maxSessions() )
                    throw ToolError( ErrorClass::Connectivity, "too many open MCP sessions" );
            }
            std::unique_ptr<JsonRpcServer> srv = cfg_.sessionFactory();
            std::lock_guard<std::mutex> lk( mu_ );
            Entry e{ makeServer( std::move( srv ) ), owner, std::chrono::steady_clock::now() };
            creds_[ credKey ] = e;
            return e.srv;
        }

        static std::size_t maxSessions()
        {
            const char* v = std::getenv( "FSQL_MCP_MAX_SESSIONS" );
            const long n = v && *v ? std::atol( v ) : 64;
            return n > 0 ? static_cast<std::size_t>( n ) : 64;
        }
        static std::chrono::seconds sessionTtl()
        {
            const char* v = std::getenv( "FSQL_MCP_SESSION_TTL_SECS" );
            const long n = v && *v ? std::atol( v ) : 3600;
            return std::chrono::seconds( n > 0 ? n : 3600 );
        }

        void evictIdle()
        {
            std::vector<std::shared_ptr<JsonRpcServer>> dead;   // destroyed outside the lock
            {
                std::lock_guard<std::mutex> lk( mu_ );
                const auto now = std::chrono::steady_clock::now();
                const auto ttl = sessionTtl();
                for( auto* map : { &sessions_, &contexts_, &creds_ } )
                    for( auto it = map->begin(); it != map->end(); )
                    {
                        if( now - it->second.lastUse > ttl )
                        {
                            dead.push_back( it->second.srv );
                            it = map->erase( it );
                        }
                        else ++it;
                    }
            }
        }

        void endAll()
        {
            std::vector<std::shared_ptr<JsonRpcServer>> dead;
            {
                std::lock_guard<std::mutex> lk( mu_ );
                for( auto* map : { &sessions_, &contexts_, &creds_ } )
                    for( auto& kv : *map ) dead.push_back( kv.second.srv );
                sessions_.clear();
                contexts_.clear();
                creds_.clear();
            }
            dead.clear();
        }

    private:
        // The teardown callback is tied to the SERVER's own destruction, not
        // to the removal of the map slot: that is the only ordering that
        // holds when an in-flight request still holds the server alive, and
        // it is the order the config documents ("after its server is
        // destroyed"). The callback is copied into the deleter so the
        // deleter does not depend on this registry's lifetime.
        std::shared_ptr<JsonRpcServer> makeServer( std::unique_ptr<JsonRpcServer> srv )
        {
            auto teardown = cfg_.sessionTeardown;
            return std::shared_ptr<JsonRpcServer>( srv.release(),
                [ teardown ]( JsonRpcServer* p )
                {
                    delete p;
                    if( teardown ) teardown();
                } );
        }

        std::size_t sizeLocked() const
        { return sessions_.size() + contexts_.size() + creds_.size(); }

        HttpConfig cfg_;
        std::mutex mu_;
        std::map<std::string, Entry> sessions_;   // session id -> its own context (the handle IS the session id)
        std::map<std::string, Entry> contexts_;   // context handle -> its own engine connection
        std::map<std::string, Entry> creds_;      // credential name -> that credential's own connection
    };

    // Non-reversible fingerprint of the presented bearer token (never log or return it).
    static std::string tokenFingerprint( const std::string& bearer )
    {
        unsigned char d[ SHA256_DIGEST_LENGTH ];
        SHA256( reinterpret_cast<const unsigned char*>( bearer.data() ), bearer.size(), d );
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( int i = 0; i < 16; ++i ) { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
        return out;
    }

    static std::string clientKeyFor( const std::string& bearer, const std::string& sessionId )
    {
        // Session id when the deployment uses the file-token form, a raw
        // token prefix would collapse per-client fairness to one bucket when
        // the whole team shares one static token.
        return sessionId.empty() ? ( "token:" + bearer.substr( 0, 8 ) ) : ( "session:" + sessionId );
    }

    // ---- wire abstraction: plain socket or OpenSSL TLS BIO ----
    struct Wire
    {
        virtual ~Wire() = default;
        virtual int sendAll( const char* data, std::size_t len ) = 0;
        virtual int recvSome( char* buf, std::size_t max ) = 0;
        virtual void closeWire() = 0;
        virtual void setTimeoutMs( int ms ) = 0;
    };
    using WirePtr = std::unique_ptr<Wire>;

    class PlainWire : public Wire
    {
    public:
        explicit PlainWire( int fd ) : fd_( fd ) {}
        int sendAll( const char* data, std::size_t len ) override
        {
            std::size_t off = 0;
            while( off < len )
            {
                const int n = ::send( fd_, data + off, static_cast<int>( len - off ), 0 );
                if( n <= 0 ) return -1;
                off += static_cast<std::size_t>( n );
            }
            return 0;
        }
        int recvSome( char* buf, std::size_t max ) override
        {
            return static_cast<int>( ::recv( fd_, buf, static_cast<int>( max ), 0 ) );
        }
        void closeWire() override { if( fd_ >= 0 ) { fsqlCloseSocket( fd_ ); fd_ = -1; } }
        void setTimeoutMs( int ms ) override { if( fd_ >= 0 ) setSocketTimeoutMs( fd_, ms ); }
    private:
        int fd_ = -1;
    };

    class TlsWire : public Wire
    {
    public:
        TlsWire( int fd, SSL_CTX* ctx ) : ssl_( SSL_new( ctx ) ), fd_( fd )
        {
            if( ssl_ ) SSL_set_fd( ssl_, fd );
        }
        bool ok() const { return ssl_ != nullptr; }
        bool accept() { return SSL_accept( ssl_ ) == 1; }
        int sendAll( const char* data, std::size_t len ) override
        {
            std::size_t off = 0;
            while( off < len )
            {
                const int n = SSL_write( ssl_, data + off, static_cast<int>( len - off ) );
                if( n <= 0 ) return -1;
                off += static_cast<std::size_t>( n );
            }
            return 0;
        }
        int recvSome( char* buf, std::size_t max ) override
        {
            return SSL_read( ssl_, buf, static_cast<int>( max ) );
        }
        void closeWire() override { if( ssl_ ) { SSL_shutdown( ssl_ ); SSL_free( ssl_ ); ssl_ = nullptr; } }
        void setTimeoutMs( int ms ) override { setSocketTimeoutMs( fd_, ms ); }
    private:
        SSL* ssl_ = nullptr;
        int fd_ = -1;
    };

    struct HttpRequest
    {
        std::string method, target, bearer, sessionId;
        std::string body;
        bool keepAlive = true;
        // The framing of the body, taken from the headers. The body
        // itself is read separately, after the request is authenticated.
        std::size_t contentLength = 0;
        bool chunked = false;
        bool malformed = false;    // framing the server refuses; answered with 400
        // Every header, with a lower-cased name. The header names that
        // arrived more than once are remembered too: a header sent twice is
        // ambiguous framing, not "the last one wins".
        std::map<std::string, std::string> headers;
        std::set<std::string> repeated;
        // The request target without its query string: the path the server
        // routes on.
        std::string path;
    };

    static std::string lowerCopy( std::string s )
    {
        std::transform( s.begin(), s.end(), s.begin(),
                        []( unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        return s;
    }

    static std::string trimCopy( const std::string& s )
    {
        const std::size_t b = s.find_first_not_of( " \t\r\n" );
        if( b == std::string::npos ) return "";
        const std::size_t e = s.find_last_not_of( " \t\r\n" );
        return s.substr( b, e - b + 1 );
    }

    // Resolves the configured bind address into addr. Accepts a literal
    // IPv4 dotted quad, the two loopback spellings, and the empty string
    // (which means "the loopback interface" -- the documented default).
    // Anything else is refused rather than silently widened to INADDR_ANY:
    // a bind address an operator mistyped must fail loudly at startup, not
    // quietly listen on every interface.
    static bool resolveBindAddr( const std::string& host, sockaddr_in& addr )
    {
        std::string h = host;
        // Trim surrounding whitespace: a value arriving from a config file
        // or a shell variable routinely carries a stray newline.
        while( !h.empty() && ( h.front() == ' ' || h.front() == '\t' || h.front() == '\r' || h.front() == '\n' ) )
            h.erase( h.begin() );
        while( !h.empty() && ( h.back() == ' ' || h.back() == '\t' || h.back() == '\r' || h.back() == '\n' ) )
            h.pop_back();
        if( h.empty() || h == "localhost" || h == "127.0.0.1" )
        {
            addr.sin_addr.s_addr = htonl( INADDR_LOOPBACK );
            return true;
        }
        if( h == "*" || h == "0.0.0.0" )
        {
            addr.sin_addr.s_addr = htonl( INADDR_ANY );
            return true;
        }
        in_addr parsed{};
        if( inet_pton( AF_INET, h.c_str(), &parsed ) == 1 )
        {
            addr.sin_addr = parsed;
            return true;
        }
        return false;
    }


    static void sendStatus( Wire& w, int code, const char* text )
    {
        std::ostringstream h;
        h << "HTTP/1.1 " << code << ' ' << text << "\r\nContent-Length: 0\r\n"
          << "Content-Type: application/json\r\nConnection: close\r\n\r\n";
        w.sendAll( h.str().data(), h.str().size() );
    }

    // The reason phrase for a status code, so a reply built from a computed
    // status does not have to carry its own text around.
    static const char* httpStatusText( int code )
    {
        switch( code )
        {
            case 200: return "OK";
            case 202: return "Accepted";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 411: return "Length Required";
            case 413: return "Payload Too Large";
            case 503: return "Service Unavailable";
            default:  return "OK";
        }
    }

    // A status reply that carries a JSON body saying what went wrong. The
    // refusals below use it so a client can tell WHY it was refused and not
    // only that it was.
    static void sendJsonError( Wire& w, int code, const char* text, const std::string& message )
    {
        const std::string body = Json{ { "error", message } }.dump();
        std::ostringstream h;
        h << "HTTP/1.1 " << code << ' ' << text << "\r\nContent-Length: " << body.size()
          << "\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" << body;
        w.sendAll( h.str().data(), h.str().size() );
    }

    // A status reply whose body is already JSON, plus any extra headers the
    // reply needs (the RFC 6750 challenge on a 401, for instance).
    static void sendJsonBody( Wire& w, int code, const char* text, const std::string& body,
                              const std::map<std::string, std::string>& extra = {} )
    {
        std::ostringstream h;
        h << "HTTP/1.1 " << code << ' ' << text << "\r\nContent-Length: " << body.size()
          << "\r\nContent-Type: application/json\r\nConnection: close\r\n";
        for( const auto& kv : extra ) h << kv.first << ": " << kv.second << "\r\n";
        h << "\r\n" << body;
        w.sendAll( h.str().data(), h.str().size() );
    }

    // The RFC 6750 challenge a 401 carries. No scope and no
    // resource_metadata: this server authenticates one bearer token (or a
    // per-client credential from the policy file) and does not implement
    // the OAuth 2.1 resource-server flow.
    static const char* const kAuthRealm = "Bearer realm=\"fractalsql-mcp\"";

    // A JSON-RPC error body for a refusal that happened before the request
    // reached the dispatch core. There is no id to correlate it with, so
    // the body carries none.
    static std::string rpcErrorBody( int code, const std::string& message, const Json& data = Json() )
    {
        Json err{ { "code", code }, { "message", message } };
        if( !data.is_null() ) err[ "data" ] = data;
        return Json{ { "jsonrpc", "2.0" }, { "error", err } }.dump();
    }

    // Reads one HTTP request HEAD (the request line and the headers);
    // returns false on EOF/empty. The body is read separately, AFTER
    // the request has been authenticated -- see readRequestBody.
    //
    // Splitting the two is deliberate. The body is up to 32 MiB, and a
    // client that has not authenticated yet should not be able to make
    // the server hold that much memory per connection: the head is
    // bounded by the per-line caps below, so an unauthenticated
    // connection can only ever cost the server a few tens of KiB.
    static bool readRequestHead( Wire& w, HttpRequest& out )
    {
        // The whole head, not just each line, is bounded: an unauthenticated
        // client must not be able to keep a thread reading headers forever.
        constexpr std::size_t kHeadMax = 64 * 1024;
        constexpr int kMaxHeaders = 100;
        std::size_t headBytes = 0;
        std::string buf;
        auto readLine = [&]( std::string& line, std::size_t cap ) -> bool
        {
            std::size_t nl;
            while( ( nl = buf.find( '\n' ) ) == std::string::npos )
            {
                if( buf.size() > cap || ++headBytes > kHeadMax ) return false;
                char tmp[ 1 ];
                const int n = w.recvSome( tmp, sizeof( tmp ) );
                if( n <= 0 ) return false;
                buf.append( tmp, static_cast<std::size_t>( n ) );
            }
            line = buf.substr( 0, nl );
            if( !line.empty() && line.back() == '\r' ) line.pop_back();
            buf.erase( 0, nl + 1 );
            return true;
        };

        std::string head;
        if( !readLine( head, 16 * 1024 ) ) return false;
        {
            std::istringstream sl( head );
            sl >> out.method >> out.target;
        }
        auto trim = []( std::string s )
        {
            const auto isWs = []( char c ) { return c == ' ' || c == '\t'; };
            while( !s.empty() && isWs( s.front() ) ) s.erase( s.begin() );
            while( !s.empty() && isWs( s.back() ) ) s.pop_back();
            return s;
        };
        std::string h;
        int headerCount = 0;
        bool sawLength = false, sawEncoding = false;
        while( readLine( h, 64 * 1024 ) && !h.empty() )
        {
            if( ++headerCount > kMaxHeaders ) return false;
            const std::size_t colon = h.find( ':' );
            if( colon == std::string::npos ) continue;
            std::string name = trim( h.substr( 0, colon ) );
            const std::string value = trim( h.substr( colon + 1 ) );
            for( char& c : name ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
            // A header sent more than once is ambiguous framing, not "the
            // last one wins": the names are remembered so the request can be
            // refused rather than served with one of the two values.
            if( out.headers.count( name ) ) out.repeated.insert( name );
            out.headers[ name ] = value;

            if( name == "authorization" )
            {
                // The credential scheme is case-insensitive (RFC 7235).
                const std::string lower = lowerCopy( value );
                if( lower.rfind( "bearer ", 0 ) == 0 )
                    out.bearer = trimCopy( value.substr( 7 ) );
            }
            else if( name == "mcp-session-id" ) out.sessionId = value;
            else if( name == "content-length" )
            {
                // Exactly one Content-Length, digits only: anything else is a
                // framing error, not a different length.
                const bool digits = !value.empty() && value.size() <= 12 &&
                    std::all_of( value.begin(), value.end(), []( char c ) { return c >= '0' && c <= '9'; } );
                if( sawLength || !digits ) { out.malformed = true; return false; }
                sawLength = true;
                out.contentLength = static_cast<std::size_t>( std::strtoull( value.c_str(), nullptr, 10 ) );
            }
            else if( name == "transfer-encoding" )
            {
                // Only a plain "chunked" is understood; any other coding would
                // be framed differently here than by a proxy in front.
                if( sawEncoding || lowerCopy( value ) != "chunked" ) { out.malformed = true; return false; }
                sawEncoding = true;
                out.chunked = true;
            }
            else if( name == "connection" )
            {
                if( lowerCopy( value ) == "close" ) out.keepAlive = false;
            }
        }
        if( sawLength && sawEncoding ) { out.malformed = true; return false; }
        // The path the server routes on: the request target without its
        // query string.
        {
            const std::size_t q = out.target.find( '?' );
            out.path = ( q == std::string::npos ) ? out.target : out.target.substr( 0, q );
        }
        return !out.method.empty();
    }

    // Reads the request BODY into `out`. Returns false on EOF; throws
    // when the body exceeds the 32 MiB cap.
    //
    // Only the Content-Length framing is read here: a chunked body is
    // refused with 411 before the body is read at all, so there is no
    // chunk-size arithmetic here to get wrong.
    static bool readRequestBody( Wire& w, HttpRequest& out )
    {
        if( out.contentLength > 0 )
        {
            if( out.contentLength > kBodyMax )
                throw ToolError( ErrorClass::Connectivity, "request body exceeds the 32 MiB cap" );
            out.body.resize( out.contentLength );
            std::size_t got = 0;
            while( got < out.contentLength )
            {
                const int n = w.recvSome( &out.body[ got ], out.contentLength - got );
                if( n <= 0 ) return false;
                got += static_cast<std::size_t>( n );
            }
        }
        return true;
    }

    // Reads and throws away the bytes of a request body that the server
    // has decided not to look at.
    //
    // A request that is refused before its body is read (a wrong token, a
    // disallowed origin, a chunked body) leaves those bytes in the
    // socket's receive queue. Closing a socket that still has unread data
    // queued resets the connection, and the peer can lose the reply it
    // was just given. So the pending bytes are read and discarded first:
    // the reply is what matters, the body is not.
    //
    // The drain is bounded and does not wait: a body that does not arrive
    // is not waited for, and only a limited amount is read.
    static void drainPendingBody( Wire& w, std::size_t want )
    {
        if( want > kDrainMax ) want = kDrainMax;
        if( want == 0 ) return;
        // A short timeout: the body may never arrive, and the connection
        // is finished either way.
        w.setTimeoutMs( 250 );
        char sink[ 4096 ];
        while( want > 0 )
        {
            const std::size_t chunk = ( want < sizeof( sink ) ) ? want : sizeof( sink );
            const int n = w.recvSome( sink, chunk );
            if( n <= 0 ) return;
            want -= static_cast<std::size_t>( n );
        }
    }

    // How many body bytes a refused request may still have queued.
    //
    // A chunked body has no length the server can count, so everything that
    // could be queued is drained.
    static std::size_t pendingBodyBytes( const HttpRequest& req )
    {
        return req.chunked ? kDrainMax : req.contentLength;
    }

    // ---- request handling, split by concern ----
    //
    // Each helper below handles one decision and returns whether the
    // connection may continue. Keeping them separate (rather than one
    // long function with inline `break`s) is what makes the
    // one-request-per-connection rule below obvious: there is exactly
    // one place that decides "reply and stop".

    // The two unauthenticated liveness endpoints. They touch no session
    // state and no DB, so they are answered before the auth check.
    //
    // The return value means "this request is FINISHED -- do not send
    // anything else on this connection". A wrong path is finished: the
    // 404 IS the answer. Returning false there (as an earlier version
    // of this helper did) let the caller fall through to the auth check
    // and then to the dispatch, so an authenticated POST to a path the
    // server does not serve got a 404 AND a 200 with the tool's result
    // -- two HTTP responses on one connection, and the tool really ran.
    // A client that reads one response per connection was then left
    // with the stale 200 in its socket buffer, and the NEXT request on
    // a pooled socket parsed that stale response as its own.
    static bool handleUnauthenticatedGet( Wire& wire, const HttpRequest& req,
                                          const std::string& path,
                                          const std::function<bool()>& readinessProbe )
    {
        if( req.path == "/healthz" ) { sendStatus( wire, 200, "OK" ); return true; }
        if( req.path == "/readyz" )
        {
            const bool ready = readinessProbe();
            sendStatus( wire, ready ? 200 : 503, ready ? "OK" : "Service Unavailable" );
            return true;
        }
        if( req.path != path ) { sendStatus( wire, 404, "Not Found" ); return true; }
        return false;   // the MCP path itself: the caller continues
    }

    // Failed-auth backoff: each failure stalls its own connection thread for a growing
    // interval (capped at 2 s), which throttles online token guessing without a lockout
    // an attacker could turn against legitimate clients. A success pays one failure back.
    static std::atomic<int>& authFailureCounter() { static std::atomic<int> n{ 0 }; return n; }
    static void authFailed()
    {
        const int fails = std::min( authFailureCounter().fetch_add( 1 ) + 1, 20 );
        std::this_thread::sleep_for( std::chrono::milliseconds( fails * 100 ) );
    }
    static void authOk()
    {
        int f = authFailureCounter().load();
        while( f > 0 && !authFailureCounter().compare_exchange_weak( f, f - 1 ) ) {}
    }

    // Extracts the bearer credential from the Authorization header and
    // checks it against the token store (the timing-safe compare lives in
    // TokenStore::check). The presented value is returned via presentedOut
    // but is NEVER logged by any caller.
    //
    // The header is the ONLY place a credential is read from: a token in
    // the URL's query string is not a credential, and the spec forbids
    // putting one there (it ends up in proxy logs and browser history).
    static TokenStore::Credential authenticate( const HttpRequest& req, TokenStore& tokens,
                                                std::string& presentedOut )
    {
        presentedOut.clear();
        auto authIt = req.headers.find( "authorization" );
        const std::string authHeader = authIt == req.headers.end() ? std::string() : authIt->second;
        // The credential scheme is case-insensitive (RFC 7235).
        if( lowerCopy( authHeader ).rfind( "bearer ", 0 ) == 0 )
            presentedOut = trimCopy( authHeader.substr( 7 ) );
        if( presentedOut.empty() ) return TokenStore::Credential{};
        return tokens.check( presentedOut );
    }

    // True when the origin names a loopback host. The host part is what
    // matters: a page served from http://127.0.0.1:3000 is a loopback
    // origin whatever its port.
    static bool originIsLoopback( const std::string& origin )
    {
        const std::size_t sep = origin.find( "://" );
        if( sep == std::string::npos ) return false;
        std::string host = origin.substr( sep + 3 );
        const std::size_t slash = host.find( '/' );
        if( slash != std::string::npos ) host = host.substr( 0, slash );
        if( !host.empty() && host.front() == '[' )
        {
            const std::size_t close = host.find( ']' );
            if( close == std::string::npos ) return false;
            const std::string inner = host.substr( 1, close - 1 );
            return inner == "::1";
        }
        const std::size_t colon = host.rfind( ':' );
        if( colon != std::string::npos ) host = host.substr( 0, colon );
        if( host == "localhost" ) return true;
        if( host.rfind( "127.", 0 ) == 0 ) return true;
        return false;
    }

    // An Origin header, when present, must be one this deployment allows:
    // a loopback origin by default, plus whatever FSQL_MCP_ALLOWED_ORIGINS
    // lists (browser tools such as the MCP Inspector need their origin
    // there). A request with no Origin header is not a browser request and
    // is allowed through.
    static bool originAllowed( const std::string& origin, const HttpConfig& cfg )
    {
        if( origin.empty() ) return true;
        if( originIsLoopback( origin ) ) return true;
        const std::string o = lowerCopy( trimCopy( origin ) );
        for( const std::string& allowed : cfg.allowedOrigins )
            if( lowerCopy( trimCopy( allowed ) ) == o ) return true;
        return false;
    }

    // base64url decode, for the Mcp-Name header's "=?base64?...?=" form.
    static std::string base64Decode( const std::string& in )
    {
        if( in.empty() ) return std::string();
        // The decoder counts the padding characters as decoded bytes, so the
        // value's length is the decoded length less the padding.
        std::size_t pad = 0;
        while( pad < in.size() && in[ in.size() - 1 - pad ] == '=' ) ++pad;
        std::string out( ( in.size() / 4 + 1 ) * 3 + 3, '\0' );
        const int n = EVP_DecodeBlock( reinterpret_cast<unsigned char*>( &out[ 0 ] ),
                                       reinterpret_cast<const unsigned char*>( in.data() ),
                                       static_cast<int>( in.size() ) );
        if( n < 0 ) return std::string();
        std::size_t len = static_cast<std::size_t>( n );
        if( len >= pad ) len -= pad;   // the padding is not part of the value
        out.resize( len );
        return out;
    }

    // The Mcp-Name header may carry the name in the base64 form the spec
    // allows. Decoded, it is the same string; a value that is not in that
    // form is taken literally.
    static std::string decodeMcpName( const std::string& raw )
    {
        static const std::string kPrefix = "=?base64?";
        const std::string v = trimCopy( raw );
        if( v.rfind( kPrefix, 0 ) != 0 ) return v;
        const std::size_t end = v.rfind( "?=" );
        if( end == std::string::npos || end < kPrefix.size() ) return std::string();
        std::string b64 = v.substr( kPrefix.size(), end - kPrefix.size() );
        for( char& c : b64 ) { if( c == '-' ) c = '+'; else if( c == '_' ) c = '/'; }
        while( b64.size() % 4 != 0 ) b64.push_back( '=' );
        return base64Decode( b64 );
    }

    // The modern era's per-request protocol version, carried in the body's
    // _meta. The spec names it
    // _meta.io.modelcontextprotocol/protocolVersion; the nested spelling is
    // accepted too, because a client that builds _meta as a tree rather
    // than as a namespaced key produces that.
    static std::string modernMetaVersion( const Json& body )
    {
        if( !body.is_object() ) return std::string();
        auto meta = body.find( "_meta" );
        if( meta == body.end() || !meta->is_object() ) return std::string();
        auto it = meta->find( "io.modelcontextprotocol/protocolVersion" );
        if( it != meta->end() && it->is_string() ) return it->get<std::string>();
        auto ns = meta->find( "io.modelcontextprotocol" );
        if( ns != meta->end() && ns->is_object() )
        {
            auto v = ns->find( "protocolVersion" );
            if( v != ns->end() && v->is_string() ) return v->get<std::string>();
        }
        return std::string();
    }

    // A string field of the request's params, or "" when it is absent or
    // not a string. Never throws on a wrongly typed params object.
    static std::string paramsString( const Json& body, const std::string& key )
    {
        auto p = body.find( "params" );
        if( p == body.end() || !p->is_object() ) return std::string();
        auto v = p->find( key );
        if( v == p->end() || !v->is_string() ) return std::string();
        return v->get<std::string>();
    }

    // The revisions the modern protocol era covers. A modern request must
    // name one of them.
    static const std::vector<std::string>& modernProtocolVersions()
    {
        static const std::vector<std::string> v{ "2025-11-25", "2026-07-28" };
        return v;
    }

    // The JSON-RPC methods this server answers. A modern request naming
    // anything else is answered with 404 and -32601; a legacy request keeps
    // the legacy behaviour (the dispatch core answers -32601).
    static bool isKnownRpcMethod( const std::string& m )
    {
        static const char* const kMethods[] = {
            "initialize", "ping", "tools/list", "tools/call",
            "resources/list", "resources/read", "resources/templates/list",
            "prompts/list", "prompts/get", "server/discover", "logging/setLevel",
            "notifications/initialized", "notifications/cancelled", "$/cancel"
        };
        for( const char* k : kMethods ) if( m == k ) return true;
        return false;
    }

    // The outcome of validating a modern-era request's headers against its
    // body.
    struct ModernCheck
    {
        bool ok = true;
        int httpStatus = 200;
        int code = 0;                 // the JSON-RPC error code, 0 = no error
        std::string message;
        Json data = Json();           // the error's data, when it carries any
    };

    // A modern protocol era request must carry MCP-Protocol-Version,
    // Mcp-Method and, where the method addresses something by name,
    // Mcp-Name; and the headers must agree with the body. A disagreement
    // is -32020 (HeaderMismatch), an unsupported revision is -32022
    // (UnsupportedProtocolVersionError).
    static ModernCheck validateModernRequest( const HttpRequest& req, const Json& body,
                                               const std::string& bodyMethod )
    {
        ModernCheck out;

        auto pv = req.headers.find( "mcp-protocol-version" );
        if( pv == req.headers.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing MCP-Protocol-Version header: a modern protocol era request "
                          "must name the revision it speaks";
            return out;
        }
        const std::string headerVersion = trimCopy( pv->second );
        const auto& versions = modernProtocolVersions();
        if( std::find( versions.begin(), versions.end(), headerVersion ) == versions.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32022;
            out.message = "unsupported protocol version: " + headerVersion;
            Json supported = Json::array();
            for( const std::string& v : versions ) supported.push_back( v );
            out.data = Json{ { "supported", supported }, { "requested", headerVersion } };
            return out;
        }

        const std::string bodyVersion = modernMetaVersion( body );
        if( bodyVersion.empty() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing _meta.io.modelcontextprotocol/protocolVersion: a modern protocol "
                          "era request carries its revision in the body as well as in the header";
            return out;
        }
        if( bodyVersion != headerVersion )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the protocol version: header says "
                          + headerVersion + ", body says " + bodyVersion;
            return out;
        }

        auto mm = req.headers.find( "mcp-method" );
        if( mm == req.headers.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing Mcp-Method header: a modern protocol era request must name its method";
            return out;
        }
        if( trimCopy( mm->second ) != bodyMethod )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the method: header says '"
                          + trimCopy( mm->second ) + "', body says '" + bodyMethod + "'";
            return out;
        }

        // Mcp-Name, for the methods that address something by name.
        std::string expectedName;
        bool nameRequired = false;
        if( bodyMethod == "tools/call" || bodyMethod == "prompts/get" )
        {
            expectedName = paramsString( body, "name" );
            nameRequired = true;
        }
        else if( bodyMethod == "resources/read" )
        {
            expectedName = paramsString( body, "uri" );
            nameRequired = true;
        }
        if( nameRequired )
        {
            auto mn = req.headers.find( "mcp-name" );
            if( mn == req.headers.end() )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "missing Mcp-Name header: " + bodyMethod + " must name what it addresses";
                return out;
            }
            const std::string headerName = decodeMcpName( mn->second );
            if( headerName != expectedName )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "header and body disagree about the name: header says '" + headerName
                              + "', body says '" + expectedName + "'";
                return out;
            }
        }
        return out;
    }

    // DELETE closes the named session's dedicated DB connection.
    static void handleDelete( Wire& wire, const HttpRequest& req, ClientRegistry& reg,
                              const std::string& ownerFp )
    {
        if( req.sessionId.empty() ) { sendStatus( wire, 400, "Bad Request" ); return; }
        if( reg.eraseSession( req.sessionId, ownerFp ) ) sendStatus( wire, 200, "OK" );
        else sendStatus( wire, 404, "Not Found" );
    }

    // The legacy era's initialize: it mints the protocol session (and with
    // it the session's own dedicated engine connection) and answers with the
    // session id in the Mcp-Session-Id header.
    static void handleInitialize( Wire& wire, const HttpRequest& req, ClientRegistry& reg,
                                  const TokenStore::Credential& cred, const std::string& ownerFp )
    {
        if( !req.sessionId.empty() )
        {
            sendJsonError( wire, 400, "Bad Request", "initialize must not carry a session id" );
            return;
        }
        std::string sessionId;
        std::shared_ptr<JsonRpcServer> srv;
        try { srv = reg.createSession( ownerFp, sessionId ); }
        catch( const ToolError& ) { sendStatus( wire, 503, "Service Unavailable" ); return; }

        const std::string clientKey = clientKeyFor( req.bearer, sessionId );
        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;
        auto respOpt = srv->handleLine( req.body, clientKey, opts );

        std::map<std::string, std::string> extra;
        extra[ "Mcp-Session-Id" ] = sessionId;
        if( respOpt )
            sendJsonBody( wire, 200, "OK", *respOpt, extra );
        else
            sendJsonBody( wire, 202, "Accepted", "", extra );
    }

    // The legacy era's ordinary call on an already-initialized session. The
    // protocol session supplies the context, so an explicit context_id is
    // accepted only when it names that very context.
    static void handleLegacyDispatch( Wire& wire, const HttpRequest& req, const Json& body,
                                      ClientRegistry& reg, const TokenStore::Credential& cred,
                                      const std::string& ownerFp )
    {
        if( req.sessionId.empty() )
        {
            // Session resolution: a call without a session header is 400; an
            // unknown session (or one that belongs to another credential) is
            // 404, so existence is not revealed.
            sendStatus( wire, 400, "Bad Request" );
            return;
        }
        std::shared_ptr<JsonRpcServer> srv = reg.findSession( req.sessionId, ownerFp );
        if( !srv ) { sendStatus( wire, 404, "Not Found" ); return; }

        // The legacy era's context handle IS the session handle: a call that
        // names a different context is refused rather than silently served on
        // the session's own state.
        std::string namedContext;
        {
            auto p = body.find( "params" );
            if( p != body.end() && p->is_object() )
            {
                auto a = p->find( "arguments" );
                if( a != p->end() && a->is_object() )
                {
                    auto c = a->find( "context_id" );
                    if( c != a->end() && c->is_string() ) namedContext = c->get<std::string>();
                }
            }
        }
        if( !namedContext.empty() && namedContext != req.sessionId )
        {
            sendJsonBody( wire, 400, "Bad Request",
                rpcErrorBody( -32602,
                    "the context_id does not match this session's own context: in the legacy protocol "
                    "era the Mcp-Session-Id header supplies the context, and an explicit context_id "
                    "may only repeat it" ) );
            return;
        }

        const std::string clientKey = clientKeyFor( req.bearer, req.sessionId );
        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;
        auto respOpt = srv->handleLine( req.body, clientKey, opts );
        if( respOpt )
            sendJsonBody( wire, 200, "OK", *respOpt );
        else
            // A notification is acknowledged with 202 and nothing of
            // substance: there is no result to deliver.
            sendJsonBody( wire, 202, "Accepted", "" );
    }

    // A modern era request: stateless, no protocol session. The engine
    // context comes from the request's own context_id argument when the call
    // addresses a stateful tool; otherwise the call runs on the
    // credential's own connection.
    static void handleModernDispatch( Wire& wire, const HttpRequest& req, const Json& body,
                                      const std::string& bodyMethod, bool isRequest,
                                      ClientRegistry& reg, const TokenStore::Credential& cred,
                                      const std::string& ownerFp )
    {
        const ModernCheck check = validateModernRequest( req, body, bodyMethod );
        if( !check.ok )
        {
            sendJsonBody( wire, check.httpStatus, httpStatusText( check.httpStatus ),
                          rpcErrorBody( check.code, check.message, check.data ) );
            return;
        }
        if( !isKnownRpcMethod( bodyMethod ) )
        {
            sendJsonBody( wire, 404, "Not Found",
                          rpcErrorBody( -32601, "method not found: " + bodyMethod ) );
            return;
        }

        // The engine context: the request's own handle when it names one and
        // the tool keeps engine state, otherwise a fresh handle, and the
        // credential's own connection for a tool that keeps no state.
        const std::string toolName = ( bodyMethod == "tools/call" ) ? paramsString( body, "name" ) : std::string();
        const bool stateful = !toolName.empty() && isContextScopedTool( toolName );
        std::string requestedContext;
        if( stateful )
        {
            auto p = body.find( "params" );
            if( p != body.end() && p->is_object() )
            {
                auto a = p->find( "arguments" );
                if( a != p->end() && a->is_object() )
                {
                    auto c = a->find( "context_id" );
                    if( c != a->end() && c->is_string() ) requestedContext = c->get<std::string>();
                }
            }
        }

        std::shared_ptr<JsonRpcServer> srv;
        std::string contextId;
        try
        {
            if( stateful )
            {
                if( !requestedContext.empty() )
                {
                    srv = reg.findContext( requestedContext, ownerFp, contextId );
                    if( !srv )
                    {
                        sendJsonError( wire, 404, "Not Found",
                            "unknown context handle: it does not exist, or it belongs to another credential" );
                        return;
                    }
                }
                else
                {
                    srv = reg.createContext( ownerFp, contextId );
                }
            }
            else
                srv = reg.credentialContext( ownerFp + "|" + cred.clientName, ownerFp );
        }
        catch( const ToolError& )
        {
            sendStatus( wire, 503, "Service Unavailable" );
            return;
        }

        CallOptions opts;
        opts.era = ProtocolEra::Modern;
        opts.contextId = stateful ? contextId : std::string();
        opts.toolAllow = cred.allow;
        auto respOpt = srv->handleLine( req.body, cred.clientName, opts );
        if( respOpt )
            sendJsonBody( wire, 200, "OK", *respOpt );
        else
            // A notification: 202 and nothing of substance. A cancelled
            // request has no result either, but it was a request, so it
            // answers 200.
            sendJsonBody( wire, isRequest ? 200 : 202, isRequest ? "OK" : "Accepted", "" );
    }

    static void serveConnection( const WirePtr& wire, ClientRegistry& reg,
                                  TokenStore& tokens, const HttpConfig& cfg,
                                  std::function<bool()> readinessProbe )
    {
        // One request per connection. The MCP HTTP transport is a
        // request/response protocol: the client opens a connection,
        // sends one request, and reads one reply. Keeping a keep-alive
        // loop here bought nothing and cost a class of bugs -- a
        // half-sent request left in the socket when the session was
        // torn down, and a reply written to a connection the client had
        // already abandoned. One request, one reply, one close.
        HttpRequest req;
        if( !readRequestHead( *wire, req ) )
        {
            if( req.malformed )
            {
                // The framing of the request is ambiguous, so the length of
                // the body that may still be queued is not known: whatever
                // is queued is drained before the reply is sent, so the peer
                // gets the refusal instead of a reset.
                sendStatus( *wire, 400, "Bad Request" );
                drainPendingBody( *wire, kDrainMax );
                return;
            }
            return;
        }
        wire->setTimeoutMs( 65000 );    // the head arrived; allow a slower body

        if( g_httpSignalled.load() ) return;
        if( handleUnauthenticatedGet( *wire, req, cfg.path, readinessProbe ) ) return;

        // Origin: a browser-driven client sends one, and it has to be an
        // origin this deployment allows. A request with no Origin header is
        // not a browser request and is let through.
        {
            auto oIt = req.headers.find( "origin" );
            const std::string origin = oIt == req.headers.end() ? std::string() : trimCopy( oIt->second );
            if( !originAllowed( origin, cfg ) )
            {
                sendJsonBody( *wire, 403, "Forbidden",
                    rpcErrorBody( -32000,
                        "origin not allowed: " + origin + " is not a loopback origin and is not "
                        "listed in FSQL_MCP_ALLOWED_ORIGINS" ) );
                drainPendingBody( *wire, pendingBodyBytes( req ) );
                return;
            }
        }

        // The credential comes from the Authorization header only.
        std::string presented;
        const TokenStore::Credential cred = authenticate( req, tokens, presented );
        if( !cred.ok )
        {
            // 401 BEFORE the request reaches the adapter layer. The
            // presented value is never logged. The challenge names the
            // realm; a token that WAS presented but is wrong or expired
            // also says why.
            authFailed();
            std::map<std::string, std::string> extra;
            extra[ "WWW-Authenticate" ] = std::string( kAuthRealm ) +
                ( presented.empty() ? "" : ", error=\"invalid_token\"" );
            sendJsonBody( *wire, 401, "Unauthorized",
                Json{ { "error", presented.empty() ? "missing bearer token" : "invalid bearer token" } }.dump(),
                extra );
            drainPendingBody( *wire, pendingBodyBytes( req ) );
            return;
        }
        authOk();
        const std::string ownerFp = tokenFingerprint( presented );

        // A chunked body has no length the server can check the cap
        // against, and this transport does not frame one: the client has
        // to send Content-Length.
        if( req.chunked )
        {
            sendJsonError( *wire, 411, "Length Required",
                           "a chunked request body is not accepted; send Content-Length" );
            drainPendingBody( *wire, pendingBodyBytes( req ) );
            return;
        }

        // The body is read only once the request is known to be
        // authenticated: an unauthenticated client must not be able to
        // make the server buffer a body for it.
        if( req.method == "POST" || req.contentLength > 0 )
        {
            try
            {
                if( !readRequestBody( *wire, req ) ) return;
            }
            catch( const ToolError& )
            {
                sendStatus( *wire, 413, "Payload Too Large" );
                return;
            }
        }

        // A modern era request carries the modern protocol version header
        // (and the matching _meta in its body). The legacy era has neither.
        const bool modernByHeader = req.headers.count( "mcp-protocol-version" ) > 0;

        if( req.method == "GET" || req.method == "DELETE" )
        {
            // The modern era has no GET stream and no session teardown, so
            // both are refused for a modern request.
            if( modernByHeader || modernEraOnly() )
            {
                sendJsonError( *wire, 405, "Method Not Allowed",
                    req.method == "GET"
                        ? "GET is not used by the modern protocol era; POST JSON-RPC 2.0 messages"
                        : "DELETE is not used by the modern protocol era; it has no protocol session to tear down" );
                return;
            }
            if( req.method == "GET" ) { sendStatus( *wire, 405, "Method Not Allowed" ); return; }
            handleDelete( *wire, req, reg, ownerFp );
            return;
        }
        if( req.method != "POST" ) { sendStatus( *wire, 405, "Method Not Allowed" ); return; }

        if( jsonNestsTooDeep( req.body ) ) { sendStatus( *wire, 400, "Bad Request" ); return; }
        Json body;
        bool parsedOk = true;
        try { body = Json::parse( req.body ); }
        catch( ... ) { parsedOk = false; }
        if( !parsedOk || !body.is_object() || req.body.empty() )
        {
            // A body that is not a JSON-RPC message is a parse error, and
            // the JSON-RPC error object says so.
            sendJsonBody( *wire, 400, "Bad Request",
                rpcErrorBody( -32700,
                    "parse error: the request body is not a JSON-RPC 2.0 message" ) );
            return;
        }
        const std::string method = ( body.contains( "method" ) && body[ "method" ].is_string() )
            ? body[ "method" ].get<std::string>() : std::string();
        const bool isRequest = body.contains( "id" );
        const bool isInitialize = ( method == "initialize" );

        // The era of this request. "initialize" is the legacy handshake and
        // always selects the legacy flow; anything else is modern when it
        // carries the modern metadata or the modern version header.
        const bool isModern = !isInitialize &&
            ( modernByHeader || !modernMetaVersion( body ).empty() );

        if( modernEraOnly() && !isModern )
        {
            // A modern-only server refuses the legacy era outright, and says
            // which revisions it speaks.
            sendJsonBody( *wire, 400, "Bad Request",
                rpcErrorBody( -32000,
                    "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                    "the legacy initialize handshake and the legacy session headers are refused. "
                    "Supported versions: 2025-11-25, 2026-07-28" ) );
            return;
        }

        if( isModern )
        {
            handleModernDispatch( *wire, req, body, method, isRequest, reg, cred, ownerFp );
            return;
        }

        // Legacy era: initialize mints the session, every other call
        // presents one.
        if( isInitialize )
        {
            handleInitialize( *wire, req, reg, cred, ownerFp );
            return;
        }
        handleLegacyDispatch( *wire, req, body, reg, cred, ownerFp );
    }

    // The last OpenSSL error as a readable string. Every TLS startup
    // failure below reports through it: a bare "cert/key failed to load"
    // tells an operator nothing about WHICH file failed or why.
    static std::string opensslLastError()
    {
        const unsigned long code = ERR_get_error();
        if( code == 0 ) return "unknown OpenSSL error";
        char buf[ 256 ];
        ERR_error_string_n( code, buf, sizeof( buf ) );
        return std::string( buf );
    }

    // Builds the server-side SSL_CTX for the direct-TLS mode. A failure
    // here is a HARD startup failure -- this NEVER falls back to plaintext
    // silently, and it never leaves the process half-listening. The
    // resulting SSL_CTX is read-only for the rest of the process's life,
    // which is why sharing one across every connection thread's SSL_new()
    // needs no extra locking (OpenSSL's own documented thread-safety
    // guarantee for a configured, unmodified SSL_CTX).
    // A routable bind without TLS sends the bearer token and every tool result in clear
    // text. Warn always; refuse unless FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK is set.
    static bool hostIsLoopback( const std::string& h )
    {
        return h.empty() || h == "localhost" || h == "::1" || h.rfind( "127.", 0 ) == 0;
    }

    static SSL_CTX* makeSslCtx( const HttpConfig& cfg, std::string& errOut )
    {
        SSL_CTX* ctx = SSL_CTX_new( TLS_server_method() );
        if( !ctx ) { errOut = "SSL_CTX_new failed: " + opensslLastError(); return nullptr; }
        // A failed floor must be fatal: otherwise the server believes it enforces TLS 1.2+ but negotiates the library default.
        if( SSL_CTX_set_min_proto_version( ctx, TLS1_2_VERSION ) != 1 )
        {
            errOut = "SSL_CTX_set_min_proto_version(TLS1.2) failed: " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        if( SSL_CTX_use_certificate_chain_file( ctx, cfg.tlsCertPath.c_str() ) != 1 )
        {
            errOut = "failed to load TLS cert file '" + cfg.tlsCertPath + "': " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        if( SSL_CTX_use_PrivateKey_file( ctx, cfg.tlsKeyPath.c_str(), SSL_FILETYPE_PEM ) != 1 )
        {
            errOut = "failed to load TLS key file '" + cfg.tlsKeyPath + "': " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        // Both files loaded, but they may simply not belong to each other.
        // Without this check the mismatch surfaces much later, as a
        // handshake failure on every single connection -- an
        // indistinguishable symptom from a broken client.
        if( SSL_CTX_check_private_key( ctx ) != 1 )
        {
            errOut = "TLS certificate and private key do not match: " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        return ctx;
    }

    int runHttpTransport( JsonRpcServer& server, const HttpConfig& cfg, std::function<bool()> readinessProbe )
    {
        (void)server;    // dispatch is per-session; this instance only carries the shared registry
        if( !cfg.sessionFactory )
            throw ToolError( ErrorClass::ServerInternal, "runHttpTransport needs a per-session factory" );

#ifdef SIGHUP
        std::signal( SIGHUP, onSighup );
#endif
        std::signal( SIGTERM, onHttpTermSignal );
        std::signal( SIGINT,  onHttpTermSignal );

#ifdef _WIN32
        WSADATA wsa{};
        if( WSAStartup( MAKEWORD( 2, 2 ), &wsa ) != 0 )
            throw ToolError( ErrorClass::ServerInternal, "WSAStartup failed" );
#endif

        // The registry, the token store and the SSL context are held by
        // SHARED pointer and captured BY VALUE by every connection thread.
        // The shutdown path detaches whatever is still in flight (a client
        // that opened a connection and never sent a request must not be
        // able to wedge the server forever), and a detached thread
        // outliving this function would otherwise touch stack objects
        // that are already gone.
        std::shared_ptr<TokenStore> tokens = std::make_shared<TokenStore>( cfg );
        std::shared_ptr<ClientRegistry> reg = std::make_shared<ClientRegistry>( cfg );
        std::shared_ptr<SSL_CTX> sslCtx;
        if( cfg.tlsEnabled )
        {
            std::string tlsErr;
            SSL_CTX* ctx = makeSslCtx( cfg, tlsErr );
            if( !ctx )
                throw ToolError( ErrorClass::ServerInternal, "TLS enabled but cert/key failed to load: " + tlsErr );
            // The deleter is OpenSSL's, not delete's: an SSL_CTX is not a
            // C++ object and must go through SSL_CTX_free.
            sslCtx.reset( ctx, []( SSL_CTX* c ) { if( c ) SSL_CTX_free( c ); } );
        }

        const int listenFd = static_cast<int>( ::socket( AF_INET, SOCK_STREAM, 0 ) );
        if( listenFd < 0 )
            throw ToolError( ErrorClass::ServerInternal, "socket() failed" );
        int one = 1;
        setsockopt( listenFd, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>( &one ), sizeof( one ) );
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons( static_cast<unsigned short>( cfg.port ) );
        // The bind address comes from FSQL_MCP_BIND / --bind and defaults to
        // the loopback interface. Binding INADDR_ANY here would expose an
        // authenticated-but-otherwise-open JSON-RPC surface on every
        // interface of the host, which is not what "off by default" has to
        // mean for a server that ships with a Bearer token and no TLS.
        if( !resolveBindAddr( cfg.host, addr ) )
            // The message says what is ACCEPTED, not what was attempted:
            // no name resolution happens here, so a message about
            // "resolving" an address the code never tries to resolve
            // sends the operator looking for a DNS problem that is not
            // there.
            throw ToolError( ErrorClass::ServerInternal,
                             "the HTTP bind address '" + cfg.host + "' is not accepted: "
                             "use an IPv4 dotted quad (127.0.0.1), 'localhost', '*' "
                             "for every interface, or an empty value for the loopback" );
        if( ::bind( listenFd, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) != 0 ||
            ::listen( listenFd, 16 ) != 0 )
            throw ToolError( ErrorClass::ServerInternal, "cannot bind the HTTP listener" );
        if( !sslCtx && !hostIsLoopback( cfg.host ) )
        {
            logging::logInfo( "WARNING: the HTTP transport is bound to non-loopback address '" + cfg.host +
                              "' WITHOUT TLS; the bearer token and all results travel in clear text (set FSQL_MCP_HTTP_TLS=true)" );
            const char* allowPlain = std::getenv( "FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK" );
            if( !( allowPlain && *allowPlain && std::string( allowPlain ) != "0" && std::string( allowPlain ) != "false" ) )
                throw ToolError( ErrorClass::ServerInternal, "refusing a non-loopback HTTP bind without TLS (set FSQL_MCP_HTTP_TLS=true, or FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK=true to accept the risk)" );
        }
        logging::logInfo( "http transport listening on " + cfg.host + ":" + std::to_string( cfg.port ) +
                          ( sslCtx ? " (TLS)" : " (plain)" ) );

        // Every connection gets its own thread, and the thread objects are
        // REAPED as they finish. Keeping every thread object for the life
        // of the process (the old behaviour) grew the vector without bound
        // on a long-running server: a std::thread that has been joined
        // still occupies its stack handle, and an unjoined one occupies its
        // whole stack allocation.
        struct Conn
        {
            std::thread t;
            // Shared, not a plain member: a thread that is detached at
            // shutdown may outlive this function, and it still has to be
            // able to set the flag without touching freed memory.
            std::shared_ptr<std::atomic<bool>> done = std::make_shared<std::atomic<bool>>( false );
        };

        // The bookkeeping lives in a SHARED object rather than in locals,
        // because the reaper thread and the connection threads both reach
        // it, and a connection thread that is detached at shutdown can
        // outlive this function. The stop flag is shared for the same
        // reason: the reaper is joined on every path out of here, but a
        // std::thread constructor that throws would leave it running
        // against a stack object that no longer exists.
        struct ConnState
        {
            std::mutex mu;
            std::condition_variable cv;
            std::vector<std::unique_ptr<Conn>> conns;
        };
        auto state = std::make_shared<ConnState>();
        auto reaperStop = std::make_shared<std::atomic<bool>>( false );
        // Refusals still delivering themselves (past the connection limit).
        auto refusalsInFlight = std::make_shared<std::atomic<int>>( 0 );

        // Joins and drops the connections that have already finished.
        // Called with state->mu held.
        auto reapLocked = [ state ]()
        {
            for( auto it = state->conns.begin(); it != state->conns.end(); )
            {
                if( ( *it )->done->load() )
                {
                    if( ( *it )->t.joinable() ) ( *it )->t.join();
                    it = state->conns.erase( it );
                }
                else ++it;
            }
        };
        auto reap = [ state, reapLocked ]()
        {
            std::lock_guard<std::mutex> lk( state->mu );
            reapLocked();
        };

        // A connection that finishes while the server is IDLE has to be
        // reclaimed too, and the accept loop cannot do it: it only wakes
        // for a new connection or the next poll slice. Without
        // this thread, a burst of N requests followed by a quiet period
        // left N finished-but-unjoined threads (each keeping its stack
        // allocated) and N stale entries in the vector until the next
        // request came in. The reaper waits on a condition variable that
        // a finishing connection signals, and also on a timeout so it
        // cannot miss a signal.
        std::thread reaper( [ state, reaperStop, reapLocked ]()
        {
            std::unique_lock<std::mutex> lk( state->mu );
            while( !reaperStop->load() )
            {
                state->cv.wait_for( lk, std::chrono::milliseconds( 250 ) );
                reapLocked();
            }
        } );

        const std::size_t connLimit = maxConnections();
        logging::logInfo( "http max connections: " + std::to_string( connLimit ) );

        while( !g_httpSignalled.load() )
        {
            if( !waitForConnection( listenFd, 250 ) ) continue;
            sockaddr_in peer{}; socklen_t plen = sizeof( peer );
            const int fd = static_cast<int>( ::accept( listenFd, reinterpret_cast<sockaddr*>( &peer ), &plen ) );
            if( fd < 0 )
            {
                // Out of descriptors, an aborted connection: keep serving.
                if( g_httpSignalled.load() ) break;
                std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
                continue;
            }
            bool overLimit = false;
            {
                std::lock_guard<std::mutex> lk( state->mu );
                reapLocked();
                overLimit = state->conns.size() >= connLimit;
            }
            if( overLimit )
            {
                // Over the limit: refuse before spending a thread on it. A
                // TLS client cannot read a plaintext reply; it just sees the close.
                if( !sslCtx )
                {
                    static const char kBusy[] = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n"
                                                "Content-Length: 0\r\nConnection: close\r\n\r\n";
                    ::send( fd, kBusy, static_cast<int>( sizeof( kBusy ) - 1 ), 0 );
                    // The refusal is finished on its own short-lived thread:
                    // draining the peer's request takes a moment, and the
                    // accept loop must keep accepting while it does.
                    if( refusalsInFlight->fetch_add( 1 ) < kMaxRefusalsInFlight )
                    {
                        std::thread( [ fd, refusalsInFlight ] {
                            fsqlCloseAfterReply( fd, kRefusalLingerMs );
                            refusalsInFlight->fetch_sub( 1 );
                        } ).detach();
                    }
                    else
                    {
                        refusalsInFlight->fetch_sub( 1 );
                        fsqlCloseSocket( fd );
                    }
                }
                else
                    fsqlCloseSocket( fd );
                continue;
            }
            // Everything the thread touches is captured BY VALUE (shared
            // pointers for the registry, the token store, the SSL context
            // and the connection bookkeeping; the config by copy), so a
            // thread that is still running when this function returns
            // keeps every object it needs alive.
            const HttpConfig cfgCopy = cfg;
            auto conn = std::unique_ptr<Conn>( new Conn );
            auto done = conn->done;
            conn->t = std::thread( [ fd, reg, tokens, sslCtx, cfgCopy, readinessProbe, done, state ]()
            {
                WirePtr wire;
                setSocketTimeoutMs( fd, 15000 );    // TLS handshake and request head
                if( sslCtx )
                {
                    TlsWire* t = new TlsWire( fd, sslCtx.get() );
                    if( !t->ok() || !t->accept() ) { delete t; done->store( true ); state->cv.notify_one(); return; }
                    wire.reset( t );
                }
                else wire.reset( new PlainWire( fd ) );
                serveConnection( wire, *reg, *tokens, cfgCopy, readinessProbe );
                wire->closeWire();
                done->store( true );
                state->cv.notify_one();
            } );
            {
                std::lock_guard<std::mutex> lk( state->mu );
                state->conns.emplace_back( std::move( conn ) );
            }
            reap();
        }

        server.beginShutdown();
        reg->endAll();
        fsqlCloseSocket( listenFd );
        {
            // Stop the reaper before the drain: it shares the bookkeeping
            // with the drain loop, and the drain loop reaps on its own.
            reaperStop->store( true );
            state->cv.notify_all();
            if( reaper.joinable() ) reaper.join();
        }
        const auto deadline = std::chrono::steady_clock::now() +
                               std::chrono::milliseconds( cfg.shutdownDrainMs );
        while( std::chrono::steady_clock::now() < deadline )
        {
            reap();
            bool alive = false;
            { std::lock_guard<std::mutex> lk( state->mu ); alive = !state->conns.empty(); }
            // A refusal that is still delivering itself counts as alive: the
            // process must not exit while a client is owed its 503.
            if( !alive && refusalsInFlight->load() == 0 ) break;
            std::this_thread::sleep_for( std::chrono::milliseconds( 50 ) );
        }
        {
            // Whatever is still in flight is detached rather than joined:
            // a client that opened a connection and never sent a request
            // would otherwise wedge the shutdown for good. Detaching is
            // safe because the thread owns every object it touches.
            std::lock_guard<std::mutex> lk( state->mu );
            for( auto& c : state->conns ) if( c->t.joinable() ) c->t.detach();
        }
#ifdef _WIN32
        WSACleanup();
#endif
        return 0;
    }
}