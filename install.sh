#!/usr/bin/env bash
# Idempotent installer: symlinks the entry-script into ~/.local/bin and prepares config dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/autocoding"

check_dep() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "MISSING: $1" >&2
        return 1
    fi
    printf '  ok  %-10s %s\n' "$1" "$(command -v "$1")"
}

echo "Checking dependencies..."
missing=0
for dep in gh claude git jq envsubst; do
    check_dep "$dep" || missing=1
done
if (( missing )); then
    echo
    echo "Install missing dependencies before running auto-code."
    exit 1
fi

echo
echo "Preparing config dir: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR/state" "$CONFIG_DIR/logs"
if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
    cp "$SCRIPT_DIR/examples/config.env.example" "$CONFIG_DIR/config.env"
    echo "  wrote default config.env (edit to customize)"
else
    echo "  config.env already exists, leaving untouched"
fi

echo
echo "Installing symlink: $BIN_DIR/auto-code -> $SCRIPT_DIR/auto-code.sh"
mkdir -p "$BIN_DIR"
ln -sf "$SCRIPT_DIR/auto-code.sh" "$BIN_DIR/auto-code"
chmod +x "$SCRIPT_DIR/auto-code.sh"

echo
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "NOTE: $BIN_DIR is not on \$PATH. Add this to ~/.zshrc:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo "Done. Try: auto-code --help"
