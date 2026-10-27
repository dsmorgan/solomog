#!/usr/bin/env bash
set -euo pipefail
#
# Install Homebrew tools solomog needs, create .env from the example when
# absent, and symlink ./solomog onto ~/.local/bin.
#
# Idempotent. An existing .env is never overwritten. A formula whose command
# is already on PATH is left alone (no brew upgrade). Re-run after installing
# Docker Desktop or kubectl.
#
# Does not pull git. bash install.sh does that when the worktree is clean.
#
# External prerequisites (this script does not install them):
#   Docker Desktop   must be running (docker info)
#   kubectl          ships with Docker Desktop, or: brew install kubectl
#   Homebrew         https://brew.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOLOMOG_BIN="$REPO_DIR/solomog"
LINK_DIR="${HOME}/.local/bin"
LINK_TARGET="${LINK_DIR}/solomog"
ZSHRC_MARKER="# solomog: ~/.local/bin"

# setup_copy_env DIR
# Copy DIR/.env.example to DIR/.env when .env is absent. An existing .env is
# left alone, including a symlink. Returns 1 when the example is missing.
setup_copy_env() {
  local dest="$1"
  if [ -e "${dest}/.env" ]; then
    echo "    ✓ .env already exists — left it alone"
    return 0
  fi
  if [ ! -f "${dest}/.env.example" ]; then
    echo "Error: ${dest}/.env.example is missing; cannot create .env" >&2
    return 1
  fi
  cp "${dest}/.env.example" "${dest}/.env"
  echo "    ✓ Created .env from .env.example"
  echo "      Add license keys before an enterprise install. Community-only use can leave them blank."
  return 0
}

# setup_ensure_path DIR
# When DIR is not on PATH, append one marked export to ~/.zshrc. A second run
# does not append again. A ~/.zshrc that already mentions .local/bin is left
# alone — this shell may simply need a new terminal.
setup_ensure_path() {
  local link_dir="$1"
  local zshrc="${HOME}/.zshrc"
  if echo "$PATH" | tr ':' '\n' | grep -qx "$link_dir"; then
    echo "    ✓ ${link_dir} is on PATH"
    return 0
  fi
  if [ -f "$zshrc" ] && grep -qF "$ZSHRC_MARKER" "$zshrc"; then
    echo "    ~/.local/bin is in ~/.zshrc, but not in this shell."
    echo "      Open a new terminal, or run: source ~/.zshrc"
    return 0
  fi
  if [ -f "$zshrc" ] && grep -qF '.local/bin' "$zshrc"; then
    echo "    ~/.zshrc already mentions ~/.local/bin, but this shell does not have it on PATH."
    echo "      Open a new terminal, or add: export PATH=\"\$HOME/.local/bin:\$PATH\""
    return 0
  fi
  if [ -s "$zshrc" ]; then
    printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$ZSHRC_MARKER" >> "$zshrc"
  else
    printf '%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$ZSHRC_MARKER" >> "$zshrc"
  fi
  echo "    ✓ Added ~/.local/bin to ~/.zshrc"
  echo "      Open a new terminal, or run: source ~/.zshrc"
  return 0
}

setup_main() {
  local DOCKER_DOWN=0
  MISSING=()

  # External tools this script does not install. vcluster is Homebrew, below.
  echo "==> Preflight: external dependencies..."
  preflight() {
    local cmd="$1" hint="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "    ✓ $cmd"
    else
      echo "    ✗ $cmd — $hint"
      MISSING+=("$cmd")
    fi
  }
  preflight docker  "Docker Desktop: https://docs.docker.com/desktop/"
  preflight kubectl "kubectl: ships with Docker Desktop, or  brew install kubectl"

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      echo "    ✓ docker daemon"
    else
      echo "    ✗ docker daemon — Docker is installed but not running. Start Docker Desktop and re-run."
      DOCKER_DOWN=1
    fi
  fi

  echo ""
  echo "==> Checking Homebrew tools..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "    ✗ brew — install Homebrew from https://brew.sh, then re-run." >&2
    exit 1
  fi

  check_brew() {
    local formula="$1"
    local cmd="${2:-$(basename "$formula")}"
    if command -v "$cmd" >/dev/null 2>&1; then
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
  check_brew "uv"                       # Python bundle tests; isolated, on-the-fly deps
  check_brew "loft-sh/tap/vcluster" "vcluster"

  echo ""
  echo "==> Local .env..."
  setup_copy_env "$REPO_DIR"

  echo ""
  echo "==> Creating solomog symlink..."
  mkdir -p "$LINK_DIR"

  if [[ -L "$LINK_TARGET" ]] && [[ "$(readlink "$LINK_TARGET")" == "$SOLOMOG_BIN" ]]; then
    echo "    ✓ Already linked: $LINK_TARGET"
  else
    ln -sf "$SOLOMOG_BIN" "$LINK_TARGET"
    echo "    ✓ $LINK_TARGET → $SOLOMOG_BIN"
  fi

  echo ""
  echo "==> PATH..."
  setup_ensure_path "$LINK_DIR"

  if [ "${#MISSING[@]}" -ne 0 ] || [ "$DOCKER_DOWN" -eq 1 ]; then
    echo ""
    echo "Brew tools and the symlink are in place, but solomog cannot create clusters yet."
    if [ "${#MISSING[@]}" -ne 0 ]; then
      echo "Missing: ${MISSING[*]}"
    fi
    if [ "$DOCKER_DOWN" -eq 1 ]; then
      echo "Start Docker Desktop, then re-run."
    fi
    exit 1
  fi

  echo ""
  echo "==> Optional (one-time): solomog setup:sudo"
  echo "    Lets solomog rewrite /etc/hosts with no password prompt, so an unattended"
  echo "    'solomog stack …' does not stall mid-install. See: solomog help setup:sudo"

  echo ""
  echo "==> Done. Try: solomog"
}

# Executed as a script, not when a test sources the helpers above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  setup_main
fi
