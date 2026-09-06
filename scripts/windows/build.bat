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
REM     fractalsql-%CORE_VARIANT%.lib (this repo's own include/, dropped
REM     by fractalsql-core's deploy.sh, the same source as the Linux/macOS
REM     archives; see Makefile's own CORE_VARIANT comment).
REM
REM Environment overrides
REM   MARIADB_DIR   directory with MariaDB binaries tree
REM                 (the "mariadb-^<VER^>-winx64" root from the ZIP)
REM   MARIADB_MAJOR MariaDB major version being targeted (e.g. 10.6, 10.11, 11.4, 12.2)
REM   OUT_DIR       output directory for fractalsql.dll
REM   CORE_VARIANT  vendored core archive selector (default community-sovereign-c)
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
    echo ==^> ERROR: MARIADB_MAJOR must be set ^(10.6 ^| 10.11 ^| 11.4 ^| 12.2^)
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

REM cl.exe flags:
REM   /MT     static CRT (no MSVC runtime DLL dependency)
REM   /GL     whole-program optimization (paired with /LTCG at link)
REM   /O2     optimize for speed
REM   /LD     build a DLL
REM   /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS
REM
REM The UDF entry points (fractal_search / fractalsql_edition /
REM fractalsql_version / ... plus their _init/_deinit) carry
REM __declspec(dllexport) via the FRACTAL_EXPORT macro in
REM src/fractalsql.c, so no .def file is needed and candle/light
REM downstream won't need to play with export tables.
cl.exe /nologo /MT /GL /O2 ^
    /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS ^
    /I"%MARIADB_INC%" ^
    /Iinclude ^
    /LD src\fractalsql.c src\fractalsql_session.c src\fractalsql_vector.c src\fractalsql_cognition.c ^
        src\fractalsql_textsql.c src\fractalsql_enterprise.c ^
    /Fo"%OUT_DIR%\\" ^
    /Fe"%OUT_DIR%\fractalsql.dll" ^
    /link /LTCG ^
        "%CORE_LIB%"

if errorlevel 1 (
    echo.
    echo ==^> BUILD FAILED for MariaDB %MARIADB_MAJOR%
    exit /b 1
)

echo.
echo ==^> Built %OUT_DIR%\fractalsql.dll ^(MariaDB %MARIADB_MAJOR%^)
dir "%OUT_DIR%\fractalsql.dll"

endlocal
