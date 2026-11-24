@echo off
REM Launcher for the MCP server inside the MSI's fractalsql-mcp\ folder.
REM
REM The MSI does not ship libmariadb.dll. MariaDB Connector/C (LGPL-2.1-or-later)
REM is an install prerequisite, exactly like libmariadb3 is a package dependency
REM on Linux: the connector travels with the machine, not with our package. The
REM server links libmariadb.dll by name, so this script puts the installed
REM connector's lib directory on PATH for this process only and starts the
REM executable with the caller's arguments.
REM
REM Resolution order:
REM   1. MARIADB_CONNECTOR_HOME (set it when the connector lives outside its
REM      installer's default location; both a ...\<dir> and a ...\<dir>\lib
REM      layout are accepted),
REM   2. the Connector/C installer's default location (C:\Program Files\MariaDB\
REM      MariaDB Connector C).

setlocal
set "EXEDIR=%~dp0"
if not exist "%EXEDIR%fractalsql-mariadb-mcp.exe" (
    echo fractalsql-mcp.cmd: fractalsql-mariadb-mcp.exe not found beside this script. 1>&2
    exit /b 1
)

set "CONNECTOR=%MARIADB_CONNECTOR_HOME%"
if "%CONNECTOR%"=="" set "CONNECTOR=%ProgramFiles%\MariaDB\MariaDB Connector C"
if exist "%CONNECTOR%\libmariadb.dll" goto run
if exist "%CONNECTOR%\lib\libmariadb.dll" set "CONNECTOR=%CONNECTOR%\lib"
if exist "%CONNECTOR%\libmariadb.dll" goto run

echo fractalsql-mcp.cmd: libmariadb.dll not found. 1>&2
echo   The MCP server needs MariaDB Connector/C installed first. 1>&2
echo   Install it from https://mariadb.com/downloads/connectors/ or with 1>&2
echo   choco install mariadb-connector-c, or set MARIADB_CONNECTOR_HOME 1>&2
echo   to an existing Connector/C directory. Last location checked: 1>&2
echo   %CONNECTOR% 1>&2
exit /b 1

:run
set "PATH=%CONNECTOR%;%PATH%"
"%EXEDIR%fractalsql-mariadb-mcp.exe" %*
