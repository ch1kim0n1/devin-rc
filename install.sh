#!/usr/bin/env bash
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="devin-rc"

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
install -m 0755 "$SRC_DIR/$BIN_NAME" "$BIN_DIR/$BIN_NAME"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    shell_rc="$HOME/.bashrc"
    [[ "${SHELL:-}" == */zsh ]] && shell_rc="$HOME/.zshrc"
    touch "$shell_rc"
    # Match BIN_DIR only as a whole path segment, so e.g. ~/.local/bin2
    # does not satisfy the check for ~/.local/bin.
    esc_dir="$(printf '%s' "$BIN_DIR" | sed 's/[][\\.*^$/]/\\&/g')"
    if ! grep -Eq "(^|[:\"' =])${esc_dir}([:\"' ]|$)" "$shell_rc"; then
      # The "# devin-rc" suffix lets uninstall.sh find and remove this line.
      printf '\nexport PATH="%s:$PATH" # devin-rc\n' "$BIN_DIR" >> "$shell_rc"
    fi
    ;;
esac

printf 'Installed: %s/%s\n' "$BIN_DIR" "$BIN_NAME"
printf '\nNext:\n'
printf '  Main PC: devin-rc setup-host\n'
printf '  Laptop:  devin-rc pair user@HOST && devin-rc connect\n'
