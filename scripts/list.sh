#!/usr/bin/env bash
set -euo pipefail
#
# Bare `solomog` (and `solomog help` with no topic): the grouped index.
# Colour is emitted here (not by Task) so it survives, and is dropped when
# stdout isn't a TTY or NO_COLOR is set. Full catalog: `solomog help --all`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/help.sh
source "$ROOT/scripts/lib/help.sh"
solomog_help_index
