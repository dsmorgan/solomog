#!/usr/bin/env bash
set -euo pipefail
#
# Reset a solomog vsphere cluster to its baseline snapshot: revert every node VM to
# "solomog-baseline" (fresh k3s + MetalLB — taken by `vsphere:create SNAPSHOT=true`
# or `vsphere:snapshot`), power back on, and wait for all nodes Ready. The homelab
# superpower vind can't match: a clean cluster in roughly VM-boot time instead of a
# full recreate. Everything installed AFTER the baseline (products, gateways, apps)
# is wiped; the kubeconfig context, registry entry, and node IPs all survive — the
# registry/allocator live outside the VMs, and reverting restores the same k3s CA
# the merged kubeconfig was minted from, so the context keeps working. (Re-running
# expose after a reset re-creates the gateway; MetalLB may hand out a different VIP,
# which the DNS=real upsert tracks automatically.)
# Spec: docs/specs/vsphere-provisioner.md (phase 4).
#
# Env:
#   CLUSTER     vsphere cluster name(s), space-separated (required — no default; wipes cluster state)
#   FORCE       "true" skips the confirmation prompt
#   VSPHERE_*   vCenter connection from .env

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

CLUSTERS="${CLUSTER:-}"
: "${CLUSTERS:?set CLUSTER=<name> — this wipes current cluster state, so no default}"

vsphere_preflight "vsphere:reset" conn
command -v kubectl >/dev/null || { echo "Error: kubectl not found." >&2; exit 1; }

# Validate every name before reverting anything — fail whole-batch, not mid-way.
for CLUSTER in $CLUSTERS; do
  if [ "$(vsphere_list_ips "$CLUSTER" | grep -c . || true)" -eq 0 ]; then
    echo "Error: no node allocations recorded for '${CLUSTER}' — is it a solomog vsphere cluster?" >&2
    exit 1
  fi
done

echo "About to REVERT to the 'solomog-baseline' snapshot: ${CLUSTERS}"
echo "  Everything installed after the baseline (products, gateways, apps) will be wiped."
if [ "${FORCE:-false}" != "true" ]; then
  printf "Proceed? [y/N] "
  read -r ANSWER
  [[ "$ANSWER" =~ ^[Yy] ]] || { echo "Aborted — nothing reverted."; exit 1; }
fi

for CLUSTER in $CLUSTERS; do
  CTX="$(vsphere_context_name "$CLUSTER")"
  NODE_COUNT="$(vsphere_list_ips "$CLUSTER" | grep -c . || true)"
  echo "==> Reverting '${CLUSTER}' (${NODE_COUNT} VMs)"
  vsphere_vm_tool revert "$CLUSTER"
  echo "==> waiting for ${NODE_COUNT} Ready node(s)"
  vsphere_wait_ready "$CTX" "$NODE_COUNT"
done

echo ""
echo "✓ Reset to baseline (fresh k3s + MetalLB): ${CLUSTERS}"
echo "  Rebuild from here, e.g.:  solomog agentgateway expose apps:utils ROUTE=true CLUSTER=${CLUSTERS%% *}"
