#!/usr/bin/env bash
set -Eeuo pipefail
rm -f "$HOME/.local/bin/devin-rc" "$HOME/bin/devin-rc"
printf 'Removed devin-rc binary. Config remains at ~/.config/devin-rc\n'
