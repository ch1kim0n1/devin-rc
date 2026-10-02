#!/usr/bin/env bash
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="devin-rc"

choose_bin_dir() {
  if [[ -d "$HOME/.local/bin" ]] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    printf '%s' "$HOME/.local/bin"
  else
    printf '%s' "$HOME/bin"
  fi
}

BIN_DIR="$(choose_bin_dir)"
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
      # shellcheck disable=SC2016
      printf '\n# devin-rc\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$shell_rc"
    fi
    ;;
esac

printf 'Installed: %s/%s\n' "$BIN_DIR" "$BIN_NAME"
printf '\nNext:\n'
printf '  Main PC: devin-rc setup-host\n'
printf '  Laptop:  devin-rc pair user@HOST && devin-rc connect\n'
