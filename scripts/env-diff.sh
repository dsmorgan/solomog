#!/usr/bin/env bash
set -euo pipefail
#
# Report structural drift between .env and .env.example (keys only — never prints values).

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/envfile.sh
source "$REPO_DIR/scripts/lib/envfile.sh"

envfile_diff
