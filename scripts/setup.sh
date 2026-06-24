#!/usr/bin/env bash
set -euo pipefail
#
# Installs required Homebrew tools and creates the solomog symlink.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOLOMOG_BIN="$REPO_DIR/solomog"
LINK_DIR="$HOME/.local/bin"
LINK_TARGET="$LINK_DIR/solomog"

# Preflight: external tools solomog needs but does NOT install for you. Docker
# Desktop, the vcluster CLI, and kubectl come from outside Homebrew's managed set —
# we just verify they're on PATH and point at install docs if not.
echo "==> Preflight: external dependencies..."
MISSING=()
preflight() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" &>/dev/null; then
    echo "    ✓ $cmd"
  else
    echo "    ✗ $cmd — $hint"
    MISSING+=("$cmd")
  fi
}
preflight docker   "Docker Desktop: https://docs.docker.com/desktop/ (must also be running)"
preflight vcluster "vcluster CLI: brew install loft-sh/tap/vcluster  (docs: https://www.vcluster.com/docs)"
preflight kubectl  "kubectl: ships with Docker Desktop, or  brew install kubectl"

echo ""
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

if [ "${#MISSING[@]}" -ne 0 ]; then
  echo ""
  echo "⚠  Missing required external tools: ${MISSING[*]}"
  echo "   Brew tools + symlink are set up, but install these before running scenarios"
  echo "   (see the hints in the preflight above)."
  exit 1
fi

echo ""
echo "==> Done. Try: solomog"
