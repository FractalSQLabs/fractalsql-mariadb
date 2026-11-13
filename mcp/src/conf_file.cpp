// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "conf_file.h"
#include "errors.h"
#include <fstream>
#include <cctype>
#include <cstdio>
#include <set>
#include <algorithm>
#include <atomic>
#include <random>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <Windows.h>
#else
  #include <sys/stat.h>
  #include <utime.h>
#endif

namespace fsqlmcp::conffile
{
    // http_token is the engine's own name for the reasoning bearer token:
    // the config key reasoning_token is carried in the C field
    // g_cfg.http_token, and the environment names it FRACTALSQL_HTTP_TOKEN.
    // It is the same credential under a second name, so it is a secret here
    // too.
    static const std::set<std::string> kSecretKeys{ "reasoning_token", "enterprise_ledger_key", "http_token" };

    static const std::set<std::string> kOperatorOnlyKeys{
        "enterprise_lib", "enterprise_ledger_path", "enterprise_ledger_key",
        "enterprise_require_signature",
    };

    // Exactly the live-reloadable provider/text-to-sql tier set from
    // docs/fractalsql-daemon.md.
    static const std::set<std::string> kEditableKeys{
        "reasoning_plugin", "reasoning_url", "reasoning_token", "reasoning_model",
        "reasoning_allow_plaintext", "embed_url", "embed_model",
        "think", "think_provider", "think_native_url", "think_num_ctx",
        "t2s_max_attempts", "t2s_allowed_statements", "t2s_use_review",
    };

    bool isSecretKey( const std::string& key )        { return kSecretKeys.count( key ) != 0; }
    bool isOperatorOnlyKey( const std::string& key )  { return kOperatorOnlyKeys.count( key ) != 0; }
    bool isEditableKey( const std::string& key )      { return kEditableKeys.count( key ) != 0; }

    // A key or value that cannot be represented on ONE line of the
    // daemon's config file. Returns the problem, or an empty string.
    // The file is line-based ("key = value"), so an embedded line break
    // is not part of the value: it ends the key's line and starts
    // another one.
    static std::string lineBreakProblem( const std::string& s )
    {
        for( char c : s )
        {
            if( c == '\n' ) return "contains a line feed";
            if( c == '\r' ) return "contains a carriage return";
            if( c == '\0' ) return "contains a NUL byte";
        }
        return "";
    }

    static const std::set<std::string> kPathKeys{
        "reasoning_plugin", "enterprise_lib", "enterprise_ledger_path",
    };

    bool isPathKey( const std::string& key ) { return kPathKeys.count( key ) != 0; }

    std::string pathProblem( const std::string& key, const std::string& value )
    {
        if( !isPathKey( key ) ) return {};

        if( value.empty() ) return "a path value must not be empty";

        // Absolute? Windows accepts a drive-letter path ("C:\dir\file",
        // "C:/dir/file"), a UNC path ("\\server\share\file") and a rooted
        // path ("\dir\file"); POSIX accepts a rooted path ("/dir/file").
        // A relative path is refused: the daemon's working directory is
        // not a contract, so the same value would name different files
        // depending on how the daemon was started.
        bool isAbs = false;
#ifdef _WIN32
        if( value.size() >= 3 && std::isalpha( static_cast<unsigned char>( value[ 0 ] ) ) &&
            value[ 1 ] == ':' && ( value[ 2 ] == '\\' || value[ 2 ] == '/' ) )
            isAbs = true;
        if( value.size() >= 2 && value[ 0 ] == '\\' && value[ 1 ] == '\\' ) isAbs = true;   // UNC
        if( value[ 0 ] == '\\' || value[ 0 ] == '/' ) isAbs = true;                          // rooted
#else
        if( value[ 0 ] == '/' ) isAbs = true;
#endif
        if( !isAbs )
            return "must be an absolute path with no '..' segments";

        // Lexical traversal: any ".." segment, whatever it is glued to.
        // Checking the whole path for ".." (rather than for a "/../"
        // segment) also refuses a file whose own name contains two dots,
        // which is not a name this codebase ever generates.
        if( value.find( ".." ) != std::string::npos )
            return "must be an absolute path with no '..' segments";

        return {};
    }

