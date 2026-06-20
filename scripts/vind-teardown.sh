#!/usr/bin/env bash
set -euo pipefail
#
# Destroys vcluster instances. Prompts for confirmation before proceeding.
#
# Usage:
#   vind-teardown.sh                   # destroy all clusters
#   vind-teardown.sh cluster-one       # destroy specific cluster(s)

if command -v vind &>/dev/null; then
  VCLUSTER_CMD=vind
elif command -v vcluster &>/dev/null; then
  VCLUSTER_CMD=vcluster
else
  echo "Error: neither 'vind' nor 'vcluster' found in PATH" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  CLUSTERS=("$@")
else
  mapfile -t CLUSTERS < <(
    $VCLUSTER_CMD list 2>/dev/null \
      | awk 'NR>1 && $1 != "" {print $1}' \
      || true
  )
fi

if [[ ${#CLUSTERS[@]} -eq 0 ]]; then
  echo "No clusters found."
  exit 0
fi

echo ""
echo "The following clusters will be destroyed:"
for cluster in "${CLUSTERS[@]}"; do
  echo "  - $cluster"
done
echo ""
read -rp "Continue? [y/N] " confirm
echo ""

if [[ "${confirm,,}" != "y" ]]; then
  echo "Teardown cancelled."
  exit 0
fi

for cluster in "${CLUSTERS[@]}"; do
  echo "==> Deleting: $cluster"
  $VCLUSTER_CMD delete "$cluster" 2>/dev/null \
    || echo "    Warning: could not delete '$cluster' (may already be gone)"
done

echo ""
echo "Teardown complete."
