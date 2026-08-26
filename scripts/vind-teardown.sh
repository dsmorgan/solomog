#!/usr/bin/env bash
set -euo pipefail
#
# Destroys named vcluster (vind) instances. Prompts for confirmation unless FORCE=true.
#
# CLUSTER / CLUSTERS is required — there is no default-to-all. Explicit names are
# not filtered against .solomog/clusters (you take responsibility for the name),
# but registered eks/vsphere/external names are refused (use that type's delete,
# or `solomog teardown`).
#
# Always prunes stale .solomog/clusters entries (tracked but already gone from
# `vcluster list`) when the list is available, so cluster:list doesn't keep
# showing "gone" forever.
#
# Env:
#   CLUSTER / CLUSTERS  space-separated names (required — destructive)
#   FORCE               "true" skips the confirmation prompt

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

STATE_FILE="$REPO_DIR/.solomog/clusters"

CLUSTER="${CLUSTER:-${CLUSTERS:-}}"
solomog_require_cluster_list "$CLUSTER" "vind:delete"

NAMES=()
for n in $CLUSTER; do
  [ -n "$n" ] && NAMES+=("$n")
done

for n in "${NAMES[@]}"; do
  solomog_require_kind "$n" "vind" "vind:delete"
done

if ! command -v vcluster &>/dev/null; then
  echo "Error: 'vcluster' not found in PATH" >&2
  exit 1
fi

# Cache `vcluster list` once. If Docker/vcluster is down, VCLUSTER_OK=0 and we
# skip prune (don't wipe tracking just because the list failed).
VCLUSTER_RAW=""
VCLUSTER_OK=0
if VCLUSTER_RAW="$(vcluster list 2>/dev/null)"; then
  VCLUSTER_OK=1
fi

# Whether a vcluster with this name currently exists (uses cached list).
cluster_exists() {
  [ "$VCLUSTER_OK" = 1 ] || return 1
  printf '%s\n' "$VCLUSTER_RAW" | awk 'NR>1 && $1 != "" {print $1}' | grep -qxF "$1"
}

# Remove a cluster name from the tracking file.
untrack_cluster() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -vxF "$1" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  [ -s "$STATE_FILE" ] || rm -f "$STATE_FILE"
}

# Drop tracked names that are no longer in `vcluster list`. Safe no-op when the
# list is unavailable (keeps entries rather than mass-pruning on a docker blip).
prune_stale_tracking() {
  [[ -f "$STATE_FILE" ]] || return 0
  if [ "$VCLUSTER_OK" != 1 ]; then
    echo "==> skipping tracking prune (vcluster list unavailable)"
    return 0
  fi
  local name tmp pruned=0
  tmp="${STATE_FILE}.tmp"
  : > "$tmp"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if cluster_exists "$name"; then
      printf '%s\n' "$name" >> "$tmp"
    else
      echo "==> pruned stale tracking entry: $name (already gone)"
      pruned=$((pruned + 1))
    fi
  done < "$STATE_FILE"
  if [ "$pruned" -eq 0 ]; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$STATE_FILE"
  [ -s "$STATE_FILE" ] || rm -f "$STATE_FILE"
}

prune_stale_tracking

echo ""
echo "The following vind clusters will be destroyed:"
for cluster in "${NAMES[@]}"; do
  echo "  - $cluster"
done
echo "(explicit names — not filtered against solomog's tracking)"
echo ""
if [ "${FORCE:-false}" != "true" ]; then
  read -rp "Continue? [y/N] " confirm
  echo ""
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Teardown cancelled."
    exit 1
  fi
fi

for cluster in "${NAMES[@]}"; do
  echo "==> Deleting: $cluster"
  if vcluster delete "$cluster" 2>/dev/null; then
    untrack_cluster "$cluster"
  else
    echo "    Warning: could not delete '$cluster' (may already be gone)"
    untrack_cluster "$cluster"
  fi
done

echo ""
echo "Teardown complete."
