@echo off
REM scripts/windows/build.bat
REM
REM Builds fractalsql.dll on Windows with the MSVC toolchain using
REM static CRT (/MT) and whole-program optimization (/GL), matching
REM the Linux/macOS posture: zero runtime dependency on the Visual C++
REM Redistributable, and zero dependency on LuaJIT. It statically links
REM the vendored pure-C core archive instead, the same
REM community-sovereign-c archive the Linux/macOS builds link, see
REM CORE_VARIANT in Makefile/build.sh.
REM
REM One DLL per (MariaDB major, arch) cell: the UDF ABI is stable
REM across 10.6 / 10.11 / 11.4, but we still build per-major on
REM Windows because the install target path differs per server
REM installation (C:\Program Files\MariaDB ^<VER^>\lib\plugin\).
REM
REM Prerequisites
REM   * Visual Studio Build Tools (cl.exe on PATH: invoke from a
REM     Developer Command Prompt, or `call vcvarsall.bat ^<arch^>` first).
REM   * A MariaDB Windows binaries tree (mariadb-^<VER^>-winx64.zip
REM     from archive.mariadb.org), unpacked so that:
REM         %MARIADB_DIR%\include\mysql\mysql.h
REM     exists. Only headers are needed, since UDFs don't link against a
REM     server import lib.
REM   * The vendored core archive at include\windows-x86_64\
REM     fractalsql-%CORE_VARIANT%.lib (this repo's own include/, the
REM     same source as the Linux/macOS archives; see Makefile's own
REM     CORE_VARIANT comment).
REM   * OpenSSL, static (x64-windows-static triplet, matching /MT below),
REM     for src\fractalsql_enterprise.c's ent_verify_signature() (Ed25519
REM     signature check on the enterprise .so before loading it).
REM     MariaDB's official
REM     Windows binaries are statically linked against wolfSSL, not
REM     OpenSSL (confirmed via mariadb.com's own TLS/crypto-library docs,
REM     and directly: the winx64 zip ships no libcrypto.lib or openssl/
REM     headers at all) -- there is nothing to reuse here, so this needs
REM     its own independent OpenSSL, brought in via vcpkg (the standard
REM     way to get MSVC-compatible headers and a static .lib -- same
REM     tool fractalsql-reasoning-http's own Windows build already uses
REM     for libcurl, pre-installed on GitHub's windows-latest/windows-2022
REM     runners at C:\vcpkg).
REM       vcpkg install openssl:x64-windows-static
REM     Defaults to C:\vcpkg below; override via VCPKG_ROOT if yours
REM     lives elsewhere.
REM     Statically linked, so this adds no new runtime DLL dependency.
REM
REM Environment overrides
REM   MARIADB_DIR   directory with MariaDB binaries tree
REM                 (the "mariadb-^<VER^>-winx64" root from the ZIP)
REM   MARIADB_MAJOR MariaDB major version being targeted (e.g. 10.6, 10.11, 11.4, 12.3)
REM   OUT_DIR       output directory for fractalsql.dll
REM   CORE_VARIANT  vendored core archive selector (default community-sovereign-c)
REM   VCPKG_ROOT    vcpkg install root (default: C:\vcpkg)
REM
REM Invocation
REM   set MARIADB_DIR=%CD%\deps\mariadb\root
REM   set MARIADB_MAJOR=11.4
REM   set OUT_DIR=dist\windows\mdb11.4
REM   scripts\windows\build.bat

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

if "%MARIADB_DIR%"=="" (
    echo ==^> ERROR: MARIADB_DIR must point at an unpacked MariaDB binaries tree
    exit /b 1
)
if "%MARIADB_MAJOR%"==""   (
    echo ==^> ERROR: MARIADB_MAJOR must be set ^(10.6 ^| 10.11 ^| 11.4 ^| 12.3^)
    exit /b 1
)
if "%OUT_DIR%"==""    set OUT_DIR=dist\windows\mdb%MARIADB_MAJOR%
if "%CORE_VARIANT%"=="" set CORE_VARIANT=community-sovereign-c

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo ==^> MARIADB_DIR    = %MARIADB_DIR%
echo ==^> MARIADB_MAJOR  = %MARIADB_MAJOR%
echo ==^> OUT_DIR        = %OUT_DIR%
echo ==^> CORE_VARIANT   = %CORE_VARIANT%

REM Vendored core static lib. -import.lib is the DLL-linkage stub for
REM dynamic linking against fractalsql-community-*.dll. It is
REM deliberately NOT used here, since that would give fractalsql.dll a
REM runtime dependency on a second DLL, contradicting the
REM zero-extra-runtime-dependency posture the /MT static CRT is already
REM going for.
set CORE_LIB=include\windows-x86_64\fractalsql-%CORE_VARIANT%.lib
if not exist "%CORE_LIB%" (
    echo ==^> ERROR: vendored core archive missing: %CORE_LIB%
    echo         Refresh from foundry:
    echo           cd ..\fractalsql-core ^&^& .\scripts\deploy.sh --git fractalsql-mariadb
    exit /b 1
)
echo ==^> CORE_LIB       = %CORE_LIB%

REM MariaDB header tree. A UDF doesn't call server-exported symbols,
REM so no server import lib is needed: the server loads this DLL and
REM calls the exported UDF entry points by name via GetProcAddress.
set MARIADB_INC=%MARIADB_DIR%\include\mysql
if not exist "%MARIADB_INC%\mysql.h" (
    echo ==^> ERROR: %MARIADB_INC%\mysql.h not found: check MARIADB_DIR layout
    exit /b 1
)
echo ==^> MARIADB_INC    = %MARIADB_INC%

