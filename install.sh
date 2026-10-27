#!/usr/bin/env bash
set -euo pipefail
#
# Bootstrap or update a solomog checkout, then run scripts/setup.sh.
#
# New machine (Docker Desktop running, Homebrew installed). Clone wherever
# you keep source; the script uses its own directory:
#   git clone https://github.com/dsmorgan/solomog.git
#   cd solomog && bash install.sh
#
# Later, from the checkout or by path:
#   bash install.sh
#   bash /path/to/solomog/install.sh
#   Fast-forwards the tracked branch when the worktree is clean, then refreshes
#   tools. A dirty tree, a detached HEAD, or a branch with no upstream skips
#   the pull and still runs setup. A diverged branch stops before setup.
#
# Env:
#   SOLOMOG_DEST   checkout directory (default: this script's directory,
#                  or ~/solomog when the script has no path — a pipe)
#   SOLOMOG_REPO   clone URL (default: https://github.com/dsmorgan/solomog.git)

SOLOMOG_REPO_DEFAULT="https://github.com/dsmorgan/solomog.git"

# dest_missing_or_empty DIR — true when DIR is absent or has no entries.
dest_missing_or_empty() {
  local dest="$1"
  if [ ! -d "$dest" ]; then
    return 0
  fi
  [ -z "$(ls -A "$dest")" ]
}

# is_solomog_tree DIR — true when DIR looks like this repo.
is_solomog_tree() {
  local dest="$1"
  [ -f "${dest}/scripts/setup.sh" ] && [ -f "${dest}/solomog" ] && [ -f "${dest}/Taskfile.yaml" ]
}

# pull_checkout DIR
# Fast-forward when the worktree is clean and the branch tracks an upstream.
# Returns 0 when the pull is skipped or succeeds, 1 when pull --ff-only fails.
pull_checkout() {
  local dest="$1"
  local status branch upstream
  if ! git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "==> Not a git checkout; skipping git pull"
    return 0
  fi
  status="$(git -C "$dest" status --porcelain)"
  if [ -n "$status" ]; then
    echo "==> Working tree has local changes; skipping git pull"
    echo "    Tools still refresh. Commit or stash, then re-run, to update main."
    return 0
  fi
  branch="$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    echo "==> Detached HEAD; skipping git pull"
    return 0
  fi
  upstream="$(git -C "$dest" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [ -z "$upstream" ]; then
    echo "==> Branch ${branch} has no upstream; skipping git pull"
    return 0
  fi
  echo "==> Updating ${branch} (${upstream})"
  if ! git -C "$dest" pull --ff-only; then
    echo "Error: git pull --ff-only failed." >&2
    echo "       Fix the branch, or run: bash scripts/setup.sh" >&2
    return 1
  fi
  return 0
}

# install_dest — checkout directory for this run.
# SOLOMOG_DEST wins. Otherwise the directory of this file (BASH_SOURCE[0] is
# install.sh inside these functions). A piped script with no file falls back
# to ~/solomog.
install_dest() {
  local script_path
  if [ -n "${SOLOMOG_DEST:-}" ]; then
    printf '%s\n' "$SOLOMOG_DEST"
    return 0
  fi
  script_path="${BASH_SOURCE[0]:-}"
  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    (cd "$(dirname "$script_path")" && pwd)
    return 0
  fi
  printf '%s\n' "${HOME}/solomog"
}

install_main() {
  local dest repo
  repo="${SOLOMOG_REPO:-$SOLOMOG_REPO_DEFAULT}"
  dest="$(install_dest)"

  if dest_missing_or_empty "$dest"; then
    echo "==> Cloning ${repo}"
    echo "    into ${dest}"
    mkdir -p "$(dirname "$dest")"
    git clone "$repo" "$dest"
  elif ! is_solomog_tree "$dest"; then
    echo "Error: ${dest} is not a solomog checkout." >&2
    echo "       Expected scripts/setup.sh, solomog, and Taskfile.yaml." >&2
    exit 1
  else
    pull_checkout "$dest" || exit 1
  fi

  bash "${dest}/scripts/setup.sh"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  install_main "$@"
fi
