#!/usr/bin/env bash
set -euo pipefail
#
# Pause a solomog vsphere cluster: graceful guest shutdown of every node VM (open-vm-
# tools; hard power-off fallback after 180s), freeing the host CPU/RAM the cluster was
# holding. All state is preserved exactly as-is — the complement is vsphere-start.sh,
# which boots the same state back up. Non-destructive and reversible, so no prompt.
# Spec: docs/specs/vsphere-provisioner.md (phase 4).
#
# Env:
#   CLUSTER     vsphere cluster name(s), space-separated (required)
#   VSPHERE_*   vCenter connection from .env

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

CLUSTERS="${CLUSTER:-}"
: "${CLUSTERS:?set CLUSTER=<name> or CLUSTERS=\"a b c\"}"

vsphere_preflight "vsphere:stop" conn

for CLUSTER in $CLUSTERS; do
  echo "==> Stopping '${CLUSTER}' (graceful guest shutdown; state preserved)"
  vsphere_vm_tool stop "$CLUSTER"
done

echo ""
echo "✓ Stopped: ${CLUSTERS} — host resources freed. Resume with:  solomog vsphere:start CLUSTERS=\"${CLUSTERS}\""