REM OpenSSL (static): src\fractalsql_enterprise.c needs openssl/evp.h
REM and links against libcrypto for Ed25519 signature verification. See
REM this file's own Prerequisites comment for how to get it via vcpkg.
REM Same VCPKG_ROOT convention as fractalsql-reasoning-http's own
REM scripts\build-windows.ps1: default to C:\vcpkg (pre-installed at
REM that exact path on GitHub's windows-latest/windows-2022 runners),
REM overridable via the environment.
if "%VCPKG_ROOT%"=="" if not "%VCPKG_INSTALLATION_ROOT%"=="" set VCPKG_ROOT=%VCPKG_INSTALLATION_ROOT%
if "%VCPKG_ROOT%"=="" set VCPKG_ROOT=C:\vcpkg
if not exist "%VCPKG_ROOT%\vcpkg.exe" (
    echo ==^> ERROR: no vcpkg.exe found at %VCPKG_ROOT%
    echo         Install vcpkg, then: vcpkg install openssl:x64-windows-static
    echo         and set VCPKG_ROOT to vcpkg's root directory if it isn't C:\vcpkg.
    exit /b 1
)
set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
    echo ==^> ERROR: OpenSSL headers not found under %OPENSSL_DIR%
    echo         Run: vcpkg install openssl:x64-windows-static
    exit /b 1
)
echo ==^> OPENSSL_DIR    = %OPENSSL_DIR%

REM cl.exe flags:
REM   /MT     static CRT (no MSVC runtime DLL dependency)
REM   /GL     whole-program optimization (paired with /LTCG at link)
REM   /O2     optimize for speed
REM   /LD     build a DLL
REM   /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS
REM
REM   /DFSQL_STATIC: switches fractalsql.h's FSQL_API macro from the
REM   default dllimport (consumer-of-a-DLL mode) to a plain extern,
REM   matching the vendored static .lib we link below (see
REM   include/fractalsql.h:82-91). Without this the compiler emits
REM   __imp_fsql_* references that only an import library
REM   (fractalsql-*-import.lib, the .dll's companion) would satisfy --
REM   the static .lib has plain fsql_* symbols, not __imp_ thunks
REM   (confirmed directly: LNK2001 on 33 __imp_fsql_* externals on the
REM   first real Windows run without it).
REM
REM The UDF entry points (fractal_search / fractalsql_edition /
REM fractalsql_version / ... plus their _init/_deinit) carry
REM __declspec(dllexport) via the FRACTAL_EXPORT macro in
REM src/fractalsql.c, so no .def file is needed and candle/light
REM downstream won't need to play with export tables.
REM /U_WINDLL: MSVC's /LD (building a DLL, this invocation) implicitly
REM predefines _WINDLL for the WHOLE compilation, not just when OpenSSL
REM itself is being built as one. openssl/e_os2.h keys its OPENSSL_EXPORT/
REM OPENSSL_EXTERN macros on exactly that macro: with it defined, every
REM EVP_* declaration in this file becomes __declspec(dllimport), the
REM wrong decoration against libcrypto.lib's real static archive rather
REM than a DLL's import stub (confirmed by reading e_os2.h directly:
REM "OPENSSL_OPT_WINDLL" is set iff _WINDLL is defined, which then picks
REM the dllimport branch). Same class of bug as libcurl's own
REM CURL_STATICLIB fix for its DLL-vs-static export macro -- /U removes a
REM predefined macro on the cl.exe command line, undoing what /LD set
REM before openssl/evp.h ever sees it.
REM
REM libcrypto's static build pulls in these system libs transitively
REM (ws2_32/crypt32/advapi32/user32/gdi32) -- the exact set can vary by
REM OpenSSL/vcpkg version; not independently verified against a real
REM Windows+vcpkg+MSVC build in this repo's own CI yet (see build-test.yml's
REM windows-gate-matrix, the actual verification gate). A missing one
REM surfaces as an "unresolved external symbol" link error, not a silent
REM miscompile, so it's safe to add more here if that happens.
cl.exe /nologo /MT /GL /O2 ^
    /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS ^
    /DFSQL_STATIC ^
    /U_WINDLL ^
    /I"%MARIADB_INC%" ^
    /Iinclude ^
    /I"%OPENSSL_DIR%\include" ^
    /LD src\fractalsql.c src\fractalsql_parse.c src\fractalsql_session.c src\fractalsql_vector.c src\fractalsql_cognition.c ^
        src\fractalsql_textsql.c src\fractalsql_enterprise.c ^
    /Fo"%OUT_DIR%\\" ^
    /Fe"%OUT_DIR%\fractalsql.dll" ^
    /link /LTCG ^
        "%CORE_LIB%" ^
        "%OPENSSL_DIR%\lib\libcrypto.lib" ^
        ws2_32.lib crypt32.lib advapi32.lib user32.lib gdi32.lib bcrypt.lib

if errorlevel 1 (
    echo.
    echo ==^> BUILD FAILED for MariaDB %MARIADB_MAJOR%
    exit /b 1
)

echo.
echo ==^> Built %OUT_DIR%\fractalsql.dll ^(MariaDB %MARIADB_MAJOR%^)
dir "%OUT_DIR%\fractalsql.dll"

endlocal
