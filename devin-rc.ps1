#Requires -Version 5.1
# devin-rc — cross-platform: Windows (PowerShell 5.1/7), Linux and macOS (pwsh 7+). Same commands as the bash version.
#   Client: pair / connect / status / ls / ui use the OpenSSH client (ssh.exe on Windows, ssh elsewhere) over Tailscale.
#   Host:   start / bg / stop / setup-host run Devin inside tmux — natively on Linux/macOS, inside WSL2 on Windows.
$ErrorActionPreference = 'Continue'  # native stderr is expected (ssh/wsl failures are handled explicitly via exit codes)
$App = 'devin-rc'
$Version = '1.5.0'
$SessionDefault = 'devin'
# PS 5.1 (Desktop) is Windows-only; PS7 defines $IsWindows/$IsLinux/$IsMacOS.
$IsWin  = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool](Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue)
$SshExe = if ($IsWin) { 'ssh.exe' } else { 'ssh' }
$ConfigDir = if ($env:DEVIN_RC_HOME) { $env:DEVIN_RC_HOME }
    elseif ($IsWin) { Join-Path $env:APPDATA 'devin-rc' }
    else { Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'devin-rc' }
$ConfigFile = Join-Path $ConfigDir 'config.json'
$SshOpts = @('-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2')

function Red($m)    { Write-Host $m -ForegroundColor Red }
function Green($m)  { Write-Host $m -ForegroundColor Green }
function Yellow($m) { Write-Host $m -ForegroundColor Yellow }
function Die($m)    { Red "Error: $m"; if ($script:InUi) { throw 'devin-rc error' } else { exit 1 } }
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

# ---- host-side tmux helpers: on Windows tmux lives inside WSL; on Linux/macOS it is native.
function Wsl-Args { if ($script:cfg.distro) { return @('-d', $script:cfg.distro) } else { return @() } }
function Wsl-Run { param([string[]]$Cmd) & wsl.exe @(Wsl-Args) -e @Cmd }          # exec without a shell
function Wsl-RunAt { param([string]$Dir, [string[]]$Cmd) & wsl.exe @(Wsl-Args) '--cd' $Dir '-e' @Cmd }  # same, starting in Dir
function Wsl-Ok  { param([string[]]$Cmd) & wsl.exe @(Wsl-Args) -e @Cmd *> $null; return ($LASTEXITCODE -eq 0) }
# Tmux-* take a command argv starting with 'tmux' and run it in the right place for this OS.
function Tmux-Run { param([string[]]$Cmd) if ($IsWin) { Wsl-Run $Cmd } else { & $Cmd[0] @($Cmd | Select-Object -Skip 1) } }
function Tmux-Ok  { param([string[]]$Cmd) if ($IsWin) { return (Wsl-Ok $Cmd) } & $Cmd[0] @($Cmd | Select-Object -Skip 1) *> $null; return ($LASTEXITCODE -eq 0) }
function Need-Tmux {
    if ($IsWin) {
        if (-not (Exists 'wsl.exe')) { Die "WSL is required to host Devin on Windows (tmux has no native build). Run: wsl --install" }
        if (-not (Wsl-Ok @('true'))) { Die "The WSL distro could not start. Check 'wsl -l -v'; reinstall or repair it, or set DEVIN_RC_DISTRO to a working distro." }
        if (-not (Wsl-Ok @('tmux', '-V'))) { Die "tmux is missing inside WSL. Run: devin-rc setup-host" }
    } elseif (-not (Exists 'tmux')) { Die "tmux is required. Run 'devin-rc setup-host' or install it (apt/dnf/brew install tmux)." }
}
function Need-Devin {
    $bin = ($script:cfg.devin -split '\s+')[0]
    if ($IsWin) {
        if (-not (Wsl-Ok @('bash', '-lc', "command -v $bin"))) { Die "'$bin' was not found inside WSL (Devin must run in the same Linux environment as tmux). Install the Linux Devin CLI in WSL: curl -fsSL https://cli.devin.ai/install.sh | bash" }
    } elseif (-not (Exists $bin)) { Die "'$bin' not found. Install Devin CLI: curl -fsSL https://cli.devin.ai/install.sh | bash" }
}
function Local-Running {
    if ($IsWin) { return ((Exists 'wsl.exe') -and (Wsl-Ok @('tmux', 'has-session', '-t', $script:cfg.session))) }
    return ((Exists 'tmux') -and (Tmux-Ok @('tmux', 'has-session', '-t', $script:cfg.session)))
}

