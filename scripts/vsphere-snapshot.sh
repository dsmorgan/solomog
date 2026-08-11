#!/usr/bin/env bash
set -euo pipefail
#
# Take (or inspect) the "solomog-baseline" snapshot of a vsphere cluster's VMs — the
# revert point for `solomog vsphere:reset`. Taking replaces any existing baseline, so
# run it whenever the current cluster state is the one you want resets to land on
# (freshly created, or after installing a base you keep rebuilding from).
# `vsphere:create SNAPSHOT=true` does the same automatically at create time.
# Spec: docs/specs/vsphere-provisioner.md (phase 4).
#
# Env:
#   CLUSTER     vsphere cluster name(s), space-separated (required)
#   ACTION      take (default) | status
#   VSPHERE_*   vCenter connection from .env

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

CLUSTERS="${CLUSTER:-}"
: "${CLUSTERS:?set CLUSTER=<name> or CLUSTERS=\"a b c\"}"
ACTION="${ACTION:-take}"
case "$ACTION" in
  take|status) ;;
  *) echo "Error: ACTION='$ACTION' — use take or status (revert is 'solomog vsphere:reset')." >&2; exit 1 ;;
esac

vsphere_preflight "vsphere:snapshot" conn

for CLUSTER in $CLUSTERS; do
  if [ "$ACTION" = "take" ]; then
    echo "==> Taking baseline snapshots for '${CLUSTER}' (replaces any existing 'solomog-baseline')"
  else
    echo "==> Baseline snapshot status for '${CLUSTER}'"
  fi
  vsphere_vm_tool "$ACTION" "$CLUSTER"
done

if [ "$ACTION" = "take" ]; then
  echo ""
  echo "✓ Baseline captured — reset to it anytime:  solomog vsphere:reset CLUSTERS=\"${CLUSTERS}\""
fi
