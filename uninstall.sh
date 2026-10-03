#!/usr/bin/env bash
set -Eeuo pipefail
rm -f "$HOME/.local/bin/devin-rc" "$HOME/bin/devin-rc"

# Remove the "export PATH=... # devin-rc" line install.sh appends, plus the
# older two-line "# devin-rc" + "export PATH=..." block.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  grep -q 'devin-rc' "$rc" || continue
  tmp="$(mktemp)"
  awk '
    /^# devin-rc$/ {
      if ((getline line) > 0 && line !~ /^export PATH=/) { print; print line }
      next
    }
    /^export PATH=.*# devin-rc/ { next }
    { print }
  ' "$rc" > "$tmp"
  cat "$tmp" > "$rc"
  rm -f "$tmp"
done

printf 'Removed devin-rc. Config remains at ~/.config/devin-rc\n'
