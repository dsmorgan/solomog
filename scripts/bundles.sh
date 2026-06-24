#!/usr/bin/env bash
set -euo pipefail
#
# Lists / inspects custom-config bundles (see scripts/apply-bundle.sh).
# Bundles live in bundles/<name>/ (committed) and bundles/private/<name>/ (gitignored).
#
# Usage:
#   bundles.sh list           pretty list of bundles (+ first README line, private tag)
#   bundles.sh show <name>    files in apply order, with [tmpl] markers
#   bundles.sh names          bare names, one per line (used by apply-bundle.sh)

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

case "$MODE" in
  names)
    _each_bundle | cut -f1
    ;;

  list)
    if [ -z "$(_each_bundle)" ]; then
      printf '%sNo bundles yet.%s Create one:  mkdir -p bundles/<name> && add NN-*.yaml\n' "$B" "$R"
      printf 'See %sbundles/README.md%s for the convention.\n' "$D" "$R"
      exit 0
    fi
    printf '%sApply a bundle:%s solomog apply BUNDLE=<name> CLUSTER=<cluster> [DRY_RUN=true]\n\n' "$B" "$R"
    # Note: end the loop body with statements that return 0 even when the
    # README/desc is absent — otherwise a trailing `[ -n "$desc" ] && printf`
    # returns 1 for the LAST bundle, failing the pipeline under set -e/pipefail.
    _each_bundle | while IFS=$'\t' read -r name dir priv; do
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
    ;;

  *)
    echo "Usage: bundles.sh {list|show <name>|names}" >&2
    exit 1
    ;;
esac
