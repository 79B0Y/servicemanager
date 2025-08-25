#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_SRC="$REPO_ROOT/bin/isg-android-control"
BIN_DST="${HOME}/.local/bin/isg-android-control"

mkdir -p "${HOME}/.local/bin"
chmod +x "$BIN_SRC"

# Prefer symlink; fallback to copy if filesystem disallows
if ln -sf "$BIN_SRC" "$BIN_DST" 2>/dev/null; then
  echo "Installed symlink: $BIN_DST -> $BIN_SRC"
else
  cp "$BIN_SRC" "$BIN_DST"
  echo "Installed copy: $BIN_DST"
fi

echo "Ensure ~/.local/bin is in PATH, e.g.:"
echo "  export PATH=\"$HOME/.local/bin:\$PATH\""

