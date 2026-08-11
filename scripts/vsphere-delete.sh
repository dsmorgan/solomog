#!/usr/bin/env bash
set -euo pipefail
#
# Tear down solomog-created vSphere k3s cluster(s) — the complement to
# vsphere-create.sh: prompt once, then per cluster `tofu destroy` its workspace
# (ONLY state-tracked resources — never VMs enumerated by name from vCenter),
# delete the workspace, free the node-IP + LB-slice allocations, delete its
# DNS=real records, remove the vsphere_<name> kube context, and deregister from
# .solomog/contexts. Safe to re-run; each step no-ops when its work is already gone.
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env:
#   CLUSTER     vsphere cluster name(s), space-separated (required — no default; destructive)
#   FORCE       "true" skips the confirmation prompt (for scripted teardown)
#   VSPHERE_*   from .env (full set — destroy re-reads the placement data sources)
#   OPNSENSE_*  optional — when set, each cluster's DNS=real records are deleted too
#               (best-effort; expose recreates them on the next DNS=real run)
#
# Prereqs: OpenTofu (brew install opentofu) — lazy-checked, NOT a setup.sh prerequisite.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"
# shellcheck source=lib/opnsense.sh
source "$REPO_DIR/scripts/lib/opnsense.sh"

# DNS=real records are fully automated in both directions: expose upserts them, and
# teardown removes the cluster's (matched by the descr expose stamps — hand-made
# records are never touched). Best-effort: a failure only prints a warning.
delete_dns_records() {   # args: <cluster>
  solomog_opnsense_ready || return 0
  solomog_opnsense_dns_delete_cluster "$1" \
    || echo "    WARNING: OPNsense DNS cleanup failed — check Services → Dnsmasq DNS → Hosts for '*-$1' records." >&2
}

delete_one() {   # args: <cluster>
  local cluster="$1" ctx server_ip agent_ips_json
  ctx="$(vsphere_context_name "$cluster")"

  if ! "$TOFU" -chdir="$ROOT" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -qx "$cluster"; then
    echo "No tofu workspace '${cluster}' — nothing solomog-created to destroy."
    echo "  Workspaces: $("$TOFU" -chdir="$ROOT" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -v '^default$' | tr '\n' ' ')"
    # Still clean up any leftover registration/allocations/records from a partial create.
    vsphere_release_ips "$cluster"
    delete_dns_records "$cluster"
    solomog_deregister_context "$cluster"
    return 0
  fi

  # Destroy needs typed var values; recover the real IPs from the allocator (dummy
  # fallbacks are fine — destroy removes what's in state, not what the vars describe).
  server_ip="$(vsphere_list_ips "$cluster" | awk -F'\t' '$1=="server"{print $2}')"
  agent_ips_json="$(vsphere_list_ips "$cluster" | awk -F'\t' '$1!="server"{printf "%s\"%s\"", sep, $2; sep=","}')"
  export TF_VAR_cluster="$cluster"
  export TF_VAR_server_ip="${server_ip:-10.255.255.1}"
  export TF_VAR_agent_ips="[${agent_ips_json}]"

  echo "==> tofu destroy (workspace '${cluster}')"
  "$TOFU" -chdir="$ROOT" init -input=false >/dev/null
  "$TOFU" -chdir="$ROOT" workspace select "$cluster" >/dev/null
  "$TOFU" -chdir="$ROOT" destroy -input=false -auto-approve
  "$TOFU" -chdir="$ROOT" workspace select default >/dev/null
  "$TOFU" -chdir="$ROOT" workspace delete "$cluster" >/dev/null
  echo "    workspace '${cluster}' destroyed + deleted"

  vsphere_release_ips "$cluster"
  echo "    node IPs + LB slice released"
  delete_dns_records "$cluster"

  # Remove the merged kube entries (created by vsphere-create with one shared name).
  kubectl config delete-context "$ctx" >/dev/null 2>&1 || true
  kubectl config delete-cluster "$ctx" >/dev/null 2>&1 || true
  kubectl config delete-user    "$ctx" >/dev/null 2>&1 || true
  echo "    kube context '${ctx}' removed"

  solomog_deregister_context "$cluster"
}

CLUSTERS="${CLUSTER:-}"
: "${CLUSTERS:?set CLUSTER=<name> — destructive, so no default}"

vsphere_preflight "vsphere:delete" full

TOFU="${VSPHERE_TOFU_BIN:-tofu}"
ROOT="$REPO_DIR/terraform/vsphere-k3s"

echo "About to DESTROY vSphere k3s cluster(s) — all their VMs — on ${VSPHERE_SERVER}: ${CLUSTERS}"
if [ "${FORCE:-false}" != "true" ]; then
  printf "Proceed? [y/N] "
  read -r ANSWER
  [[ "$ANSWER" =~ ^[Yy] ]] || { echo "Aborted — nothing destroyed."; exit 1; }
fi

export VSPHERE_SERVER VSPHERE_USER VSPHERE_PASSWORD
export VSPHERE_ALLOW_UNVERIFIED_SSL="${VSPHERE_ALLOW_UNVERIFIED_SSL:-false}"
export TF_VAR_datacenter="$VSPHERE_DATACENTER"
export TF_VAR_compute_cluster="$VSPHERE_COMPUTE_CLUSTER"
export TF_VAR_datastore="$VSPHERE_DATASTORE"
export TF_VAR_network="$VSPHERE_NETWORK"
export TF_VAR_net_gateway="$VSPHERE_NET_GATEWAY"
export TF_VAR_net_dns="$VSPHERE_NET_DNS"
export TF_VAR_net_prefix="$VSPHERE_NET_PREFIX"

for CLUSTER in $CLUSTERS; do
  delete_one "$CLUSTER"
done

echo ""
echo "✓ Torn down: ${CLUSTERS}"
