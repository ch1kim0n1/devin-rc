#Requires -Version 5.1
# Install devin-rc on Windows: copies the script to a per-user folder, adds a cmd/PowerShell shim (devin-rc.cmd) and a Git Bash shim (devin-rc),
# and puts the folder on the USER PATH (no admin rights needed). Use -NoPath to skip the PATH change.
param([string]$Prefix = (Join-Path $env:LOCALAPPDATA 'devin-rc'), [switch]$NoPath)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $Prefix 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item (Join-Path $src 'devin-rc.ps1') (Join-Path $bin 'devin-rc.ps1') -Force

# cmd.exe / PowerShell shim: prefer PowerShell 7 when present, fall back to Windows PowerShell
@'
@echo off
where pwsh >nul 2>nul && (pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0devin-rc.ps1" %*) || (powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0devin-rc.ps1" %*)
exit /b %ERRORLEVEL%
'@ | Set-Content -Path (Join-Path $bin 'devin-rc.cmd') -Encoding ASCII

# Git Bash shim (no extension, LF endings)
$sh = "#!/usr/bin/env bash`nexec powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""`$(cygpath -w ""`$(dirname ""`$0"")/devin-rc.ps1"")"" ""`$@""`n"
[IO.File]::WriteAllText((Join-Path $bin 'devin-rc'), $sh, (New-Object Text.UTF8Encoding($false)))

if (-not $NoPath) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($user -split ';' | Where-Object { $_ })
    if ($parts -notcontains $bin) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $bin) -join ';'), 'User')
        Write-Host "Added to your user PATH: $bin (open a new terminal)"
    }
}
Write-Host "Installed: $bin\devin-rc.ps1"
Write-Host "`nNext:`n  Main PC (Windows + WSL): devin-rc setup-host`n  Laptop:                  devin-rc pair user@HOST [--wsl]; devin-rc connect"
