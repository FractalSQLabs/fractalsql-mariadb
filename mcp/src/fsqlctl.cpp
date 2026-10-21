// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// fsqlctl.cpp: the MCP server's client for fractalsqld's control plane.
//
// Licence boundary. This file speaks FSQ protocol v2 as written in
// service/protocol/SPEC.md (the wire format is MIT-licensed so that any
// process may implement it). Like service/cli/fsqlctl.c it is an
// independent client: it includes no header from the GPL-2.0-only shim
// (service/shim), the Apache-2.0 daemon (service/daemon), or the vendored
// core (include/, src/), and it shares no code with them. The whole MCP
// server is a separate process that reaches the engine in exactly two ways:
// SQL over libmariadb (a dynamically linked, LGPL client library) and this
// socket protocol to the daemon. service/scripts/mcp_boundary_check.sh
// enforces that, and `make -C service scan` runs it.
#include "fsqlctl.h"
#include "errors.h"
#include <openssl/crypto.h>
#include <openssl/hmac.h>
#include <cstring>
#include <vector>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <Windows.h>
#else
  #include <sys/socket.h>
  #include <sys/un.h>
  #include <unistd.h>
#endif
#include <cctype>

namespace fsqlmcp
{
    static constexpr std::uint16_t OP_PING    = 0x0001;
    static constexpr std::uint16_t OP_VERSION = 0x0002;
    static constexpr std::uint16_t OP_RELOAD  = 0x0014;

    static const char* const kStatusNames[] = { "OK","ARGS","LIMIT","CORE","NOT_LICENSED","AUTH","INTERNAL","NOTSUP","BUSY" };

    FsqlCtl::FsqlCtl( const std::string& socketPath, const std::string& keyPath )
        : socketPath_( socketPath ), keyPath_( keyPath )
    {
        if( socketPath_.empty() )
            throw ToolError( ErrorClass::Connectivity,
                "fractalsql_set_config/_get_config need the fractalsqld daemon: set FSQLCTL_SOCKET "
                "(a Unix socket path or a \\\\.\\pipe\\name) and FSQLCTL_KEY (path to the hex HMAC key file)" );
        if( keyPath_.empty() )
            throw ToolError( ErrorClass::Connectivity,
                "FSQLCTL_KEY is not set: the daemon authenticates its frames with an "
                "HMAC key file shared with the shim (see docs/fractalsql-daemon.md)" );

        std::FILE* f = std::fopen( keyPath_.c_str(), "rb" );
        if( !f )
            throw ToolError( ErrorClass::Connectivity,
                              "cannot read daemon key file " + keyPath_ );
        std::string hex;
        int c;
        while( ( c = std::fgetc( f ) ) != EOF && c != '\n' && c != '\r' )
            hex.push_back( static_cast<char>( c ) );
        std::fclose( f );
        std::string tight;
        for( char ch : hex )
            if( !std::isspace( static_cast<unsigned char>( ch ) ) ) tight.push_back( ch );
        if( tight.size() < 2 || tight.size() > 128 || ( tight.size() % 2 ) != 0 )
            throw ToolError( ErrorClass::Connectivity, "daemon key file is not a hex key of 2 to 128 digits" );
        for( char ch : tight )
            if( !std::isxdigit( static_cast<unsigned char>( ch ) ) )
                throw ToolError( ErrorClass::Connectivity, "daemon key file is not a hex key of 2 to 128 digits" );
        hmacKey_.clear();
        for( std::size_t i = 0; i + 1 < tight.size(); i += 2 )
            hmacKey_.push_back( static_cast<char>( std::stoi( tight.substr( i, 2 ), nullptr, 16 ) ) );
        if( hmacKey_.empty() || hmacKey_.size() > 64 )
            throw ToolError( ErrorClass::Connectivity, "daemon key file is not a hex key of 2 to 128 digits" );
    }

    static void putLE16( std::string& s, std::uint16_t v ) { s.push_back( char( v & 0xFF ) ); s.push_back( char( ( v >> 8 ) & 0xFF ) ); }
    static void putLE32( std::string& s, std::uint32_t v ) { for( int i = 0; i < 4; ++i ) s.push_back( char( ( v >> ( 8 * i ) ) & 0xFF ) ); }
    static void putLE64( std::string& s, std::uint64_t v ) { for( int i = 0; i < 8; ++i ) s.push_back( char( ( v >> ( 8 * i ) ) & 0xFF ) ); }
    static std::uint32_t getLE32( const unsigned char* p )
    { return p[ 0 ] | ( p[ 1 ] << 8 ) | ( p[ 2 ] << 16 ) | ( std::uint32_t( p[ 3 ] ) << 24 ); }
    static std::uint16_t getLE16( const unsigned char* p ) { return static_cast<std::uint16_t>( p[ 0 ] | ( p[ 1 ] << 8 ) ); }

