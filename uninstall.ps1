#Requires -Version 5.1
# Remove devin-rc (any OS). Keeps your saved config unless -Purge is given.
param([string]$Prefix = '', [switch]$Purge)
$IsWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool](Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $Prefix) { $Prefix = if ($IsWin) { Join-Path $env:LOCALAPPDATA 'devin-rc' } else { Join-Path $HOME '.local' } }
$bin = Join-Path $Prefix 'bin'
if ($IsWin) {
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $new = (@($user -split ';' | Where-Object { $_ -and $_ -ne $bin })) -join ';'
    if ($new -ne $user) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
}
if ($IsWin) { Remove-Item -Recurse -Force $Prefix -ErrorAction SilentlyContinue }
else { Remove-Item -Force (Join-Path $bin 'devin-rc'), (Join-Path $bin 'devin-rc.ps1') -ErrorAction SilentlyContinue }
if ($Purge) {
    $cfgDir = if ($env:DEVIN_RC_HOME) { $env:DEVIN_RC_HOME }
        elseif ($IsWin) { Join-Path $env:APPDATA 'devin-rc' }
        else { Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'devin-rc' }
    Remove-Item -Recurse -Force $cfgDir -ErrorAction SilentlyContinue
}
Write-Host "devin-rc removed."
