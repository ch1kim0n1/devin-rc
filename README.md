# devin-rc

A tiny remote-control wrapper for Devin CLI.

It does **not** clone or hand off the Devin session. Devin runs on the main PC inside `tmux`; your laptop attaches to that same pseudo-terminal over Tailscale SSH.

## Requirements

- Main PC: Linux, Devin CLI, Tailscale
- Laptop: macOS or Linux, Tailscale + SSH
- Both devices signed into the same Tailscale network

Devin CLI itself supports macOS, Linux, and Windows. This v1 intentionally targets a Linux host because Tailscale SSH + tmux is the smallest reliable setup.

## 1. Install on both machines

Copy this folder to each machine, then:

```bash
./install.sh
exec "$SHELL" -l
```

## 2. Main PC: one-time host setup

```bash
devin-rc setup-host
```

That checks Devin/tmux/Tailscale, installs `tmux` if needed, enables Tailscale SSH, and prints something like:

```text
vlad@100.101.102.103
```

## 3. Main PC: launch Devin remote-ready

From a project:

```bash
cd ~/code/my-project
devin-rc start
```

Or:

```bash
devin-rc start ~/code/my-project
```

You now use Devin normally. To leave it running and return to your shell:

```text
Ctrl-b, then d
```

## 4. Laptop: pair once

Use the target printed by `setup-host`:

```bash
devin-rc pair vlad@100.101.102.103
```

## 5. Laptop: connect

```bash
devin-rc connect
```

You are now attached to the **same tmux pane and same Devin CLI process** running on the main PC.

You can keep both the main-PC terminal and laptop attached simultaneously. Anything typed/output in one is visible in the other.

## Commands

```text
devin-rc setup-host
devin-rc start [project]
devin-rc bg [project]
devin-rc connect [user@host]
devin-rc pair user@host
devin-rc status          # local + remote state
devin-rc ls              # list local + remote tmux sessions
devin-rc stop
devin-rc info
devin-rc version
```

Multiple concurrent sessions are supported via `-s`/`--session` (placed before
the command) or the `SESSION` environment variable. Session names are limited
to letters, digits, `-` and `_` (tmux forbids `.` and `:`):

```bash
devin-rc -s web bg ~/code/web
devin-rc -s api bg ~/code/api
devin-rc -s web connect
```

`DEVIN_CMD` may include arguments (e.g. `DEVIN_CMD="devin --model x"`), and is
persisted by `setup-host`/`pair` in `~/.config/devin-rc/config`.

## Windows

Native Windows support is a PowerShell port (`devin-rc.ps1`, works in Windows PowerShell 5.1 and PowerShell 7) with the same commands.

```powershell
.\install.ps1            # per-user install, adds devin-rc to your user PATH (no admin); -NoPath to skip, -Prefix to relocate
devin-rc help
.\uninstall.ps1          # -Purge also removes the saved config
```

Installing also drops a `devin-rc.cmd` shim (cmd/PowerShell) and a `devin-rc` shim for Git Bash.

| Role on Windows | How it works | Needs |
|---|---|---|
| **Laptop (client)**: `pair`, `connect`, `status`, `ls` | Windows OpenSSH client (`ssh.exe`) over Tailscale | Tailscale for Windows signed in; OpenSSH Client (installed by default on Windows 11) |
| **Main PC (host)**: `setup-host`, `start`, `bg`, `stop` | Devin runs in `tmux` inside **WSL2** (tmux has no native Windows build) | A working WSL distro with tmux and the **Linux** Devin CLI inside it |

Windows-specific notes:

- Pairing with a Windows host: `devin-rc pair user@HOST --wsl` (the client then attaches through `wsl.exe -e tmux ...`). Pairing with a Linux or macOS host needs no flag.
- **Tailscale SSH cannot host on Windows**, so a Windows host needs the Windows OpenSSH Server. `setup-host` checks WSL, tmux, Devin and Tailscale and prints the elevated PowerShell commands for the OpenSSH Server and a firewall rule limited to the Tailscale range; it does not change system settings itself.
- Multiple WSL distros: set `DEVIN_RC_DISTRO`. Config lives in `%APPDATA%\devin-rc\config.json` (override with `DEVIN_RC_HOME`).
- The bash version still works as a client under Git Bash; its `setup-host` stops with a pointer to the PowerShell version.
- The client side was tested on Windows 11 (PowerShell 7 and 5.1, the cmd and Git Bash shims, install and uninstall). The host side (WSL) is the less tested path: if `wsl -l -v` shows a distro that does not start, repair or reinstall it first.

## Important limitation

A Devin CLI process that was already launched in a normal terminal **before** `devin-rc` cannot be safely and portably pulled into tmux after the fact. Exit that one once, then launch future sessions with `devin-rc start`.

## Security model

There is no public web terminal and no custom password server. Connectivity is through Tailscale, and SSH access is governed by your tailnet's Tailscale SSH policy.
