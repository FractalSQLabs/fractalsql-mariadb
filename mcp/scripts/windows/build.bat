@echo off
REM fractalsql-mariadb-mcp Windows build, mirroring the repo's own
REM scripts/windows/build.bat conventions (Developer Command Prompt / vcvars64
REM on PATH, VCPKG_ROOT for OpenSSL, the vendored deps\mariadb\root tree for
REM Connector/C). Run from a vcvars64'd prompt, or let this script call it.

setlocal enabledelayedexpansion

if "%VCPKG_ROOT%"=="" set "VCPKG_ROOT=C:\Users\Daniel Gardiner\github\vcpkg"
if "%VCPKG_ROOT%"=="" (
    echo VCPKG_ROOT not set and no default tree found ^& exit /b 1
    exit /b 1
)
set "OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static"
if not exist "%OPENSSL_DIR%\include\openssl\ssl.h" (
    REM vcvars resets VCPKG_ROOT to the VS-bundled tree (whose OpenSSL tree is
    REM only present after a vcpkg install) — fall back to the repo's own tree.
    set "VCPKG_ROOT=C:\Users\Daniel Gardiner\github\vcpkg"
    set "OPENSSL_DIR=!VCPKG_ROOT!\installed\x64-windows-static"
)
if not exist "%OPENSSL_DIR%\include\openssl\ssl.h" (
    echo no openssl tree under VCPKG_ROOT ^(%VCPKG_ROOT%^)
    exit /b 1
)

REM MariaDB Connector/C: the repo's own vendored server deps tree carries the
REM client headers + libmariadb.lib alongside the server build; MARIADB_DIR can
REM override (e.g. a real Connector/C install).
if "%MARIADB_DIR%"=="" set "MARIADB_DIR=%~dp0..\..\..\deps\mariadb\root"
REM The import library's NAME and the client DLL's PATH can be overridden
REM separately: a MariaDB tree that carries the client under the legacy
REM mariadbclient.lib name would fail the link step with LNK1181 otherwise,
REM and the DLL does not live in lib\ in every distribution.
if "%MARIADB_CLIENT_LIB%"=="" set "MARIADB_CLIENT_LIB=libmariadb.lib"
if "%MARIADB_CLIENT_DLL%"=="" set "MARIADB_CLIENT_DLL=%MARIADB_DIR%\lib\libmariadb.dll"

REM Suite-standard output tree (the mcp_smoke gate locates the binary
REM here; the old mcp\build output moved with this server's first
REM harness-integrated release).
set outdir=%~dp0..\..\dist\windows-mcp
if not exist "%outdir%" mkdir "%outdir%"
cd /d "%~dp0..\.."

REM VS Build Tools already on PATH (this script, like the repo's own build.bat,
REM assumes a vcvars64'd environment; VS 2022 Build Tools / VS 18 both work).
where cl.exe >nul 2>&1
if errorlevel 1 (
    for %%v in (
        "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    ) do if exist %%v call %%v >nul 2>&1
)

cl.exe /nologo /std:c++17 /EHsc /O2 /W3 /utf-8 /Zm500 /MT /D_CRT_SECURE_NO_WARNINGS /DNOMINMAX ^
    /I "%~dp0..\..\vendor" ^
    /I "%~dp0..\..\src" ^
    /I "%OPENSSL_DIR%\include" ^
    /I "%MARIADB_DIR%\include\mysql" ^
    src\*.cpp src\adapters\*.cpp ^
    /Fe"%outdir%\fractalsql-mariadb-mcp.exe" ^
    /Fo"%outdir%\\" ^
    /link /LIBPATH:"%OPENSSL_DIR%\lib" libssl.lib libcrypto.lib ws2_32.lib advapi32.lib crypt32.lib user32.lib ^
          /LIBPATH:"%MARIADB_DIR%\lib" "%MARIADB_CLIENT_LIB%"
if errorlevel 1 (
    echo EXITCODE=%ERRORLEVEL%
    exit /b 1
)

REM The exe links libmariadb.dll at runtime -- stage it next to the exe
REM so dist\windows-mcp\ is runnable as-is (the mcp_smoke gate spawns
REM the exe directly from that tree).
copy /Y "%MARIADB_CLIENT_DLL%" "%outdir%\" >nul
if errorlevel 1 (
  echo could not stage "%MARIADB_CLIENT_DLL%" 1>&2
  exit /b 1
)

echo EXITCODE=%ERRORLEVEL%
endlocal