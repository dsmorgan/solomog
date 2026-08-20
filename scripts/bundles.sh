#!/usr/bin/env bash
set -euo pipefail
#
# Lists / inspects custom-config bundles (see scripts/apply-bundle.sh).
# Bundles live in bundles/<name>/ (committed) and bundles/private/<name>/ (gitignored).
#
# Usage:
#   bundles.sh list           pretty list of bundles (+ first README line, private tag)
#                             FILTER=<substr> filters names (case-insensitive, literal)
#   bundles.sh show <name>    files in apply order, with [tmpl] markers
#   bundles.sh names          bare names, one per line (used by apply-bundle.sh)
#
# Env:
#   FILTER   optional substring; list only. Empty = all. Not used by names/show.
#   MATCH    alias for FILTER when invoking this script directly. Do not use MATCH
#            as a go-task CLI var — MATCH is reserved for wildcard captures.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLES="$REPO_DIR/bundles"
MODE="${1:-list}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then G=$'\033[32m'; B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; else G=''; B=''; D=''; R=''; fi

# Echo "<name>\t<dir>\t<private?>" for every bundle dir, committed first then private.
_each_bundle() {
  local d
  for d in "$BUNDLES"/*/; do
    [ -d "$d" ] || continue
    case "$d" in */private/) continue ;; esac   # the private/ container itself isn't a bundle
    printf '%s\t%s\tno\n' "$(basename "$d")" "${d%/}"
  done
  for d in "$BUNDLES"/private/*/; do
    [ -d "$d" ] || continue
    printf '%s\t%s\tyes\n' "$(basename "$d")" "${d%/}"
  done
}

# FILTER is the Taskfile CLI knob. MATCH is a direct-script alias (go-task reserves .MATCH).
_filter_needle() {
  if [ -n "${FILTER:-}" ]; then
    printf '%s' "$FILTER"
  else
    printf '%s' "${MATCH:-}"
  fi
}

# Case-insensitive literal substring on the bundle directory name. Empty needle = keep.
_name_matches() {
  local needle
  needle="$(_filter_needle)"
  [ -z "$needle" ] && return 0
  printf '%s' "$1" | grep -qiF -- "$needle"
}

# Same rows as _each_bundle, restricted to FILTER/MATCH (list only).
_list_rows() {
  local name dir priv
  _each_bundle | while IFS=$'\t' read -r name dir priv; do
    _name_matches "$name" || continue
    printf '%s\t%s\t%s\n' "$name" "$dir" "$priv"
  done
}

case "$MODE" in
  names)
    _each_bundle | cut -f1
    ;;

  list)
    rows="$(_list_rows)"
    if [ -z "$rows" ]; then
      needle="$(_filter_needle)"
      if [ -n "$needle" ]; then
        printf "No bundles matching '%s'.\n" "$needle"
        exit 0
      fi
      printf '%sNo bundles yet.%s Create one:  mkdir -p bundles/<name> && add NN-*.yaml\n' "$B" "$R"
      printf 'See %sbundles/README.md%s for the convention.\n' "$D" "$R"
      exit 0
    fi
    printf '%sApply a bundle:%s solomog apply BUNDLE=<name> CLUSTER=<cluster> [DRY_RUN=true]\n\n' "$B" "$R"
    # Note: end the loop body with statements that return 0 even when the
    # README/desc is absent — otherwise a trailing `[ -n "$desc" ] && printf`
    # returns 1 for the LAST bundle, failing the pipeline under set -e/pipefail.
    printf '%s\n' "$rows" | while IFS=$'\t' read -r name dir priv; do
      desc=""
      if [ -f "$dir/README.md" ]; then
        desc="$(grep -m1 -v '^[[:space:]]*$' "$dir/README.md" | sed 's/^#\{1,\} *//')"
      fi
      tag=""
      [ "$priv" = "yes" ] && tag=" ${D}(private)${R}"
      printf '  %s%s%s%s\n' "$G$B" "$name" "$R" "$tag"
      if [ -n "$desc" ]; then
        printf '    %s%s%s\n' "$D" "$desc" "$R"
      fi
    done
    ;;

  show)
    NAME="${2:?Usage: bundles.sh show <name>}"
    DIR=""
    [ -d "$BUNDLES/private/$NAME" ] && DIR="$BUNDLES/private/$NAME"
    [ -z "$DIR" ] && [ -d "$BUNDLES/$NAME" ] && DIR="$BUNDLES/$NAME"
    if [ -z "$DIR" ]; then
      echo "Error: bundle '$NAME' not found." >&2
      exit 1
    fi
    printf '%s%s%s  %s%s%s\n' "$B" "$NAME" "$R" "$D" "$DIR" "$R"
    [ -f "$DIR/README.md" ] && { echo; sed 's/^/  /' "$DIR/README.md"; echo; }
    printf '%sapply order:%s\n' "$B" "$R"
    (cd "$DIR" && LC_ALL=C ls 2>/dev/null | grep -E '\.(yaml|yml)(\.tmpl)?$|\.sh$' | LC_ALL=C sort) \
      | while IFS= read -r f; do
          case "$f" in
            *.tmpl) printf '  %s  %s[tmpl]%s\n' "$f" "$D" "$R" ;;
            *.sh)   printf '  %s  %s[exec]%s\n' "$f" "$D" "$R" ;;
            *)      printf '  %s\n' "$f" ;;
          esac
        done
    # Tests run by `solomog test` (tests/*.sh, sorted) — mirrors test-bundle.sh's glob/order.
    if [ -d "$DIR/tests" ]; then
      tests="$(cd "$DIR/tests" && LC_ALL=C ls 2>/dev/null | grep -E '\.sh$' | LC_ALL=C sort)"
      if [ -n "$tests" ]; then
        printf '\n%stests:%s %s(solomog test BUNDLE=%s)%s\n' "$B" "$R" "$D" "$NAME" "$R"
        printf '%s\n' "$tests" | while IFS= read -r t; do printf '  %s\n' "$t"; done
      fi
    fi
    ;;

  *)
    echo "Usage: bundles.sh {list|show <name>|names}" >&2
    exit 1
    ;;
esac
