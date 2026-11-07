@echo off
REM scripts/windows/build-msi.bat
REM
REM Packages fractalsql.dll (the shim mariadbd loads) and fractalsqld.exe
REM (the daemon), pre-built by build.bat, plus the install SQL and license
REM files, into a Windows MSI using the WiX Toolset.
REM
REM One MSI per (MariaDB major, arch) pair. The resulting MSI installs
REM into the target server's on-disk layout:
REM
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\lib\plugin\fractalsql.dll
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\fractalsqld\fractalsqld.exe
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\fractalsqld\LICENSE (Apache-2.0)
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\fractalsql-mcp\fractalsql-mariadb-mcp.exe (+ libmariadb.dll, the two lock files)
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\share\doc\fractalsql-mariadb\LICENSE
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\share\doc\fractalsql-mariadb\LICENSE-THIRD-PARTY
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\share\doc\fractalsql-mariadb\install_udf.sql
REM
REM That matches MariaDB's default Windows install layout, so end-users
REM who took the MSI server installer can run:
REM     mysql -u root -p ^< "C:\Program Files\MariaDB ^<VER^>\share\doc\fractalsql-mariadb\install_udf.sql"
REM with no further path munging.
REM
REM Prerequisites
REM   * WiX Toolset v3.x installed (candle.exe / light.exe on PATH).
REM   * dist\windows\mdb^<MARIADB_MAJOR^>\fractalsql.dll already produced
REM     by scripts\windows\build.bat.
REM   * mcp\dist\windows-mcp\ already produced by mcp\scripts\windows\build.bat.
REM
REM Environment
REM   MARIADB_MAJOR 10.6 ^| 10.11 ^| 11.4 ^| 12.3: selects UpgradeCode and install-folder name
REM   MSI_ARCH      x64 ^| arm64: passed to candle -arch
REM   MSI_VERSION   overrides Product Version (default 2.0.12, read from src\fractalsql.c's FSQL_VERSION if not set)

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set REPO_ROOT=%~dp0..\..
pushd %REPO_ROOT%

if "%MARIADB_MAJOR%"==""    (
    echo ==^> ERROR: MARIADB_MAJOR must be set ^(10.6 ^| 10.11 ^| 11.4 ^| 12.3^)
    popd
    exit /b 1
)
if "%MSI_ARCH%"==""    set MSI_ARCH=x64
if "%MSI_VERSION%"=="" (
    REM findstr splits a plain /r pattern on spaces into multiple search
    REM strings, which would also match every other line mentioning
    REM FSQL_VERSION (e.g. "static const char kVersion[] = FSQL_VERSION;")
    REM and let the last match's token 3 win. /c: keeps it one pattern.
    for /f "tokens=3" %%V in ('findstr /r /c:"^#define FSQL_VERSION" src\fractalsql.c') do set MSI_VERSION=%%~V
)
if "%MSI_VERSION%"=="" (
    echo ==^> ERROR: could not read FSQL_VERSION from src\fractalsql.c; set MSI_VERSION explicitly
    popd
    exit /b 1
)

set DLL=dist\windows\mdb%MARIADB_MAJOR%\fractalsql.dll
set DAEMON=dist\windows\mdb%MARIADB_MAJOR%\fractalsqld.exe
if not exist "%DLL%" (
    echo ==^> ERROR: %DLL% missing: run build.bat with MARIADB_MAJOR=%MARIADB_MAJOR% first
    popd
    exit /b 1
)
if not exist "%DAEMON%" (
    echo ==^> ERROR: %DAEMON% missing: run build.bat with MARIADB_MAJOR=%MARIADB_MAJOR% first
    popd
    exit /b 1
)

REM The MCP server, built by mcp\scripts\windows\build.bat (libmariadb.dll is staged next to it).
set MCPDIST=mcp\dist\windows-mcp
for %%F in (fractalsql-mariadb-mcp.exe libmariadb.dll) do if not exist "%MCPDIST%\%%F" (
    echo ==^> ERROR: %MCPDIST%\%%F missing: run mcp\scripts\windows\build.bat first
    popd
    exit /b 1
)

REM Per-(major, arch) staging dir so candle can reference a stable
REM "dist\windows\staging-...\fractalsql.dll" path from the wxs. Avoids
REM threading MARIADB_MAJOR through every File/@Source attribute.
set STAGE=dist\windows\staging-mdb%MARIADB_MAJOR%-%MSI_ARCH%
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%"

copy /Y "%DLL%"                "%STAGE%\fractalsql.dll"     > nul
REM The reasoning plugin ships with its detached Ed25519 signature; the plugin loads only with the .sig beside it.
for %%F in (fractalsql-reasoning-http.dll fractalsql-reasoning-http.dll.sig) do if not exist "include\windows-x86_64\%%F" (
    echo ==^> ERROR: include\windows-x86_64\%%F missing: re-run the vendored-artifact deploy step
    popd
    exit /b 1
)
copy /Y include\windows-x86_64\fractalsql-reasoning-http.dll     "%STAGE%\fractalsql-reasoning-http.dll"     > nul
copy /Y include\windows-x86_64\fractalsql-reasoning-http.dll.sig "%STAGE%\fractalsql-reasoning-http.dll.sig" > nul
copy /Y "%DAEMON%"             "%STAGE%\fractalsqld.exe"    > nul
copy /Y LICENSES\Apache-2.0.txt "%STAGE%\fractalsqld-LICENSE" > nul
copy /Y scripts\windows\fractalsqld-service.ps1 "%STAGE%\fractalsqld-service.ps1" > nul
copy /Y scripts\windows\provision-fractalsqld.ps1 "%STAGE%\provision-fractalsqld.ps1" > nul
copy /Y sql\install_udf.sql    "%STAGE%\install_udf.sql"    > nul
copy /Y LICENSES\GPL-2.0-only.txt "%STAGE%\LICENSE"  > nul
copy /Y GPL-SOURCE-OFFER.txt "%STAGE%\GPL-SOURCE-OFFER.txt" > nul
copy /Y THIRD-PARTY-NOTICES.md "%STAGE%\LICENSE-THIRD-PARTY" > nul

REM MCP server: the executable, its client library and the two lock files go into one folder (the server looks for
REM the locks beside itself); the README and manifest ride along as documentation.
copy /Y "%MCPDIST%\fractalsql-mariadb-mcp.exe"  "%STAGE%\fractalsql-mariadb-mcp.exe" > nul
copy /Y "%MCPDIST%\libmariadb.dll"              "%STAGE%\libmariadb.dll"              > nul
copy /Y mcp\.mcp-schema-lock                    "%STAGE%\.mcp-schema-lock"            > nul
copy /Y mcp\.mcp-safety-annotations-lock        "%STAGE%\.mcp-safety-annotations-lock" > nul
copy /Y mcp\README.md                           "%STAGE%\mcp-README.md"               > nul
copy /Y mcp\manifest.json                       "%STAGE%\mcp-manifest.json"           > nul

REM Per-cell README ships in the MSI so users who only grab the .msi
REM still see the "which MariaDB major, which arch" pairing without
REM hopping to GitHub.
(
  echo FractalSQL for MariaDB %MARIADB_MAJOR%, Community Edition %MSI_VERSION%
  echo Architecture: %MSI_ARCH%
  echo.
  echo This MSI installs the fractalsql UDF DLL into the canonical
  echo MariaDB Windows install root:
  echo     C:\Program Files\MariaDB %MARIADB_MAJOR%\lib\plugin\fractalsql.dll
  echo The daemon fractalsqld.exe is installed under
  echo     C:\Program Files\MariaDB %MARIADB_MAJOR%\fractalsqld\
  echo It must be running before mariadbd can serve any FractalSQL call.
  echo This installer generates its HMAC key, writes its config under
  echo C:\ProgramData\FractalSQL, and registers + starts the fractalsqld
  echo Windows service for you ^(provision-fractalsqld.ps1, run during
  echo install^). If that couldn't finish -- most commonly because the
  echo MariaDB service wasn't running yet during this install -- do it
  echo yourself ^(fractalsqld-service.ps1 is in the same folder as
  echo fractalsqld.exe^):
  echo     cd "C:\Program Files\MariaDB %MARIADB_MAJOR%\fractalsqld"
  echo     powershell -ExecutionPolicy Bypass -File provision-fractalsqld.ps1 ^
  echo         -FractalsqldExe fractalsqld.exe
  echo Or set up and register it fully by hand ^(socket_path, hmac_key_file,
  echo allowed_pipe_sid -- see service/README.md^):
  echo     powershell -ExecutionPolicy Bypass -File fractalsqld-service.ps1 ^
  echo         -Action install -Exe fractalsqld.exe -Config ^<path to your config^>
  echo After creating the key by hand, restrict its ACL or the daemon will
  echo refuse it ^(readable by Users/Everyone is rejected at startup^):
  echo     icacls C:\ProgramData\FractalSQL\hmac.key /inheritance:r /grant:r ^
  echo         "*S-1-5-18:F" "*S-1-5-32-544:F" "*S-1-5-19:R" "*^<MariaDB service SID^>:R"
  echo     Start-Service fractalsqld
  echo Or start it by hand with -c ^<config^> before mariadbd.
  echo.
  echo The MCP ^(Model Context Protocol^) server is installed under
  echo     C:\Program Files\MariaDB %MARIADB_MAJOR%\fractalsql-mcp\fractalsql-mariadb-mcp.exe
  echo with its schema and safety lock files in the same folder. See
  echo README.md there for usage.
  echo.
  echo After install, activate the UDFs once per server. Note the SONAME
  echo rewrite: MariaDB's UDF loader takes SONAME literally, so install_
  echo udf.sql's Linux 'fractalsql.so' name must go in as 'fractalsql.dll'
  echo on Windows ^(easy_install.ps1 does this same rewrite at pipe time^):
  echo     ^(Get-Content "C:\Program Files\MariaDB %MARIADB_MAJOR%\share\doc\fractalsql-mariadb\install_udf.sql" -Raw^) ^
  echo         -replace "SONAME 'fractalsql\.so'", "SONAME 'fractalsql.dll'" ^| ^
  echo         mysql -u root -p -D fractalsql
  echo     mysql -u root -p -e "SELECT fractal_edition^(^), fractal_version^(^);"
) > "%STAGE%\README.txt"

if not exist obj mkdir obj
REM candle preprocessor can't take a dotted major without escaping;
REM expose two sanitized variants:
REM   MAJOR_TAG   underscore-safe, used in WiX Ids and filenames
REM   MAJOR_HEX   4-digit hex-safe, padded, used inside GUID strings
REM                 which MUST be pure hex [0-9A-F].
set MAJOR_TAG=%MARIADB_MAJOR:.=_%
if "%MARIADB_MAJOR%"=="10.6"   set MAJOR_HEX=0A06
if "%MARIADB_MAJOR%"=="10.11"  set MAJOR_HEX=0A11
if "%MARIADB_MAJOR%"=="11.4"   set MAJOR_HEX=0B04
if "%MARIADB_MAJOR%"=="12.3"   set MAJOR_HEX=0C03
if "%MAJOR_HEX%"==""    (
    echo ==^> ERROR: no MAJOR_HEX mapping for MARIADB_MAJOR=%MARIADB_MAJOR%
    popd
    exit /b 1
)
set OBJ=obj\fractalsql-mdb%MAJOR_TAG%-%MSI_ARCH%.wixobj

set MSI=dist\windows\FractalSQL-MariaDB-%MARIADB_MAJOR%-%MSI_VERSION%-%MSI_ARCH%.msi
if not exist "dist\windows" mkdir "dist\windows"

set WXS=scripts\windows\fractalsql.wxs

echo ==^> MARIADB_MAJOR = %MARIADB_MAJOR%
echo ==^> MSI_ARCH      = %MSI_ARCH%
echo ==^> MSI_VERSION   = %MSI_VERSION%
echo ==^> STAGE         = %STAGE%
echo ==^> MSI           = %MSI%

REM -arch propagates into $(sys.BUILDARCH) inside the WXS, used there
REM to set <Package Platform="..."/> and keep ICE80 happy about the
REM component/directory bitness pairing.
REM
REM -dMARIADB_MAJOR / -dSTAGE_DIR / -dMSI_VERSION are consumed by the
REM preprocessor inside fractalsql.wxs (see <?define?> section).
candle -nologo -arch %MSI_ARCH% ^
    -dMARIADB_MAJOR=%MARIADB_MAJOR% ^
    -dMARIADB_MAJOR_TAG=%MAJOR_TAG% ^
    -dMARIADB_MAJOR_HEX=%MAJOR_HEX% ^
    -dSTAGE_DIR=%STAGE% ^
    -dMSI_VERSION=%MSI_VERSION% ^
    -out %OBJ% %WXS%
if errorlevel 1 (
    echo ==^> candle failed
    popd
    exit /b 1
)

light -nologo ^
      -ext WixUIExtension ^
      -ext WixUtilExtension ^
      -out "%MSI%" ^
      %OBJ%
if errorlevel 1 (
    echo ==^> light failed
    popd
    exit /b 1
)

echo ==^> Built %MSI%
dir "%MSI%"

popd
endlocal
