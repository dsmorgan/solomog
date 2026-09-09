#!/usr/bin/env bash
set -euo pipefail
#
# CLI entry for `solomog vind:create`. Collision-guards names that are already a
# registered external or standalone target, then execs vind-create.sh unchanged.
# stack.sh / mesh.sh call vind-create.sh directly — they do not go through here.
#
# Env:
#   CLUSTER / CLUSTERS  space-separated names (required — no default)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-${CLUSTERS:-}}"
solomog_require_cluster_list "$CLUSTER" "vind:create"

NAMES=()
for n in $CLUSTER; do
  [ -n "$n" ] && NAMES+=("$n")
done

# Refuse a name already claimed by EKS / vsphere / a generic external / standalone
# so vind:create cannot stamp a vcluster over another tracked identity. Unregistered
# and existing vind names pass — vind-create.sh is already idempotent for those.
for n in "${NAMES[@]}"; do
  typ="$(solomog_cluster_type "$n")"
  [ "$typ" = "vind" ] && continue
  {
    echo "Error: vind:create cannot use CLUSTER='${n}' — that name is already a tracked ${typ} target."
    echo "  Pick a different name so cluster:list / teardown stay unambiguous."
    case "$typ" in
      eks|vsphere)
        echo "  → solomog ${typ}:delete CLUSTER=${n}"
        echo "    or  solomog teardown CLUSTER=${n}"
        ;;
      standalone)
        echo "  → solomog standalone:delete CLUSTER=${n}"
        echo "    or  solomog teardown CLUSTER=${n}"
        ;;
      *)
        echo "  Drop it from .solomog/contexts if it still shows in cluster:list."
        ;;
    esac
  } >&2
  exit 1
done

exec bash "$REPO_DIR/scripts/vind-create.sh" "${NAMES[@]}"
