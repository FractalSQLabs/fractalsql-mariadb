@echo off
REM scripts/windows/build.bat
REM
REM Builds the shim and the daemon on Windows (see service/README.md):
REM   fractalsql.dll   shim loaded by mariadbd. Forwards each UDF call over
REM                    a named pipe. Links no core code and no OpenSSL.
REM   fractalsqld.exe  daemon. Serves the UDF bodies, the reasoning plugin
REM                    loader and the enterprise loader. Links the vendored
REM                    core archive and OpenSSL (Ed25519 signature check).
REM
REM Prerequisites
REM   * Visual Studio Build Tools, cl.exe on PATH (Developer Command Prompt,
REM     or call vcvarsall.bat ^<arch^> first).
REM   * Python 3 (python or py -3) for service\scripts\gen_udf.py.
REM   * A MariaDB Windows binaries tree whose include\mysql\mysql.h exists.
REM   * The vendored core archive at include\windows-x86_64\
REM     fractalsql-%CORE_VARIANT%.lib.
REM   * OpenSSL, static (x64-windows-static), for the daemon:
REM       vcpkg install openssl:x64-windows-static
REM     VCPKG_ROOT is read AFTER vcvars runs, since vcvars resets it to the
REM     VS-bundled vcpkg. Defaults to C:\vcpkg.
REM
REM Environment overrides
REM   MARIADB_DIR    MariaDB binaries tree (the mariadb-VER-winx64 root)
REM   MARIADB_MAJOR  MariaDB major version (10.6, 10.11, 11.4, 12.3)
REM   OUT_DIR        output directory (default dist\windows\mdb%MARIADB_MAJOR%)
REM   CORE_VARIANT   core archive selector (default community-sovereign-c)
REM   VCPKG_ROOT     vcpkg install root (default C:\vcpkg)
REM
REM Invocation
REM   set MARIADB_DIR=%CD%\deps\mariadb\root
REM   set MARIADB_MAJOR=11.4
REM   scripts\windows\build.bat

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

if "%MARIADB_DIR%"=="" (
    echo ==^> ERROR: MARIADB_DIR must point at an unpacked MariaDB binaries tree
    exit /b 1
)
if "%MARIADB_MAJOR%"=="" (
    echo ==^> ERROR: MARIADB_MAJOR must be set ^(10.6 ^| 10.11 ^| 11.4 ^| 12.3^)
    exit /b 1
)
if "%OUT_DIR%"=="" set OUT_DIR=dist\windows\mdb%MARIADB_MAJOR%
if "%CORE_VARIANT%"=="" set CORE_VARIANT=community-sovereign-c

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo ==^> MARIADB_DIR    = %MARIADB_DIR%
echo ==^> MARIADB_MAJOR  = %MARIADB_MAJOR%
echo ==^> OUT_DIR        = %OUT_DIR%
echo ==^> CORE_VARIANT   = %CORE_VARIANT%

set CORE_LIB=include\windows-x86_64\fractalsql-%CORE_VARIANT%.lib
if not exist "%CORE_LIB%" (
    echo ==^> ERROR: vendored core archive missing: %CORE_LIB%
    echo         Refresh the vendored core artifact per the vendoring process
    echo         ^(deploy the foundry build into include\windows-x86_64^).
    exit /b 1
)
echo ==^> CORE_LIB       = %CORE_LIB%

set MARIADB_INC=%MARIADB_DIR%\include\mysql
if not exist "%MARIADB_INC%\mysql.h" (
    echo ==^> ERROR: %MARIADB_INC%\mysql.h not found: check MARIADB_DIR layout
    exit /b 1
)
echo ==^> MARIADB_INC    = %MARIADB_INC%

