#!/usr/bin/env bash
set -euo pipefail
#
# Frames a single command with a solomog step delimiter, so every task — not just the
# stack.sh/mesh.sh orchestrators — shows a clear start banner. Per-task TIMING and the
# final summary are owned by the `solomog` wrapper: it runs each task in turn, times it,
# and prints one grand-total summary at the end. So leaf tasks no longer print their own
# per-segment summary (which previously scattered mini-summaries across a chained run).
#
# Usage: run.sh "<title>" <command> [args...]
#   e.g. run.sh "Deploy utils → a1" helmfile sync -f helmfiles/apps/utils.yaml ...

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"

TITLE="${1:?Usage: run.sh \"<title>\" <command> [args...]}"
shift

solomog_step "$TITLE"

"$@"
