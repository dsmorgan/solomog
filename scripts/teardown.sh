#!/usr/bin/env bash
set -euo pipefail
#
# Type-agnostic teardown of solomog-managed targets. Requires CLUSTER / CLUSTERS (no
# default-to-all). Detects each name (vind / vsphere / eks / standalone) and dispatches to
# the type-specific delete. One prompt for the whole batch; children run with FORCE=true.
#
# `standalone` is not a cluster — it is an agentgateway container with no Kubernetes — but it
# IS a solomog-managed target, so it is destroyed here too. One command deletes anything,
# whatever its type.
#
# A registered generic `external` name is refused before anything is destroyed —
# solomog did not create it.
#
# Env:
#   CLUSTER / CLUSTERS  space-separated names (required — destructive)
#   FORCE               "true" skips the confirmation prompt

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-${CLUSTERS:-}}"
solomog_require_cluster_list "$CLUSTER" "teardown"

NAMES=()
for n in $CLUSTER; do
  [ -n "$n" ] && NAMES+=("$n")
done

vind_list=""
vsphere_list=""
eks_list=""
standalone_list=""
bad=0
for n in "${NAMES[@]}"; do
  typ="$(solomog_cluster_type "$n")"
  case "$typ" in
    vind)    vind_list="${vind_list:+$vind_list }$n" ;;
    vsphere) vsphere_list="${vsphere_list:+$vsphere_list }$n" ;;
    eks)     eks_list="${eks_list:+$eks_list }$n" ;;
    standalone) standalone_list="${standalone_list:+$standalone_list }$n" ;;
    *)
      echo "Error: CLUSTER='${n}' is a registered external cluster solomog didn't create — it will not destroy it." >&2
      echo "  Delete it yourself, then drop it from .solomog/contexts if it still shows in cluster:list." >&2
      bad=1
      ;;
  esac
done
[ "$bad" = 0 ] || exit 1

echo ""
echo "The following targets will be destroyed:"
for n in "${NAMES[@]}"; do
  printf '  - %-20s (%s)\n' "$n" "$(solomog_cluster_type "$n")"
done
echo ""
if [ "${FORCE:-false}" != "true" ]; then
  read -rp "Continue? [y/N] " confirm
  echo ""
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Teardown cancelled."
    exit 1
  fi
fi

run_group() {   # args: <script> <list>
  local script="$1" list="$2"
  [ -n "$list" ] || return 0
  FORCE=true CLUSTER="$list" bash "$script"
}

# standalone.sh is per-instance and keys on INSTANCE, so loop rather than passing a list.
run_standalone() {   # args: <list>
  local list="$1" n rc=0
  [ -n "$list" ] || return 0
  for n in $list; do
    FORCE=true INSTANCE="$n" NAME="" bash "$REPO_DIR/scripts/standalone.sh" delete || rc=1
  done
  return "$rc"
}

RC=0
run_group "$REPO_DIR/scripts/vind-teardown.sh" "$vind_list" || RC=1
run_group "$REPO_DIR/scripts/vsphere-delete.sh" "$vsphere_list" || RC=1
run_group "$REPO_DIR/scripts/eks-delete.sh" "$eks_list" || RC=1
run_standalone "$standalone_list" || RC=1

echo ""
if [ "$RC" -eq 0 ]; then
  echo "✓ Torn down: ${CLUSTER}"
else
  echo "⚠ Teardown finished with errors — review the messages above and re-run for the failed cluster(s)."
  exit 1
fi
