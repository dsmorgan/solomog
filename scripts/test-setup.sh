#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for scripts/setup.sh helpers (no brew, no Docker, no ~/.zshrc).
# Run: bash scripts/test-setup.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=setup.sh
source "$REPO_DIR/scripts/setup.sh"

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/solomog-setup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> setup_copy_env"
d="$TMP/env"
mkdir -p "$d"
printf 'A=1\n' > "$d/.env.example"
setup_copy_env "$d" >/dev/null
if [ "$(cat "$d/.env")" = "A=1" ]; then
  pass "copies example when .env is absent"
else
  fail "copies example when .env is absent"
fi
printf 'KEEP=1\n' > "$d/.env"
printf 'A=2\n' > "$d/.env.example"
setup_copy_env "$d" >/dev/null
if [ "$(cat "$d/.env")" = "KEEP=1" ]; then
  pass "leaves an existing .env alone"
else
  fail "leaves an existing .env alone"
fi
missing="$TMP/no-example"
mkdir -p "$missing"
if setup_copy_env "$missing" >/dev/null 2>&1; then
  fail "missing example should fail"
else
  pass "missing example fails"
fi

echo "==> setup_ensure_path"
home1="$TMP/home1"
mkdir -p "$home1"
out="$(HOME="$home1" PATH="/usr/bin:/bin" setup_ensure_path "$home1/.local/bin")"
if grep -qF '# solomog: ~/.local/bin' "$home1/.zshrc" \
  && grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$home1/.zshrc"; then
  pass "appends a marked PATH line"
else
  fail "appends a marked PATH line ($out)"
fi
before="$(cat "$home1/.zshrc")"
HOME="$home1" PATH="/usr/bin:/bin" setup_ensure_path "$home1/.local/bin" >/dev/null
if [ "$(cat "$home1/.zshrc")" = "$before" ]; then
  pass "does not append twice"
else
  fail "does not append twice"
fi

home2="$TMP/home2"
mkdir -p "$home2"
printf '# already uses .local/bin\n' > "$home2/.zshrc"
before="$(cat "$home2/.zshrc")"
HOME="$home2" PATH="/usr/bin:/bin" setup_ensure_path "$home2/.local/bin" >/dev/null
if [ "$(cat "$home2/.zshrc")" = "$before" ]; then
  pass "does not rewrite a zshrc that already mentions .local/bin"
else
  fail "does not rewrite a zshrc that already mentions .local/bin"
fi

home3="$TMP/home3"
mkdir -p "$home3"
HOME="$home3" PATH="${home3}/.local/bin:/usr/bin" setup_ensure_path "$home3/.local/bin" >/dev/null
if [ ! -e "$home3/.zshrc" ]; then
  pass "skips zshrc when the directory is already on PATH"
else
  fail "skips zshrc when the directory is already on PATH"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All setup helper tests passed."
  exit 0
fi
echo "${FAIL} setup helper test(s) failed."
exit 1