    // Transport over a raw Windows named pipe (\\.\pipe\<name>, CreateFile, no
    // buffering layer) or POSIX domain socket, unbuffered, which keeps the down-daemon path a connect()
    // failure, never a timeout-shaped hang.
    class DaemonTransport
    {
    public:
        explicit DaemonTransport( const std::string& path )
        {
#ifdef _WIN32
            // SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: the client
            // grants the daemon identification-level impersonation of this
            // token. Without SQOS, npfs assigns SecurityAnonymous, and the
            // daemon's cross-account vetting (peer_allowed) falls back to
            // ImpersonateNamedPipeClient, which fails with
            // ERROR_CANNOT_IMPERSONATE (1368) and refuses the connection.
            // Identification is the right level: the daemon only reads the
            // token's user SID against its allow-list.
            //
            // The ERROR_PIPE_BUSY retry is not optional: the daemon creates
            // the NEXT pipe instance only AFTER a client has connected, so
            // back-to-back connections (this class opens one per frame, and
            // the admin tier's ping-then-reload is two frames) can find every
            // instance busy (error 231). WaitNamedPipeA waits for the daemon
            // to publish the next instance, exactly as the shim does.
            for( int tries = 0; tries < 3; ++tries )
            {
                handle_ = CreateFileA( path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                        OPEN_EXISTING,
                                        SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                                        nullptr );
                if( handle_ != INVALID_HANDLE_VALUE ) break;
                if( GetLastError() != ERROR_PIPE_BUSY ) break;
                WaitNamedPipeA( path.c_str(), 5000 );
            }
            if( handle_ == INVALID_HANDLE_VALUE )
                throwDaemonUnreachable( path );
#else
            fd_ = ::socket( AF_UNIX, SOCK_STREAM, 0 );
            if( fd_ < 0 ) throwDaemonUnreachable( path );
            sockaddr_un addr{};
            addr.sun_family = AF_UNIX;
            // A path longer than sun_path can hold was silently TRUNCATED
            // by strncpy, and the connect then failed against a socket
            // path the caller never asked for -- or, worse, against some
            // other daemon that happens to answer on the truncated name.
            // Refuse the path with a message that names the limit.
            if( path.size() >= sizeof( addr.sun_path ) )
            {
                ::close( fd_ ); fd_ = -1;
                throw ToolError( ErrorClass::Connectivity,
                    "the fractalsqld socket path is too long for a Unix domain socket (" +
                    std::to_string( path.size() ) + " bytes; the limit is " +
                    std::to_string( sizeof( addr.sun_path ) - 1 ) + ")" );
            }
            std::strncpy( addr.sun_path, path.c_str(), sizeof( addr.sun_path ) - 1 );
            if( ::connect( fd_, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) != 0 )
            { ::close( fd_ ); fd_ = -1; throwDaemonUnreachable( path ); }
#endif
        }
        ~DaemonTransport() { closeIt(); }

        void writeAll( const char* p, std::size_t n )
        {
#ifdef _WIN32
            DWORD written = 0;
            while( n > 0 )
            {
                if( !WriteFile( handle_, p, static_cast<DWORD>( n ), &written, nullptr ) || written == 0 )
                    throw ToolError( ErrorClass::Connectivity, "fractalsqld connection broke during write" );
                p += written; n -= written;
            }
#else
            std::size_t off = 0;
            while( off < n )
            {
                const ssize_t k = ::write( fd_, p + off, n - off );
                if( k <= 0 )
                    throw ToolError( ErrorClass::Connectivity, "fractalsqld connection broke during write" );
                off += static_cast<std::size_t>( k );
            }
#endif
        }
        void readExact( unsigned char* dst, std::size_t n )
        {
            std::size_t got = 0;
            while( got < n )
            {
#ifdef _WIN32
                DWORD read = 0;
                if( !ReadFile( handle_, dst + got, static_cast<DWORD>( n - got ), &read, nullptr ) || read == 0 )
                    throw ToolError( ErrorClass::Connectivity, "daemon closed the connection mid-reply" );
                got += read;
#else
                const ssize_t k = ::read( fd_, dst + got, n - got );
                if( k <= 0 )
                    throw ToolError( ErrorClass::Connectivity, "daemon closed the connection mid-reply" );
                got += static_cast<std::size_t>( k );
#endif
            }
        }

    private:
        static void throwDaemonUnreachable( const std::string& path )
        {
            throw ToolError( ErrorClass::Connectivity,
                "cannot reach fractalsqld at its socket (" + path + "): is the daemon running? "
                "A stopped daemon fails calls immediately with a clear error, never a hang, never a crash (documented)" );
        }
        void closeIt()
        {
#ifdef _WIN32
            if( handle_ != INVALID_HANDLE_VALUE ) { CloseHandle( handle_ ); handle_ = INVALID_HANDLE_VALUE; }
#else
            if( fd_ >= 0 ) { ::close( fd_ ); fd_ = -1; }
#endif
        }
#ifdef _WIN32
        HANDLE handle_ = INVALID_HANDLE_VALUE;
#else
        int fd_ = -1;
#endif
    };

