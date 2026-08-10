#!/usr/bin/env bash
set -euo pipefail
#
# Tear down a solomog-created vSphere k3s cluster — the complement to
# vsphere-create.sh: prompt, `tofu destroy` the cluster's workspace (ONLY
# state-tracked resources — never VMs enumerated by name from vCenter), delete the
# workspace, free the node-IP allocations, remove the vsphere_<name> kube context,
# and deregister from .solomog/contexts. Safe to re-run; each step no-ops when its
# work is already gone.
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env:
#   CLUSTER     vsphere cluster name (required — no default; destructive)
#   FORCE       "true" skips the confirmation prompt (for scripted teardown)
#   VSPHERE_*   from .env (full set — destroy re-reads the placement data sources)
#
# Prereqs: OpenTofu (brew install opentofu) — lazy-checked, NOT a setup.sh prerequisite.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<name> — destructive, so no default}"

vsphere_preflight "vsphere:delete" full

TOFU="${VSPHERE_TOFU_BIN:-tofu}"
ROOT="$REPO_DIR/terraform/vsphere-k3s"
CTX="$(vsphere_context_name "$CLUSTER")"

if ! "$TOFU" -chdir="$ROOT" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -qx "$CLUSTER"; then
  echo "No tofu workspace '${CLUSTER}' — nothing solomog-created to destroy."
  echo "  Workspaces: $("$TOFU" -chdir="$ROOT" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -v '^default$' | tr '\n' ' ')"
  # Still clean up any leftover registration/allocations from a partial create.
  vsphere_release_ips "$CLUSTER"
  solomog_deregister_context "$CLUSTER"
  exit 0
fi

echo "About to DESTROY the vSphere k3s cluster '${CLUSTER}' (all its VMs) on ${VSPHERE_SERVER}."
if [ "${FORCE:-false}" != "true" ]; then
  printf "Proceed? [y/N] "
  read -r ANSWER
  [[ "$ANSWER" =~ ^[Yy] ]] || { echo "Aborted — nothing destroyed."; exit 1; }
fi

# Destroy needs typed var values; recover the real IPs from the allocator (dummy
# fallbacks are fine — destroy removes what's in state, not what the vars describe).
SERVER_IP="$(vsphere_list_ips "$CLUSTER" | awk -F'\t' '$1=="server"{print $2}')"
AGENT_IPS_JSON="$(vsphere_list_ips "$CLUSTER" | awk -F'\t' '$1!="server"{printf "%s\"%s\"", sep, $2; sep=","}')"

export VSPHERE_SERVER VSPHERE_USER VSPHERE_PASSWORD
export VSPHERE_ALLOW_UNVERIFIED_SSL="${VSPHERE_ALLOW_UNVERIFIED_SSL:-false}"
export TF_VAR_cluster="$CLUSTER"
export TF_VAR_server_ip="${SERVER_IP:-10.255.255.1}"
export TF_VAR_agent_ips="[${AGENT_IPS_JSON}]"
export TF_VAR_datacenter="$VSPHERE_DATACENTER"
export TF_VAR_compute_cluster="$VSPHERE_COMPUTE_CLUSTER"
export TF_VAR_datastore="$VSPHERE_DATASTORE"
export TF_VAR_network="$VSPHERE_NETWORK"
export TF_VAR_net_gateway="$VSPHERE_NET_GATEWAY"
export TF_VAR_net_dns="$VSPHERE_NET_DNS"
export TF_VAR_net_prefix="$VSPHERE_NET_PREFIX"

echo "==> tofu destroy (workspace '${CLUSTER}')"
"$TOFU" -chdir="$ROOT" init -input=false >/dev/null
"$TOFU" -chdir="$ROOT" workspace select "$CLUSTER" >/dev/null
"$TOFU" -chdir="$ROOT" destroy -input=false -auto-approve
"$TOFU" -chdir="$ROOT" workspace select default >/dev/null
"$TOFU" -chdir="$ROOT" workspace delete "$CLUSTER" >/dev/null
echo "    workspace '${CLUSTER}' destroyed + deleted"

vsphere_release_ips "$CLUSTER"
echo "    node IPs released"

# Remove the merged kube entries (created by vsphere-create with one shared name).
kubectl config delete-context "$CTX" >/dev/null 2>&1 || true
kubectl config delete-cluster "$CTX" >/dev/null 2>&1 || true
kubectl config delete-user    "$CTX" >/dev/null 2>&1 || true
echo "    kube context '${CTX}' removed"

solomog_deregister_context "$CLUSTER"

echo ""
echo "✓ vSphere cluster '${CLUSTER}' torn down."