if "%VCPKG_ROOT%"=="" if not "%VCPKG_INSTALLATION_ROOT%"=="" set VCPKG_ROOT=%VCPKG_INSTALLATION_ROOT%
if "%VCPKG_ROOT%"=="" set VCPKG_ROOT=C:\vcpkg
if not exist "%VCPKG_ROOT%\vcpkg.exe" (
    REM vcvars resets VCPKG_ROOT to the VS-bundled tree, whose path
    REM contains "(x86)" -- expanding that with %% inside a parenthesized
    REM block ends the block early ("\Microsoft was unexpected at this
    REM time"). Use !, resolved after the block is parsed.
    echo ==^> ERROR: no vcpkg.exe found at !VCPKG_ROOT!
    echo         Install vcpkg, then: vcpkg install openssl:x64-windows-static
    echo         and set VCPKG_ROOT to vcpkg's root directory if it isn't C:\vcpkg.
    exit /b 1
)
set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
    echo ==^> ERROR: OpenSSL headers not found under !OPENSSL_DIR!
    echo         Run: vcpkg install openssl:x64-windows-static
    echo         If !OPENSSL_DIR! is the VS-bundled vcpkg ^(under VC\vcpkg^),
    echo         vcvars64.bat overwrote VCPKG_ROOT -- set VCPKG_ROOT to
    echo         your real vcpkg AFTER calling vcvars, then rerun.
    exit /b 1
)
echo ==^> OPENSSL_DIR    = %OPENSSL_DIR%

REM Generated opcode tables for both sides, from protocol\opcodes.def.
set PY=python
where python >nul 2>&1 || set PY=py -3
if not exist service\build\gen mkdir service\build\gen
%PY% service\scripts\gen_udf.py service\build\gen
if errorlevel 1 (
    echo ==^> ERROR: gen_udf.py failed
    exit /b 1
)

REM Shim. /MT: static CRT, no runtime redistributable. /LD: DLL. The
REM UDF entry points carry FSQ_EXPORT (__declspec(dllexport)), so no .def.
echo.
echo ==^> Building shim
cl.exe /nologo /MT /O2 /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS ^
    /I"%MARIADB_INC%" /Iservice\build\gen ^
    /Fo"%OUT_DIR%\\" /LD service\shim\fractalsql_shim.c ^
    /Fe"%OUT_DIR%\fractalsql.dll" ^
    /link ws2_32.lib
if errorlevel 1 (
    echo.
    echo ==^> SHIM BUILD FAILED for MariaDB %MARIADB_MAJOR%
    exit /b 1
)

REM Daemon. CC_DAEMON, CRT_FLAG and SAN_FLAGS let build_test.ps1 build an
REM instrumented daemon (-Asan: cl /fsanitize=address; -Ubsan: clang-cl
REM -fsanitize=undefined). The shim is always built plain. /DFSQL_STATIC: the vendored core is a static .lib, so FSQL_API
REM must be a plain extern rather than dllimport. _WINDLL is not defined
REM (no /LD here), so openssl/e_os2.h takes the static-library branch.
echo.
echo ==^> Building daemon
if "%CC_DAEMON%"=="" set CC_DAEMON=cl.exe
if "%CRT_FLAG%"=="" set CRT_FLAG=/MT
"%CC_DAEMON%" /nologo %CRT_FLAG% /O2 %SAN_FLAGS% /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS /DFSQL_STATIC ^
    /I"%MARIADB_INC%" /Iinclude /Isrc /Iservice\build\gen ^
    /I"%OPENSSL_DIR%\include" ^
    /Fo"%OUT_DIR%\\" /Fe"%OUT_DIR%\fractalsqld.exe" ^
    service\daemon\fractalsqld.c ^
        src\fractalsql.c src\fractalsql_parse.c src\fractalsql_session.c ^
        src\fractalsql_vector.c src\fractalsql_cognition.c ^
        src\fractalsql_textsql.c src\fractalsql_enterprise.c ^
        src\fractalsql_interrupt.c ^
    /link /DEBUG ^
        "%CORE_LIB%" ^
        "%OPENSSL_DIR%\lib\libcrypto.lib" ^
        ws2_32.lib crypt32.lib advapi32.lib user32.lib gdi32.lib bcrypt.lib
if errorlevel 1 (
    echo.
    echo ==^> DAEMON BUILD FAILED for MariaDB %MARIADB_MAJOR%
    exit /b 1
)

REM Note: fsqlctl is NOT built on Windows. It is a POSIX CLI -- AF_UNIX
REM transport and getopt -- while this daemon is a named-pipe service, so
REM a Windows fsqlctl would need both a compat layer and a pipe client to
REM be useful. gen_udf.py still emits service\build\gen\fsqlctl_functions.h
REM (it derives from the same functions.def pass); Windows just ignores it.

echo.
echo ==^> Built %OUT_DIR%\fractalsql.dll ^(shim, MariaDB %MARIADB_MAJOR%^)
echo ==^> Built %OUT_DIR%\fractalsqld.exe ^(daemon^)
dir "%OUT_DIR%\fractalsql.dll" "%OUT_DIR%\fractalsqld.exe"

endlocal