# ---- commands
function Host-Setup {
    if (-not $IsWin) {
        # POSIX host: native tmux + Devin + Tailscale SSH (same flow as the bash port)
        if (-not (Exists 'tmux')) {
            if (Exists 'brew') { Yellow 'Installing tmux with brew...'; & brew install tmux }
            elseif (Exists 'apt-get') { Yellow 'Installing tmux with apt...'; & sudo apt-get update -qq; & sudo apt-get install -y tmux }
            elseif (Exists 'dnf') { & sudo dnf install -y tmux }
            elseif (Exists 'pacman') { & sudo pacman -S --noconfirm tmux }
            else { Die 'tmux is required and no supported package manager was found.' }
        }
        if (-not (Exists 'tailscale')) { Die 'Install Tailscale and sign in first: https://tailscale.com/download' }
        Need-Devin
        & tailscale status *> $null
        if ($LASTEXITCODE -ne 0) { Die "Tailscale is installed but not connected. Run 'sudo tailscale up' and sign in." }
        Yellow 'Enabling Tailscale SSH on this machine...'
        & sudo tailscale set --ssh
        if ($LASTEXITCODE -ne 0) { Die "Could not enable Tailscale SSH. On macOS use the standalone Tailscale (tailscale.com/download/macos or 'brew install tailscale'), not the App Store build." }
        $ip = (& tailscale ip -4 2>$null | Select-Object -First 1)
        $user = (& id -un 2>$null); if (-not $user) { $user = $env:USER }
        if (-not $ip) { Die "Could not determine this machine's Tailscale IP." }
        $remote = "$user@$ip"; $script:cfg.remote = $remote; Save-Config
        Green 'Host ready.'
        Write-Host ''; Write-Host 'On your laptop, install devin-rc and run:'
        Write-Host "  devin-rc pair $remote"; Write-Host '  devin-rc connect'; return
    }
    if (-not (Exists 'wsl.exe')) { Die "WSL is required to host Devin on Windows (tmux has no native build). Run: wsl --install" }
    if (-not (Wsl-Ok @('true'))) { Die "The WSL distro could not start. Check 'wsl -l -v'; reinstall or repair it, or set DEVIN_RC_DISTRO to a working distro." }
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
        Tmux-Run @('tmux', 'attach-session', '-t', $s); if (-not $script:InUi) { exit $LASTEXITCODE }
        return
    }
    # wsl --cd takes the Windows path and sets the new session's working
    # directory, so tmux needs no -c and no wslpath round-trip (which would
    # break on paths with spaces on WSL versions that re-split -e arguments).
    $full = (Resolve-Path -LiteralPath $Project).Path
    if ($Background) {
        if ($IsWin) { Wsl-RunAt $full @('tmux', 'new-session', '-d', '-s', $s, $script:cfg.devin) }
        else { & tmux new-session -d -s $s -c $full $script:cfg.devin }
        if ($LASTEXITCODE -ne 0) { Die "tmux could not start the session." }
        Green "Started Devin session '$s' in background at $full"; return
    }
    Green "Starting Devin in persistent session '$s' at $full"
    if ($IsWin) { Wsl-RunAt $full @('tmux', 'new-session', '-s', $s, $script:cfg.devin) }
    else { & tmux new-session -s $s -c $full $script:cfg.devin }
    if (-not $script:InUi) { exit $LASTEXITCODE }
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
    if (-not (Exists $SshExe)) { Die "An OpenSSH client is required$(if ($IsWin) { ' (Settings > Optional features > OpenSSH Client)' } else { ' (install openssh-client)' })." }
    Green "Connecting to $target -> tmux session '$($script:cfg.session)'"
    & $SshExe -t @SshOpts $target (Remote-Attach-Cmd); if (-not $script:InUi) { exit $LASTEXITCODE }
}

function Show-UiHelp {
@'
Slash commands:
  /status              local + remote session status
  /ls                  list local + remote tmux sessions
  /connect [host]      attach to the remote Devin terminal (detach returns here)
  /start [dir]         start or attach to the local session
  /bg [dir]            start the local session detached
  /stop                stop the local session
  /pair TGT [--wsl] [--distro NAME]
  /session NAME        switch active session (letters, digits, -, _)
  /info                show saved config
  /iphone              iPhone connect instructions
  /quit                exit (also: q, exit, Ctrl-C)
'@ | Write-Host
}

function Interactive-Ui {
    Write-Host "$App $Version - interactive shell. /help for commands, /quit to exit."
    $script:InUi = $true
    while ($true) {
        $line = Read-Host "devin-rc:$($script:cfg.session)"
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = @($line.TrimStart('/') -split '\s+')
        try {
            switch ($parts[0]) {
                { $_ -in 'help', 'h', '?' }       { Show-UiHelp }
                { $_ -in 'quit', 'q', 'exit' }    { Write-Host 'bye'; return }
                'status'                          { Show-Status }
                { $_ -in 'ls', 'sessions' }       { List-Sessions }
                'info'                            { Show-Info }
                { $_ -in 'session', 'use' } {
                    if ($parts.Count -gt 1) {
                        if ($parts[1] -notmatch '^[a-zA-Z0-9_-]+$') { Red "Invalid session name '$($parts[1])' (allowed: letters, digits, - and _)" }
                        else { $script:cfg.session = $parts[1] }
                    } else { Write-Host "session: $($script:cfg.session)" }
                }
                { $_ -in 'connect', 'c' }         { Connect-Remote $parts[1] }
                'start'                           { Start-Devin -Project $parts[1] }
                { $_ -in 'bg', 'background' }     { Start-Devin -Background -Project $parts[1] }
                'stop'                            { Stop-Local }
                'pair'                            { Pair-Client @($parts | Select-Object -Skip 1) }
                { $_ -in 'iphone', 'ios', 'mobile' } { Iphone-Help }
                'version'                         { Write-Host "$App $Version" }
                default                           { Write-Host "unknown command '$line' - try /help" }
            }
        } catch { }  # Die already printed the error; return to the prompt
    }
}

