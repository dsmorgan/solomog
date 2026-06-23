#!/usr/bin/env bash
set -euo pipefail
#
# Installs required Homebrew tools and creates the solomog symlink.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOLOMOG_BIN="$REPO_DIR/solomog"
LINK_DIR="$HOME/.local/bin"
LINK_TARGET="$LINK_DIR/solomog"

echo "==> Checking prerequisites..."

check_brew() {
  local formula="$1"
  local cmd="${2:-$(basename "$formula")}"
  if command -v "$cmd" &>/dev/null; then
    echo "    ✓ $cmd"
  else
    echo "    Installing $formula..."
    brew install "$formula"
  fi
}

check_brew "go-task/tap/go-task" "task"
check_brew "helmfile"
check_brew "helm"
check_brew "jq"
check_brew "step"
check_brew "mkcert"

echo ""
echo "==> Creating solomog symlink..."
mkdir -p "$LINK_DIR"

if [[ -L "$LINK_TARGET" ]] && [[ "$(readlink "$LINK_TARGET")" == "$SOLOMOG_BIN" ]]; then
  echo "    ✓ Already linked: $LINK_TARGET"
else
  ln -sf "$SOLOMOG_BIN" "$LINK_TARGET"
  echo "    ✓ $LINK_TARGET → $SOLOMOG_BIN"
fi

# Advise on PATH if needed
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$LINK_DIR"; then
  echo ""
  echo "    Add ~/.local/bin to your PATH by adding this to ~/.zshrc:"
  echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "==> Done. Try: solomog"
