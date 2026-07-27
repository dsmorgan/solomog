#!/usr/bin/env bash
set -euo pipefail
#
# Destroys vcluster instances that solomog created. Prompts for confirmation.
#
# solomog records every cluster it creates in .solomog/clusters. With no args,
# teardown only considers those — your hand-made vclusters are never touched.
# Passing explicit names overrides this (you take responsibility for the name).
#
# Always prunes stale .solomog/clusters entries (tracked but already gone from
# `vcluster list`) when the list is available — even if there's nothing left to
# delete — so cluster:list doesn't keep showing "gone" forever.
#
# Usage:
#   vind-teardown.sh                          # destroy all solomog-created clusters
#   vind-teardown.sh cluster-one [cluster-two] # destroy specific cluster(s), tracked or not

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$REPO_DIR/.solomog/clusters"

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

# Collect non-empty positional args (Task passes an empty string when CLUSTER is unset).
ARGS=()
for a in "$@"; do [[ -n "$a" ]] && ARGS+=("$a"); done

CLUSTERS=()
if [[ ${#ARGS[@]} -gt 0 ]]; then
  CLUSTERS=("${ARGS[@]}")
  EXPLICIT=true
else
  EXPLICIT=false
  # Only solomog-created clusters that still exist.
  if [[ -f "$STATE_FILE" ]]; then
    while IFS= read -r tracked; do
      [[ -z "$tracked" ]] && continue
      if cluster_exists "$tracked"; then
        CLUSTERS+=("$tracked")
      fi
    done < "$STATE_FILE"
  fi
fi

if [[ ${#CLUSTERS[@]} -eq 0 ]]; then
  echo "No solomog-created clusters to tear down."
  echo "(Hand-made clusters are never auto-targeted. Use 'CLUSTER=<name>' to remove one explicitly.)"
  exit 0
fi

echo ""
echo "The following clusters will be destroyed:"
for cluster in "${CLUSTERS[@]}"; do
  echo "  - $cluster"
done
$EXPLICIT && echo "(explicit names — not filtered against solomog's tracking)"
echo ""
read -rp "Continue? [y/N] " confirm
echo ""

if [[ ! "$confirm" =~ ^[Yy] ]]; then
  echo "Teardown cancelled."
  exit 0
fi

for cluster in "${CLUSTERS[@]}"; do
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