    std::map<std::string, std::string> readConf( const std::string& path )
    {
        std::ifstream in;
#ifdef _WIN32
        // writeConf replaces the file with MoveFileEx, and Windows can refuse an open of a file that was just
        // replaced for a short while: a virus scanner or indexer holds the new file, or the rename has not settled.
        // The writer already retries for that reason, so the reader must too, or a read that follows another
        // process's write fails with "cannot read" although the file is there. A file that is really missing is
        // reported at once.
        for( int attempt = 0; attempt < 40; ++attempt )
        {
            in.open( path );
            if( in ) break;
            in.clear();
            const DWORD attrs = GetFileAttributesA( path.c_str() );
            if( attrs == INVALID_FILE_ATTRIBUTES )
            {
                const DWORD e = GetLastError();
                if( e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND ) break;
            }
            Sleep( 50 );
        }
#else
        in.open( path );
#endif
        if( !in )
        {
            std::string detail;
#ifdef _WIN32
            // Which error Windows gave, so a failure that survives the retries says why.
            HANDLE h = CreateFileA( path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr );
            if( h == INVALID_HANDLE_VALUE )
                detail = " (Windows error " + std::to_string( static_cast<unsigned long>( GetLastError() ) ) + ")";
            else
                CloseHandle( h );
#endif
            throw ToolError( ErrorClass::Connectivity,
                "cannot read the daemon's config file (fractalsqld.conf); the config "
                "introspection tools need it. Set FSQLCTL_CONF to its path" + detail );
        }
        std::map<std::string, std::string> conf;
        std::string line;
        while( std::getline( in, line ) )
        {
            std::size_t s = 0, e = line.size();
            while( s < e && std::isspace( static_cast<unsigned char>( line[ s ] ) ) ) ++s;
            while( e > s && std::isspace( static_cast<unsigned char>( line[ e - 1 ] ) ) ) --e;
            if( s == e || line[ s ] == '#' ) continue;
            const std::size_t eq = line.find( '=', s );
            if( eq == std::string::npos || eq >= e ) continue;
            std::string k = line.substr( s, eq - s ), v = line.substr( eq + 1, e - eq - 1 );
            std::size_t ks = 0, ke = k.size();
            while( ks < ke && std::isspace( static_cast<unsigned char>( k[ ks ] ) ) ) ++ks;
            while( ke > ks && std::isspace( static_cast<unsigned char>( k[ ke - 1 ] ) ) ) --ke;
            std::size_t vs = 0, ve = v.size();
            while( vs < ve && std::isspace( static_cast<unsigned char>( v[ vs ] ) ) ) ++vs;
            while( ve > vs && std::isspace( static_cast<unsigned char>( v[ ve - 1 ] ) ) ) --ve;
            if( ks < ke ) conf[ k.substr( ks, ke - ks ) ] = v.substr( vs, ve - vs );
        }
        return conf;
    }

    std::mutex& confLock()
    {
        static std::mutex lock;
        return lock;
    }

    // The temporary file's name belongs to this write alone.
    //
    // Two writes to the same config file at the same time must not share
    // one temporary file: the second one truncates the first one's copy,
    // and the first one's rename moves the file away from under the
    // second, so one of the two changes is refused (or, worse, one
    // change's content lands in the other one's file).
    static std::string tempConfPath( const std::string& path )
    {
        static std::atomic<unsigned long long> n{ 0 };
        static const unsigned long long salt = std::random_device{}();
        return path + ".fsqlmcp." + std::to_string( salt ) + "." + std::to_string( ++n ) + ".tmp";
    }

    std::string writeConf( const std::string& path, const std::map<std::string, std::string>& conf )
    {
        const std::string tmp = tempConfPath( path );
        /* The daemon's config file is LINE-based ("key = value"), so a
         * newline inside a value is not a value: it ends the key's line
         * and starts another one. A caller-supplied value carrying
         * "\nenterprise_require_signature = 0" would otherwise inject an
         * arbitrary config key into the daemon's own file, including the
         * operator-only keys this surface refuses by name, and the keys
         * it refuses to set at all.
         *
         * The whole set is checked BEFORE the file is opened: a refusal
         * must not leave a half-written temporary file behind, and the
         * original file must be untouched (it is only replaced by the
         * rename at the end). Refused here, at the single choke point
         * every conf write goes through, rather than at each caller. */
        for( const auto& kv : conf )
        {
            const std::string problem = lineBreakProblem( kv.first );
            if( !problem.empty() )
                throw ToolError( ErrorClass::Schema,
                    "refusing to write the daemon's config file: the key '" + kv.first + "' " + problem
                    + " (a config key cannot span lines)" );
            const std::string vproblem = lineBreakProblem( kv.second );
            if( !vproblem.empty() )
                throw ToolError( ErrorClass::Schema,
                    "refusing to write the daemon's config file: the value for '" + kv.first + "' " + vproblem
                    + " (a config value cannot span lines; a line break would end the key's line and start "
                    "another one, injecting a config key)" );
        }
        // The temporary file is this write's own, so a write that fails
        // part way through removes it rather than leaving it behind.
        try
        {
            {
                std::ofstream out( tmp, std::ios::binary | std::ios::trunc );
                if( !out )
                    throw ToolError( ErrorClass::Connectivity,
                        "cannot write the daemon's config file. Config changes must be local files, and "
                        "this tool refuses to leave a half-applied state" );
                for( const auto& kv : conf )
                    out << kv.first << " = " << kv.second << "\n";
            }
#ifdef _WIN32
            // Preserve nothing mode-wise (Windows ACLs do not ride a rename anyway).
            // The daemon (or a scanner/indexer) may hold the destination open for a moment while it
            // reads it at a reload; Windows then refuses the replace with a sharing violation or
            // access denied. That clears in milliseconds, so retry for up to ~2 s before giving up.
            {
                DWORD err = 0;
                bool replaced = false;
                for( int attempt = 0; attempt < 40 && !replaced; ++attempt )
                {
                    if( MoveFileExA( tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING ) ) { replaced = true; break; }
                    err = GetLastError();
                    if( err != ERROR_SHARING_VIOLATION && err != ERROR_ACCESS_DENIED && err != ERROR_LOCK_VIOLATION ) break;
                    Sleep( 50 );
                }
                if( !replaced )
                    throw ToolError( ErrorClass::Connectivity,
                        "cannot replace the daemon's config file on disk (Windows error "
                        + std::to_string( static_cast<unsigned long>( err ) ) + ")" );
            }
#else
            struct stat st{};
            if( ::stat( path.c_str(), &st ) == 0 )
                ::chmod( tmp.c_str(), st.st_mode & 0777 );
            if( std::rename( tmp.c_str(), path.c_str() ) != 0 )
                throw ToolError( ErrorClass::Connectivity, "cannot replace the daemon's config file on disk" );
#endif
        }
        catch( ... )
        {
            std::remove( tmp.c_str() );
            throw;
        }
        return path;
    }
}