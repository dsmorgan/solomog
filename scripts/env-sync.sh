#!/usr/bin/env bash
set -euo pipefail
#
# Rebuild .env from .env.example (canonical sections + comments), overlaying your
# existing values. Orphan keys land under a Local-only section. Backs up first.
# Run after pulling .env.example changes, or when refresh/edits scrambled the file.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/envfile.sh
source "$REPO_DIR/scripts/lib/envfile.sh"

envfile_sync
