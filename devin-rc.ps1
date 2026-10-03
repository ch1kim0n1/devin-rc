#Requires -Version 5.1
# devin-rc for Windows (PowerShell 5.1 and 7). Same commands as the bash version.
#   Client (laptop): pair / connect / status / ls use the built-in OpenSSH client (ssh.exe) and Tailscale for Windows.
#   Host (main PC): start / bg / stop / setup-host run Devin inside tmux in WSL2 (tmux has no native Windows build).
$ErrorActionPreference = 'Continue'  # native stderr is expected (ssh/wsl failures are handled explicitly via exit codes)
$App = 'devin-rc'
$Version = '1.3.0'
$SessionDefault = 'devin'
$ConfigDir = if ($env:DEVIN_RC_HOME) { $env:DEVIN_RC_HOME } else { Join-Path $env:APPDATA 'devin-rc' }
$ConfigFile = Join-Path $ConfigDir 'config.json'
$SshOpts = @('-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2')

function Red($m)    { Write-Host $m -ForegroundColor Red }
function Green($m)  { Write-Host $m -ForegroundColor Green }
function Yellow($m) { Write-Host $m -ForegroundColor Yellow }
function Die($m)    { Red "Error: $m"; exit 1 }
function Exists($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

# ---- config (JSON: remote, session, devin, distro, remote_mode, remote_distro). Environment variables win over the file.
function Load-Config {
    $c = @{ remote = ''; session = $SessionDefault; devin = 'devin'; distro = ''; remote_mode = 'posix'; remote_distro = '' }
    if (Test-Path $ConfigFile) {
        $j = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in @($c.Keys)) { if ($j.PSObject.Properties[$k] -and $j.$k) { $c[$k] = [string]$j.$k } }
    }
    if ($env:DEVIN_CMD) { $c.devin = $env:DEVIN_CMD }
    if ($env:SESSION) { $c.session = $env:SESSION }
    if ($env:DEVIN_RC_DISTRO) { $c.distro = $env:DEVIN_RC_DISTRO }
    return $c
}
function Save-Config {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $script:cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
}

# tmux forbids ':' and '.' in session names; the safe charset also keeps the remote ssh command quoting-trivial.
function Test-Session { if ($script:cfg.session -notmatch '^[a-zA-Z0-9_-]+$') { Die "Invalid session name '$($script:cfg.session)' (allowed: letters, digits, - and _)" } }

# ---- WSL helpers (host side)
function Wsl-Args { if ($script:cfg.distro) { return @('-d', $script:cfg.distro) } else { return @() } }
function Wsl-Run { param([string[]]$Cmd) & wsl.exe @(Wsl-Args) -e @Cmd }          # exec without a shell
function Wsl-RunAt { param([string]$Dir, [string[]]$Cmd) & wsl.exe @(Wsl-Args) '--cd' $Dir '-e' @Cmd }  # same, starting in Dir
function Wsl-Ok  { param([string[]]$Cmd) & wsl.exe @(Wsl-Args) -e @Cmd *> $null; return ($LASTEXITCODE -eq 0) }
function Need-Wsl {
    if (-not (Exists 'wsl.exe')) { Die "WSL is required to host Devin on Windows (tmux has no native build). Run: wsl --install" }
    if (-not (Wsl-Ok @('true'))) { Die "The WSL distro could not start. Check 'wsl -l -v'; reinstall or repair it, or set DEVIN_RC_DISTRO to a working distro." }
}
function Need-Tmux { Need-Wsl; if (-not (Wsl-Ok @('tmux', '-V'))) { Die "tmux is missing inside WSL. Run: devin-rc setup-host" } }
function Need-Devin {
    $bin = ($script:cfg.devin -split '\s+')[0]
    if (-not (Wsl-Ok @('bash', '-lc', "command -v $bin"))) { Die "'$bin' was not found inside WSL (Devin must run in the same Linux environment as tmux). Install the Linux Devin CLI in WSL: curl -fsSL https://cli.devin.ai/install.sh | bash" }
}
function Local-Running { return ((Exists 'wsl.exe') -and (Wsl-Ok @('tmux', 'has-session', '-t', $script:cfg.session))) }

