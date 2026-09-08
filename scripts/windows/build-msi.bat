@echo off
REM scripts/windows/build-msi.bat
REM
REM Packages fractalsql.dll (pre-built by build.bat) plus the install
REM SQL and LICENSE files into a Windows MSI using the WiX Toolset.
REM
REM One MSI per (MariaDB major, arch) pair. The resulting MSI installs
REM into the target server's on-disk layout:
REM
REM     C:\Program Files\MariaDB ^<MARIADB_MAJOR^>\lib\plugin\fractalsql.dll
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
REM
REM Environment
REM   MARIADB_MAJOR 10.6 ^| 10.11 ^| 11.4 ^| 12.3: selects UpgradeCode and install-folder name
REM   MSI_ARCH      x64 ^| arm64: passed to candle -arch
REM   MSI_VERSION   overrides Product Version (default 2.0.0, read from src\fractalsql.c's FSQL_VERSION if not set)

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
if not exist "%DLL%" (
    echo ==^> ERROR: %DLL% missing: run build.bat with MARIADB_MAJOR=%MARIADB_MAJOR% first
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
copy /Y sql\install_udf.sql    "%STAGE%\install_udf.sql"    > nul
copy /Y LICENSE                "%STAGE%\LICENSE"            > nul
copy /Y THIRD-PARTY-NOTICES.md "%STAGE%\LICENSE-THIRD-PARTY" > nul

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
  echo.
  echo After install, activate the UDFs once per server:
  echo     mysql -u root -p ^< "C:\Program Files\MariaDB %MARIADB_MAJOR%\share\doc\fractalsql-mariadb\install_udf.sql"
  echo     mysql -u root -p -e "SELECT fractalsql_edition^(^), fractalsql_version^(^);"
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
