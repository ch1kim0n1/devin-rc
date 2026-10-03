#Requires -Version 5.1
# Remove devin-rc (Windows). Keeps your saved config unless -Purge is given.
param([string]$Prefix = (Join-Path $env:LOCALAPPDATA 'devin-rc'), [switch]$Purge)
$bin = Join-Path $Prefix 'bin'
$user = [Environment]::GetEnvironmentVariable('Path', 'User')
$new = (@($user -split ';' | Where-Object { $_ -and $_ -ne $bin })) -join ';'
if ($new -ne $user) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
Remove-Item -Recurse -Force $Prefix -ErrorAction SilentlyContinue
if ($Purge) { Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'devin-rc') -ErrorAction SilentlyContinue }
Write-Host "devin-rc removed."