# ---- commands
function Host-Setup {
    Need-Wsl
    if (-not (Wsl-Ok @('tmux', '-V'))) {
        Yellow "Installing tmux in WSL (apt, as root inside the distro)..."
        & wsl.exe @(Wsl-Args) -u root -e bash -lc 'apt-get update -qq && apt-get install -y tmux'
        if ($LASTEXITCODE -ne 0) { Die "Could not install tmux in WSL. Install it manually inside the distro." }
    }
    Need-Devin
    $ts = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if (-not $ts) { $p = "$env:ProgramFiles\Tailscale\tailscale.exe"; if (Test-Path $p) { $ts = $p } }
    if (-not $ts) { Die "Install Tailscale for Windows and sign in first: https://tailscale.com/download" }
    $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
    if (-not $ip) { Die "Tailscale is installed but not connected. Open Tailscale and sign in." }
    $remote = "$env:USERNAME@$ip"
    $script:cfg.remote = $remote; Save-Config
    Green "Host checks passed (WSL, tmux, Devin, Tailscale)."
    Yellow "Tailscale SSH can host only on Linux and macOS, so a Windows host needs the OpenSSH Server. This script does not change system settings. In an elevated PowerShell:"
    Write-Host "  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
    Write-Host "  Set-Service sshd -StartupType Automatic; Start-Service sshd"
    Write-Host "  New-NetFirewallRule -Name sshd-tailscale -DisplayName 'OpenSSH via Tailscale' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow"
    Write-Host ""
    Write-Host "On the laptop, install devin-rc and run:"
    Write-Host "  devin-rc pair $remote --wsl"
    Write-Host "  devin-rc connect"
}

function Pair-Client {
    $target = $null; $wsl = $false; $distro = ''
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = $args[$i]
        if ($a -eq '--wsl') { $wsl = $true }
        elseif ($a -eq '--distro') {
            $i++
            if ($i -ge $args.Count -or $args[$i] -like '-*') { Die "--distro requires a name" }
            $distro = $args[$i]
        }
        elseif ($a -like '--distro=*') { $distro = $a.Substring(9) }
        elseif ($a -like '-*') { Die "Unknown flag '$a' for pair" }
        elseif (-not $target) { $target = $a }
        else { Die "Usage: devin-rc pair user@HOST [--wsl] [--distro NAME]" }
    }
    if (-not $target -or $target -match '\s') { Die "Usage: devin-rc pair user@HOST [--wsl] [--distro NAME]   (--wsl when the host is a Windows PC running Devin in WSL)" }
    if ($distro -and $distro -notmatch '^[a-zA-Z0-9_.-]+$') { Die "Invalid distro name '$distro'" }
    $script:cfg.remote = $target
    $script:cfg.remote_mode = $(if ($wsl) { 'wsl' } else { 'posix' })
    $script:cfg.remote_distro = $distro
    Save-Config
    Green "Saved remote: $target ($($script:cfg.remote_mode) host$(if ($distro) { ", distro $distro" }))"
}

function Start-Devin {
    param([switch]$Background, [string]$Project)
    Need-Tmux; Need-Devin
    if (-not $Project) { $Project = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) { Die "Project directory does not exist: $Project" }
    $s = $script:cfg.session
    if (Local-Running) {
        if ($Background) { Green "Devin session '$s' is already running."; return }
        Green "Attaching to existing Devin session '$s'."
        Wsl-Run @('tmux', 'attach-session', '-t', $s); exit $LASTEXITCODE
    }
    # wsl --cd takes the Windows path and sets the new session's working
    # directory, so tmux needs no -c and no wslpath round-trip (which would
    # break on paths with spaces on WSL versions that re-split -e arguments).
    $full = (Resolve-Path -LiteralPath $Project).Path
    if ($Background) {
        Wsl-RunAt $full @('tmux', 'new-session', '-d', '-s', $s, $script:cfg.devin)
        if ($LASTEXITCODE -ne 0) { Die "tmux could not start the session." }
        Green "Started Devin session '$s' in background at $full"; return
    }
    Green "Starting Devin in persistent session '$s' at $full"
    Wsl-RunAt $full @('tmux', 'new-session', '-s', $s, $script:cfg.devin); exit $LASTEXITCODE
}

