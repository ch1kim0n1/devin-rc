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

## Important limitation

A Devin CLI process that was already launched in a normal terminal **before** `devin-rc` cannot be safely and portably pulled into tmux after the fact. Exit that one once, then launch future sessions with `devin-rc start`.

## Security model

There is no public web terminal and no custom password server. Connectivity is through Tailscale, and SSH access is governed by your tailnet's Tailscale SSH policy.
