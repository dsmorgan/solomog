#!/usr/bin/env bash
set -euo pipefail
#
# Reset a solomog vsphere cluster to its baseline snapshot: revert every node VM to
# "solomog-baseline" (fresh k3s + MetalLB — taken by `vsphere:create SNAPSHOT=true`
# or `vsphere:snapshot`), power back on, and wait for all nodes Ready. The homelab
# superpower vind can't match: a clean cluster in roughly VM-boot time instead of a
# full recreate. Everything installed AFTER the baseline (products, gateways, apps)
# is wiped; the kubeconfig context, registry entry, node IPs, and pinned VIPs all
# survive — the registry/allocator live outside the VMs, and reverting restores the
# same k3s CA the merged kubeconfig was minted from, so the context keeps working.
# Spec: docs/specs/vsphere-provisioner.md (phase 4).
#
# Env:
#   CLUSTER     vsphere cluster name (required — no default; wipes cluster state)
#   FORCE       "true" skips the confirmation prompt
#   VSPHERE_*   vCenter connection from .env

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<name> — this wipes current cluster state, so no default}"

vsphere_preflight "vsphere:reset" conn
command -v kubectl >/dev/null || { echo "Error: kubectl not found." >&2; exit 1; }

CTX="$(vsphere_context_name "$CLUSTER")"
NODE_COUNT="$(vsphere_list_ips "$CLUSTER" | grep -c . || true)"
if [ "${NODE_COUNT:-0}" -eq 0 ]; then
  echo "Error: no node allocations recorded for '${CLUSTER}' — is it a solomog vsphere cluster?" >&2
  exit 1
fi

echo "About to REVERT '${CLUSTER}' (${NODE_COUNT} VMs) to the 'solomog-baseline' snapshot."
echo "  Everything installed after the baseline (products, gateways, apps) will be wiped."
if [ "${FORCE:-false}" != "true" ]; then
  printf "Proceed? [y/N] "
  read -r ANSWER
  [[ "$ANSWER" =~ ^[Yy] ]] || { echo "Aborted — nothing reverted."; exit 1; }
fi

vsphere_snapshot revert "$CLUSTER"

echo "==> waiting for ${NODE_COUNT} Ready node(s)"
DEADLINE=$(( $(date +%s) + 420 ))
while :; do
  READY="$(kubectl --context "$CTX" get nodes --no-headers --request-timeout=3s 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)"
  [ "${READY:-0}" -ge "$NODE_COUNT" ] && break
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Error: only ${READY:-0}/${NODE_COUNT} nodes Ready after 7 min." >&2
    kubectl --context "$CTX" get nodes >&2 || true
    exit 1
  fi
  sleep 5
done
echo "    ${READY} node(s) Ready"

echo ""
echo "✓ '${CLUSTER}' reset to baseline (fresh k3s + MetalLB) — context ${CTX} unchanged."
echo "  Rebuild from here, e.g.:  solomog agentgateway expose apps:utils ROUTE=true CLUSTER=${CLUSTER}"
