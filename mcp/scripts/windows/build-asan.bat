@echo off
rem SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
rem SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
rem
rem mcp\scripts\windows\build-asan.bat: the ASan build of the MCP server.
rem Same tree and link posture as build.bat, plus /fsanitize=address with cl.exe,
rem the toolchain that builds fractalsqld.exe for the -Asan leg. /Od keeps the
rem optimizer from deleting the out-of-bounds accesses the sanitizer should report.
rem
rem Usage: build-asan.bat [output-dir]   (default: dist\windows-mcp-asan in mcp\)

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set MCP_DIR=%SCRIPT_DIR%..\..
set REPO_DIR=%MCP_DIR%\..
set OUTDIR=%~1
if "%OUTDIR%"=="" set OUTDIR=%MCP_DIR%\dist\windows-mcp-asan

rem vcvars64.bat replaces VCPKG_ROOT with VS's bundled (empty) vcpkg; keep the caller's.
set INCOMING_VCPKG_ROOT=%VCPKG_ROOT%
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
set VSPATH=
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
)
if "%VSPATH%"=="" set VSPATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
if not exist "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" (
  echo FATAL: no Visual Studio VC tools found 1>&2
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
if not "%INCOMING_VCPKG_ROOT%"=="" set VCPKG_ROOT=%INCOMING_VCPKG_ROOT%

set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  set CANDIDATE=%REPO_DIR%\..\vcpkg
  if exist "!CANDIDATE!\installed\x64-windows-static\include\openssl\evp.h" set OPENSSL_DIR=!CANDIDATE!\installed\x64-windows-static
)
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  echo FATAL: OpenSSL for MSVC not found: run vcpkg install openssl:x64-windows-static 1>&2
  exit /b 1
)

rem Connector/C: the vendored deps tree, or MARIADB_DIR.
if "%MARIADB_DIR%"=="" set MARIADB_DIR=%REPO_DIR%\deps\mariadb\root
if not exist "%MARIADB_DIR%\lib\libmariadb.lib" (
  echo FATAL: MariaDB Connector/C not found under %MARIADB_DIR% 1>&2
  exit /b 1
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

cl.exe /nologo /std:c++17 /utf-8 /EHsc /MT /Od /W3 /Zi /Zm500 /fsanitize=address /D_CRT_SECURE_NO_WARNINGS /DNOMINMAX ^
  /I "%MCP_DIR%\vendor" /I "%MCP_DIR%\src" ^
  /I "%OPENSSL_DIR%\include" /I "%MARIADB_DIR%\include\mysql" ^
  "%MCP_DIR%\src\*.cpp" "%MCP_DIR%\src\adapters\*.cpp" ^
  /Fo"%OUTDIR%\\" ^
  /Fe"%OUTDIR%\fractalsql-mariadb-mcp.exe" ^
  /link /STACK:8388608 /DEBUG /LIBPATH:"%OPENSSL_DIR%\lib" libssl.lib libcrypto.lib ws2_32.lib advapi32.lib crypt32.lib user32.lib ^
  /LIBPATH:"%MARIADB_DIR%\lib" libmariadb.lib
if errorlevel 1 (
  echo FATAL: asan mcp build failed 1>&2
  exit /b 1
)

rem The exe loads libmariadb.dll at runtime.
copy /y "%MARIADB_DIR%\lib\libmariadb.dll" "%OUTDIR%\" >nul
if errorlevel 1 (
  echo FATAL: could not stage libmariadb.dll 1>&2
  exit /b 1
)

rem The exe imports the ASan runtime DLL by name. Stage the toolset's own copy
rem next to it so the loader never picks a same-named DLL from elsewhere on PATH.
copy /y "%VCToolsInstallDir%bin\Hostx64\x64\clang_rt.asan_dynamic-x86_64.dll" "%OUTDIR%\" >nul
if errorlevel 1 (
  echo FATAL: could not stage the ASan runtime DLL 1>&2
  exit /b 1
)

echo asan mcp build OK: %OUTDIR%\fractalsql-mariadb-mcp.exe
endlocal
exit /b 0