    FsqlCtl::Reply FsqlCtl::rawRoundtrip( std::uint16_t opcode, const std::string& payload )
    {
        std::string header = "FSQ1";
        putLE16( header, 2 );                       // protocol version
        putLE16( header, opcode );
        putLE32( header, 0 );                       // flags
        putLE32( header, 1 );                       // request_id (single-request frames)
        putLE64( header, 0 );                       // context
        putLE32( header, 32 );                      // auth_len
        putLE32( header, static_cast<std::uint32_t>( payload.size() ) );
        std::string toSign = header + payload;
        unsigned char tag[ 32 ]; unsigned int tagLen = 0;
        HMAC( EVP_sha256(), hmacKey_.data(), static_cast<int>( hmacKey_.size() ),
              reinterpret_cast<const unsigned char*>( toSign.data() ),
              toSign.size(), tag, &tagLen );

        DaemonTransport xport( socketPath_ );
        xport.writeAll( header.data(), header.size() );
        xport.writeAll( reinterpret_cast<const char*>( tag ), 32 );
        if( !payload.empty() ) xport.writeAll( payload.data(), payload.size() );

        unsigned char rh[ 32 ];
        xport.readExact( rh, 32 );
        if( std::memcmp( rh, "FSQ1", 4 ) != 0 )
            throw ToolError( ErrorClass::Connectivity, "daemon reply has an unexpected magic/version" );
        const std::uint16_t rversion = getLE16( rh + 4 );
        if( rversion != 2 )
            throw ToolError( ErrorClass::Connectivity, "daemon reply has an unexpected magic/version" );
        const std::uint16_t ropcode = getLE16( rh + 6 );
        const std::uint32_t flags   = getLE32( rh + 8 );
        // Header layout (service/protocol/fsq_protocol.h):
        //   0 magic[4]  4 version u16  6 opcode u16  8 flags u32  12 request_id u32
        //   16 context u64  24 auth_len u32  28 payload_len u32
        // The reply's LENGTH is payload_len at offset 28. Offset 24 holds
        // auth_len, which is always 32 -- reading the length from there
        // truncated every reply to 32 bytes and made the HMAC check below
        // fail on a perfectly good reply (caught live: the admin tier
        // reported "daemon unreachable" for a daemon that was answering
        // correctly).
        const std::uint32_t rlen    = getLE32( rh + 28 );

        unsigned char rt[ 32 ];
        xport.readExact( rt, 32 );
        std::string body( rlen, '\0' );
        if( rlen ) xport.readExact( reinterpret_cast<unsigned char*>( &body[ 0 ] ), rlen );

        unsigned char expect[ 32 ]; unsigned int elen = 0;
        std::string toVerify = std::string( reinterpret_cast<const char*>( rh ), 32 ) + body;
        HMAC( EVP_sha256(), hmacKey_.data(), static_cast<int>( hmacKey_.size() ),
              reinterpret_cast<const unsigned char*>( toVerify.data() ), toVerify.size(), expect, &elen );
        if( CRYPTO_memcmp( expect, rt, 32 ) != 0 )   // constant time, as the daemon side does
            throw ToolError( ErrorClass::Connectivity, "daemon reply HMAC mismatch" );

        if( body.size() < 8 )
            throw ToolError( ErrorClass::Engine, "fsqlctl: reply body shorter than its own status header" );
        Reply r;
        r.opcode = ropcode; r.flags = flags;
        r.status = getLE32( reinterpret_cast<const unsigned char*>( body.data() ) );
        r.coreRc = static_cast<std::int32_t>( getLE32( reinterpret_cast<const unsigned char*>( body.data() ) + 4 ) );
        r.body   = body.substr( 8 );
        return r;
    }

    std::uint16_t FsqlCtl::ping()
    {
        const Reply r = rawRoundtrip( OP_PING, "" );
        if( r.flags & 0x2 ) throw ToolError( ErrorClass::Connectivity, "daemon refused ping" );
        return r.body.size() >= 2 ? getLE16( reinterpret_cast<const unsigned char*>( r.body.data() ) ) : 0;
    }

    std::string FsqlCtl::version()
    {
        const Reply r = rawRoundtrip( OP_VERSION, "" );
        if( r.flags & 0x2 ) raiseRefusal( r, "version" );
        return r.body;
    }

    std::string FsqlCtl::reload()
    {
        // RELOAD: daemon re-reads the conf file and publishes it. Live-reload
        // semantics carried through verbatim: provider keys change on the
        // tier's NEXT call; a load attempt is never performed by the reload
        // itself; enterprise_lib refuses a live change while a library is loaded
        // (restart-only). A refusal reply carries the daemon's own reason.
        const Reply r = rawRoundtrip( OP_RELOAD, "" );
        if( r.flags & 0x2 ) raiseRefusal( r, "reload" );
        return "reloaded: configuration swapped in";
    }

    void FsqlCtl::raiseRefusal( const Reply& r, const char* what )
    {
        const char* name = r.status < 9 ? kStatusNames[ r.status ] : "UNKNOWN";
        std::string reason = r.body;
        while( !reason.empty() && ( reason.back() == '\n' || reason.back() == ' ' ) ) reason.pop_back();
        std::string msg = std::string( what ) + " refused (" + name + ")";
        if( !reason.empty() ) msg += ": " + reason;
        throw ToolError( ErrorClass::Engine, msg );
    }
}