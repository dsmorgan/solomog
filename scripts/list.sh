#!/usr/bin/env bash
set -euo pipefail
#
# Renders the `solomog` scenario list: green, column-aligned task names with their
# descriptions — and NO trailing colon (the colon in `task --list` reads like part of
# what you type). Color is emitted here (not by Task) so it survives, and is dropped
# when stdout isn't a TTY or NO_COLOR is set.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; B=$'\033[1m'; R=$'\033[0m'
else
  G=''; B=''; R=''
fi

printf '%sRun a scenario:%s solomog <name> [CLUSTER=… EDITION=… ROUTE=true …]\n\n' "$B" "$R"

task --list --json 2>/dev/null \
  | jq -r '.tasks[] | [.name, .desc] | @tsv' \
  | sort \
  | awk -F'\t' -v g="$G$B" -v r="$R" '
      { name[NR]=$1; desc[NR]=$2; if (length($1) > w) w = length($1) }
      END { for (i = 1; i <= NR; i++) printf "  %s%-*s%s  %s\n", g, w, name[i], r, desc[i] }'