# Remote command: a POSIX host gets the same tmux one-liner as the bash version; a Windows (WSL) host gets a cmd.exe line.
# The remote host's distro (remote_distro) is used, not the local one (distro).
function Remote-Attach-Cmd {
    $s = $script:cfg.session; $d = $(if ($script:cfg.remote_distro) { "-d $($script:cfg.remote_distro) " } else { '' })
    if ($script:cfg.remote_mode -eq 'wsl') {
        return "wsl.exe ${d}-e tmux has-session -t $s 2>nul && wsl.exe ${d}-e tmux attach-session -t $s || echo Devin RC session is not running. On the main PC run: devin-rc start <project>"
    }
    return "command -v tmux >/dev/null || { echo 'tmux missing on host'; exit 1; }; tmux has-session -t '$s' 2>/dev/null || { echo 'Devin RC session is not running. On the main PC run: devin-rc start <project>'; exit 2; }; exec tmux attach-session -t '$s'"
}
function Remote-State-Cmd {
    $s = $script:cfg.session; $d = $(if ($script:cfg.remote_distro) { "-d $($script:cfg.remote_distro) " } else { '' })
    if ($script:cfg.remote_mode -eq 'wsl') { return "wsl.exe ${d}-e tmux has-session -t $s 2>nul && echo RUNNING || echo STOPPED" }
    return "if command -v tmux >/dev/null && tmux has-session -t '$s' 2>/dev/null; then echo RUNNING; else echo STOPPED; fi"
}

function Connect-Remote {
    $target = $(if ($args[0]) { $args[0] } else { $script:cfg.remote })
    if (-not $target) { Die "No main PC paired. Run: devin-rc pair user@HOST" }
    if (-not (Exists 'ssh.exe')) { Die "The OpenSSH client is required (Settings > Optional features > OpenSSH Client)." }
    Green "Connecting to $target -> tmux session '$($script:cfg.session)'"
    & ssh.exe -t @SshOpts $target (Remote-Attach-Cmd); exit $LASTEXITCODE
}

function Show-Status {
    $s = $script:cfg.session
    if (Local-Running) { Green "LOCAL  RUNNING   session=$s" } else { Write-Host "LOCAL  STOPPED   session=$s" }
    if ($script:cfg.remote) {
        if (-not (Exists 'ssh.exe')) { Write-Host "REMOTE UNKNOWN   host=$($script:cfg.remote) (no ssh client)"; return }
        $out = (& ssh.exe @SshOpts -o BatchMode=yes $script:cfg.remote (Remote-State-Cmd) 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $out) { Write-Host ("REMOTE {0,-9} host={1} session={2}" -f $out, $script:cfg.remote, $s) }
        else { Write-Host "REMOTE UNREACHABLE host=$($script:cfg.remote)" }
    }
}

function Stop-Local {
    Need-Tmux
    if (Local-Running) { Wsl-Run @('tmux', 'kill-session', '-t', $script:cfg.session); Green "Stopped session '$($script:cfg.session)'." }
    else { Write-Host "Session $($script:cfg.session) is not running." }
}