function Iphone-Help {
    $remote = $script:cfg.remote
    if (-not $remote) { Die "No main PC paired. Run: devin-rc pair user@HOST" }
    $attach = Remote-Attach-Cmd
    if ($remote -match '@') { $user, $host_ = $remote -split '@', 2 } else { $user = $(if ($env:USERNAME) { $env:USERNAME } else { $env:USER }); $host_ = $remote }
    Write-Host ""
    Write-Host "iPhone setup"
    Write-Host "  1. Install Tailscale (App Store) and sign in to the same tailnet."
    Write-Host "  2. Install an SSH app - Blink Shell is the best tmux client (real Ctrl key);"
    Write-Host "     Termius and the free iSH emulator also work."
    Write-Host "  3. Paste this command into the SSH app:"
    Write-Host ""
    Write-Host "  ssh -t $($SshOpts -join ' ') $remote `"$attach`""
    Write-Host ""
    Write-Host "One-tap connect via the Shortcuts app: action 'Run script over SSH' with"
    Write-Host "  Host: $host_    Port: 22    User: $user"
    Write-Host "  Script: $attach"
    Write-Host ""
    Write-Host "Detach without stopping Devin: Ctrl-b, then d (Blink shows Ctrl on its bar)."
}

function Show-Status {
    $s = $script:cfg.session
    if (Local-Running) { Green "LOCAL  RUNNING   session=$s" } else { Write-Host "LOCAL  STOPPED   session=$s" }
    if ($script:cfg.remote) {
        if (-not (Exists $SshExe)) { Write-Host "REMOTE UNKNOWN   host=$($script:cfg.remote) (no ssh client)"; return }
        $out = (& $SshExe @SshOpts -o BatchMode=yes $script:cfg.remote (Remote-State-Cmd) 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $out) { Write-Host ("REMOTE {0,-9} host={1} session={2}" -f $out, $script:cfg.remote, $s) }
        else { Write-Host "REMOTE UNREACHABLE host=$($script:cfg.remote)" }
    }
}

function Stop-Local {
    Need-Tmux
    if (Local-Running) { Tmux-Run @('tmux', 'kill-session', '-t', $script:cfg.session); Green "Stopped session '$($script:cfg.session)'." }
    else { Write-Host "Session $($script:cfg.session) is not running." }
}

function List-Sessions {
    Write-Host $(if ($IsWin) { '-- local (WSL) --' } else { '-- local --' })
    $has = if ($IsWin) { Exists 'wsl.exe' } else { Exists 'tmux' }
    if ($has) {
        # capture first: a broken WSL distro prints errors on stdout, which '2>$null' can't hide
        $lsOut = Tmux-Run @('tmux', 'ls') 2>$null | Out-String
        if ($LASTEXITCODE -eq 0 -and $lsOut) { $lsOut.TrimEnd() } else { Write-Host '(none)' }
    } else { Write-Host $(if ($IsWin) { 'WSL not installed' } else { 'tmux not installed' }) }
    if ($script:cfg.remote) {
        Write-Host "-- $($script:cfg.remote) --"
        if (Exists $SshExe) {
            $d = $(if ($script:cfg.remote_distro) { "-d $($script:cfg.remote_distro) " } else { '' })
            $cmd = $(if ($script:cfg.remote_mode -eq 'wsl') { "wsl.exe ${d}-e tmux ls" } else { 'command -v tmux >/dev/null && tmux ls 2>/dev/null || true' })
            & $SshExe @SshOpts -o BatchMode=yes $script:cfg.remote $cmd
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
devin-rc - persistent remote control for Devin CLI (any OS with PowerShell 7; Windows 5.1 too)

MAIN PC (Devin runs in tmux: native on Linux/macOS, inside WSL2 on Windows)
  devin-rc setup-host           Check tmux, Devin, Tailscale (on Windows also prints the OpenSSH Server steps)
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
  devin-rc iphone                  iPhone (iOS) connect instructions + command
  devin-rc ui                      Interactive shell (/status /connect /pair ...)

OTHER
  devin-rc ls | info | version | help

OPTIONS (before the command)
  -s, --session NAME            Use session NAME (default: devin); letters, digits, - and _ only
Environment: DEVIN_CMD (may include arguments), DEVIN_RC_DISTRO (WSL distro, Windows host), DEVIN_RC_HOME (config directory)
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
    { $_ -in 'iphone', 'ios', 'mobile' } { Iphone-Help }
    { $_ -in 'ui', 'tui', 'shell' }      { Interactive-Ui }
    'status'     { Show-Status }
    'stop'       { Stop-Local }
    { $_ -in 'ls', 'sessions' }   { List-Sessions }
    'info'       { Show-Info }
    'version'    { Write-Host "$App $Version" }
    'help'       { Show-Usage }
    default      { Die "Unknown command '$cmd'. Run: devin-rc help" }
}
