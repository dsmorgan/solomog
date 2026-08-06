#!/usr/bin/env bash
set -euo pipefail
#
# Backup the repo-root .env into .solomog/env-backups/<timestamp>.env (gitignored).
# Also runs automatically before aws:refresh / gcp:refresh / env:sync.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/envfile.sh
source "$REPO_DIR/scripts/lib/envfile.sh"

dest="$(envfile_backup)"
echo "✓ backed up .env → ${dest#"$REPO_DIR"/}"
