#!/usr/bin/env bash
set -euo pipefail
#
# Destroys vcluster instances that solomog created. Prompts for confirmation.
#
# solomog records every cluster it creates in .solomog/clusters. With no args,
# teardown only considers those — your hand-made vclusters are never touched.
# Passing explicit names overrides this (you take responsibility for the name).
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

# Whether a vcluster with this name currently exists.
cluster_exists() {
  vcluster list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}' | grep -qxF "$1"
}

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

# Remove a cluster name from the tracking file.
untrack_cluster() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -vxF "$1" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

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
