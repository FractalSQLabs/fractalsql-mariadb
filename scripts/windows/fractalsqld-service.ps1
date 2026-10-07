<#
.SYNOPSIS
Installs or removes the fractalsqld Windows service.

.DESCRIPTION
fractalsqld.exe runs as a service with --service, reading its config from
-c. Set allowed_pipe_sid in that config to the SID of the account mariadbd
runs as before starting the service: the pipe DACL and the per-connection
check both use that list. By default the service runs as the account the
daemon's own process is started under when no list is set.

.PARAMETER Action
install or uninstall.

.PARAMETER Exe
Path to fractalsqld.exe (install only).

.PARAMETER Config
Path to the daemon config file (install only).

.PARAMETER Account
Service account. Defaults to NT AUTHORITY\LocalService. A built-in account
needs no password.

.EXAMPLE
.\fractalsqld-service.ps1 -Action install -Exe 'C:\Program Files\MariaDB 11.4\fractalsqld\fractalsqld.exe' -Config 'C:\ProgramData\FractalSQL\fractalsqld.conf'
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('install', 'uninstall')][string]$Action,
    [string]$Exe = "",
    [string]$Config = "",
    [string]$Account = 'NT AUTHORITY\LocalService'
)

$ErrorActionPreference = 'Stop'
$Name = 'fractalsqld'

if ($Action -eq 'install') {
    if (-not (Test-Path -LiteralPath $Exe)) { throw "fractalsqld.exe not found: $Exe" }
    if (-not (Test-Path -LiteralPath $Config)) { throw "config not found: $Config" }
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) { throw "service '$Name' already exists: run -Action uninstall first" }

    $binPath = "`"$Exe`" --service -c `"$Config`""
    New-Service -Name $Name -BinaryPathName $binPath -DisplayName 'FractalSQL daemon' `
        -Description 'Serves the FractalSQL shim (fractalsql.dll) for MariaDB over a named pipe.' `
        -StartupType Automatic | Out-Null

    # Built-in accounts take no password, and the account name has a space
    # in it, so set it through the registry rather than sc.exe's argv.
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name ObjectName -Value $Account

    # Restart after a crash: 5 s, 5 s, 30 s; reset the count after one day.
    & sc.exe failure $Name reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null

    Write-Host "Installed service '$Name' as $Account."
    Write-Host "Set allowed_pipe_sid in $Config to the mariadbd account's SID, then: Start-Service $Name"
} else {
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Remove-Service -Name $Name
        Write-Host "Removed service '$Name'."
    } else {
        Write-Host "Service '$Name' is not installed."
    }
}
