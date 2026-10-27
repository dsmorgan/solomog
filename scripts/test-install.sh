#!/usr/bin/env bash
set -euo pipefail
#
# Fixture tests for install.sh (local git only — no network, no setup.sh).
# Run: bash scripts/test-install.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
source "$REPO_DIR/install.sh"

export GIT_AUTHOR_NAME=solomog-test
export GIT_AUTHOR_EMAIL=solomog-test@example.com
export GIT_COMMITTER_NAME=solomog-test
export GIT_COMMITTER_EMAIL=solomog-test@example.com

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/solomog-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> install_dest"
dest="$(install_dest)"
if [ "$dest" = "$REPO_DIR" ]; then
  pass "default dest is the repo that holds install.sh"
else
  fail "default dest is the repo that holds install.sh (got $dest)"
fi
dest="$(SOLOMOG_DEST="$TMP/elsewhere" install_dest)"
if [ "$dest" = "$TMP/elsewhere" ]; then
  pass "SOLOMOG_DEST overrides the checkout directory"
else
  fail "SOLOMOG_DEST overrides the checkout directory (got $dest)"
fi
unset dest

echo "==> tree checks"
if is_solomog_tree "$REPO_DIR"; then
  pass "this repo is a solomog tree"
else
  fail "this repo is a solomog tree"
fi
if is_solomog_tree "$TMP"; then
  fail "empty temp dir is not a solomog tree"
else
  pass "empty temp dir is not a solomog tree"
fi
if dest_missing_or_empty "$TMP/missing"; then
  pass "missing directory counts as empty"
else
  fail "missing directory counts as empty"
fi
mkdir -p "$TMP/empty"
if dest_missing_or_empty "$TMP/empty"; then
  pass "empty directory counts as empty"
else
  fail "empty directory counts as empty"
fi
mkdir -p "$TMP/full"
touch "$TMP/full/x"
if dest_missing_or_empty "$TMP/full"; then
  fail "non-empty directory counts as empty"
else
  pass "non-empty directory is not empty"
fi

git_init() {
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
}

echo "==> pull_checkout"
plain="$TMP/plain"
git_init "$plain"
out="$(pull_checkout "$plain")"
if printf '%s' "$out" | grep -qF 'no upstream'; then
  pass "skips a branch with no upstream"
else
  fail "skips a branch with no upstream ($out)"
fi

origin="$TMP/origin"
git_init "$origin"
git clone -q "$origin" "$TMP/clean"
echo one > "$origin/file"
git -C "$origin" add file
git -C "$origin" commit -q -m one
before="$(git -C "$TMP/clean" rev-parse HEAD)"
out="$(pull_checkout "$TMP/clean")"
after="$(git -C "$TMP/clean" rev-parse HEAD)"
if [ "$before" != "$after" ] && printf '%s' "$out" | grep -qF 'Updating'; then
  pass "fast-forwards a clean checkout"
else
  fail "fast-forwards a clean checkout (before=$before after=$after out=$out)"
fi

git clone -q "$origin" "$TMP/dirty"
echo dirty > "$TMP/dirty/local"
before="$(git -C "$TMP/dirty" rev-parse HEAD)"
out="$(pull_checkout "$TMP/dirty")"
after="$(git -C "$TMP/dirty" rev-parse HEAD)"
if [ "$before" = "$after" ] && printf '%s' "$out" | grep -qF 'local changes'; then
  pass "skips pull when the worktree is dirty"
else
  fail "skips pull when the worktree is dirty (out=$out)"
fi

git clone -q "$origin" "$TMP/mine"
echo mine > "$TMP/mine/mine"
git -C "$TMP/mine" add mine
git -C "$TMP/mine" commit -q -m mine
echo theirs > "$origin/theirs"
git -C "$origin" add theirs
git -C "$origin" commit -q -m theirs
if pull_checkout "$TMP/mine" >/dev/null 2>&1; then
  fail "diverged branch should fail the pull"
else
  pass "diverged branch fails the pull"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All install tests passed."
  exit 0
fi
echo "${FAIL} install test(s) failed."
exit 1