function List-Sessions {
    Write-Host '-- local (WSL) --'
    if (Exists 'wsl.exe') {
        # capture first: a broken distro prints errors on stdout, which '2>$null' can't hide
        $lsOut = Wsl-Run @('tmux', 'ls') 2>$null | Out-String
        if ($LASTEXITCODE -eq 0 -and $lsOut) { $lsOut.TrimEnd() } else { Write-Host '(none)' }
    } else { Write-Host 'WSL not installed' }
    if ($script:cfg.remote) {
        Write-Host "-- $($script:cfg.remote) --"
        if (Exists 'ssh.exe') {
            $d = $(if ($script:cfg.remote_distro) { "-d $($script:cfg.remote_distro) " } else { '' })
            $cmd = $(if ($script:cfg.remote_mode -eq 'wsl') { "wsl.exe ${d}-e tmux ls" } else { 'command -v tmux >/dev/null && tmux ls 2>/dev/null || true' })
            & ssh.exe @SshOpts -o BatchMode=yes $script:cfg.remote $cmd
            if ($LASTEXITCODE -ne 0) { Write-Host '(unreachable)' }
        } else { Write-Host '(no ssh client)' }
    }
}

function Show-Info {
    Write-Host "session: $($script:cfg.session)"
    Write-Host "remote:  $(if ($script:cfg.remote) { "$($script:cfg.remote) ($($script:cfg.remote_mode) host$(if ($script:cfg.remote_distro) { ", distro $($script:cfg.remote_distro)" }))" } else { '<not paired>' })"
    Write-Host "devin:   $($script:cfg.devin)"
    Write-Host "distro:  $(if ($script:cfg.distro) { $script:cfg.distro } else { '<default>' })"
    Write-Host "config:  $ConfigFile"
    Write-Host "version: $Version"
}

function Show-Usage {
@'
devin-rc (Windows) - persistent remote control for Devin CLI

MAIN PC (Windows: Devin runs in tmux inside WSL2)
  devin-rc setup-host           Check WSL, tmux, Devin, Tailscale; print the OpenSSH Server steps
  devin-rc start [project]      Start Devin or attach to the existing session
  devin-rc bg [project]         Start Devin detached
  devin-rc status               Show local + remote session status
  devin-rc stop                 Stop the local Devin session

LAPTOP
  devin-rc pair user@HOST [--wsl] [--distro NAME]
                                   Save the main PC's Tailscale address (HOST alone uses your local
                                   username; --wsl: the host is a Windows PC using WSL; --distro: its
                                   WSL distro name)
  devin-rc connect [user@HOST]     Attach to the exact persistent Devin terminal

OTHER
  devin-rc ls | info | version | help

OPTIONS (before the command)
  -s, --session NAME            Use session NAME (default: devin); letters, digits, - and _ only
Environment: DEVIN_CMD (may include arguments), DEVIN_RC_DISTRO (WSL distro), DEVIN_RC_HOME (config directory)
Detach without stopping Devin: Ctrl-b, then d
'@ | Write-Host
}

# ---- main
$script:cfg = Load-Config
$rest = @($args)
while ($rest.Count -gt 0 -and $rest[0] -like '-*') {
    switch -Regex ($rest[0]) {
        '^(-s|--session)$' { if ($rest.Count -lt 2 -or $rest[1] -like '-*') { Die "$($rest[0]) requires a session name" }; $script:cfg.session = $rest[1]; $rest = @($rest | Select-Object -Skip 2) }
        '^(-V|--version)$' { Write-Host "$App $Version"; exit 0 }
        '^(-h|--help)$'    { Show-Usage; exit 0 }
        default            { Die "Unknown flag '$($rest[0])'. Run: devin-rc help" }
    }
}
Test-Session
$cmd = $(if ($rest.Count -gt 0) { $rest[0] } else { 'help' })
$tail = @($rest | Select-Object -Skip 1)
switch ($cmd) {
    'setup-host' { Host-Setup }
    'pair'       { Pair-Client @tail }
    'start'      { Start-Devin -Project $tail[0] }
    { $_ -in 'bg', 'background' } { Start-Devin -Background -Project $tail[0] }
    { $_ -in 'connect', 'c' }     { Connect-Remote @tail }
    'status'     { Show-Status }
    'stop'       { Stop-Local }
    { $_ -in 'ls', 'sessions' }   { List-Sessions }
    'info'       { Show-Info }
    'version'    { Write-Host "$App $Version" }
    'help'       { Show-Usage }
    default      { Die "Unknown command '$cmd'. Run: devin-rc help" }
}
