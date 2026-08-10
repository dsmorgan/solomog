#!/usr/bin/env bash
set -euo pipefail
#
# Resume a stopped solomog vsphere cluster: power on every node VM and wait for all
# nodes Ready — the complement to vsphere-stop.sh. IPs, kubeconfig context, pinned
# VIPs, and everything installed on the cluster are unchanged (a whole-cluster
# shutdown/boot is a normal k3s recovery, and VMware syncs the guest clock at power
# on — no suspend-style clock jump).
# Spec: docs/specs/vsphere-provisioner.md (phase 4).
#
# Env:
#   CLUSTER     vsphere cluster name (required)
#   VSPHERE_*   vCenter connection from .env

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<name>}"

vsphere_preflight "vsphere:start" conn
command -v kubectl >/dev/null || { echo "Error: kubectl not found." >&2; exit 1; }

CTX="$(vsphere_context_name "$CLUSTER")"
NODE_COUNT="$(vsphere_list_ips "$CLUSTER" | grep -c . || true)"
if [ "${NODE_COUNT:-0}" -eq 0 ]; then
  echo "Error: no node allocations recorded for '${CLUSTER}' — is it a solomog vsphere cluster?" >&2
  exit 1
fi

echo "==> Starting '${CLUSTER}' (${NODE_COUNT} VMs)"
vsphere_vm_tool start "$CLUSTER"

echo "==> waiting for ${NODE_COUNT} Ready node(s)"
vsphere_wait_ready "$CTX" "$NODE_COUNT"

echo ""
echo "✓ '${CLUSTER}' running — everything as you left it (context ${CTX})."
