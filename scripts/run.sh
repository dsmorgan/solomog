#!/usr/bin/env bash
set -euo pipefail
#
# Frames a single command with solomog's purple delimiters + run timer, so every
# task — not just the stack.sh/mesh.sh orchestrators — gets consistent start/finish
# output. Use this for any leaf task that would otherwise call a tool directly.
#
# Usage: run.sh "<title>" <command> [args...]
#   e.g. run.sh "Deploy utils → a1" helmfile sync -f helmfiles/apps/utils.yaml ...

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"

TITLE="${1:?Usage: run.sh \"<title>\" <command> [args...]}"
shift

solomog_clock_reset
solomog_step "$TITLE"

"$@"

solomog_summary "$TITLE — complete"
