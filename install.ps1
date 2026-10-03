#Requires -Version 5.1
# Install devin-rc (cross-platform: Windows via PowerShell 5.1/7, Linux/macOS via pwsh 7).
# Windows: copies the script to a per-user folder, adds a cmd/PowerShell shim (devin-rc.cmd) and a Git Bash
#   shim (devin-rc), and puts the folder on the USER PATH (no admin). Use -NoPath to skip the PATH change.
# Linux/macOS: installs a devin-rc shim in ~/.local/bin that runs the .ps1 through pwsh (no admin).
param([string]$Prefix = '', [switch]$NoPath)
$ErrorActionPreference = 'Stop'
$IsWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool](Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $Prefix) { $Prefix = if ($IsWin) { Join-Path $env:LOCALAPPDATA 'devin-rc' } else { Join-Path $HOME '.local' } }
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $Prefix 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
Copy-Item (Join-Path $src 'devin-rc.ps1') (Join-Path $bin 'devin-rc.ps1') -Force

if ($IsWin) {
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
} else {
    # POSIX shim: run the .ps1 through pwsh
    $shim = Join-Path $bin 'devin-rc'
    $ps1  = Join-Path $bin 'devin-rc.ps1'
    [IO.File]::WriteAllText($shim, "#!/bin/sh`nexec pwsh -NoProfile -File ""$ps1"" ""`$@""`n", (New-Object Text.UTF8Encoding($false)))
    & chmod +x $shim
    Write-Host "Installed: $shim (runs via pwsh)"
    if (-not $NoPath -and (($env:PATH -split ':') -notcontains $bin)) {
        Write-Host "Add to PATH: export PATH=`"${bin}:`$PATH`""
    }
    Write-Host "`nNext:`n  Main PC: devin-rc setup-host`n  Laptop:  devin-rc pair user@HOST; devin-rc connect"
}
