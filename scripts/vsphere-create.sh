#!/usr/bin/env bash
set -euo pipefail
#
# Create a k3s cluster on the homelab vCenter — the vSphere analog of eks-create.sh:
# allocate static node IPs → OpenTofu (workspace = cluster) clones the vsphere:init
# template into 1 server + NODES agent VMs (cloud-init installs pinned k3s) → fetch
# the kubeconfig over SSH and merge it as context vsphere_<cluster> → install MetalLB
# (LoadBalancer IPs from VSPHERE_LB_POOL) → register in .solomog/contexts, after
# which CLUSTER=<name> works across every solomog task. Idempotent: IP allocation,
# tofu apply, kubeconfig merge, helmfile sync and registration all re-run safely.
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env:
#   CLUSTER     cluster name (required — no default; this provisions real VMs)
#   NODES       agent count                        default 2 (VMs = NODES + 1 server)
#   SNAPSHOT    "true" → post-ready VM snapshot for vsphere:reset (spec phase 4)
#   VSPHERE_*   connection/placement/network from .env (preflight lists any missing)
#   K3S_VERSION / METALLB_VERSION   pinned in versions.env
#
# Prereqs: OpenTofu (brew install opentofu), kubectl, helmfile, ssh/scp — lazy-checked,
# NOT setup.sh additions. Requires `solomog vsphere:init` once beforehand.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<name> — this provisions real VMs on vCenter, so no default}"
NODES="${NODES:-2}"
case "$NODES" in (*[!0-9]*|'') echo "Error: NODES='$NODES' must be a number." >&2; exit 1 ;; esac

vsphere_preflight "vsphere:create" full
vsphere_require_init "vsphere:create"
command -v kubectl  >/dev/null || { echo "Error: kubectl not found." >&2; exit 1; }
command -v helmfile >/dev/null || { echo "Error: helmfile not found (brew install helmfile)." >&2; exit 1; }

TOFU="${VSPHERE_TOFU_BIN:-tofu}"
ROOT="$REPO_DIR/terraform/vsphere-k3s"
CTX="$(vsphere_context_name "$CLUSTER")"

PUBKEY_PATH="${VSPHERE_SSH_PUBKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
[ -f "$PUBKEY_PATH" ] || { echo "Error: SSH public key '$PUBKEY_PATH' not found — set VSPHERE_SSH_PUBKEY_PATH (or ssh-keygen -t ed25519)." >&2; exit 1; }

# Same IP, different host key after every rebuild/reset — pinning known_hosts would
# hard-fail each recreate, so skip it for these homelab-only nodes.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -o LogLevel=ERROR"

echo "==> vSphere k3s cluster '${CLUSTER}': 1 server + ${NODES} agent(s) on ${VSPHERE_SERVER}"

# ── 1. Static IPs (idempotent: an existing matching allocation is reused) ────────
ALLOC="$(vsphere_alloc_ips "$CLUSTER" $((NODES + 1)))"
SERVER_IP="$(printf '%s\n' "$ALLOC" | awk -F'\t' '$1=="server"{print $2}')"
AGENT_IPS="$(printf '%s\n' "$ALLOC" | awk -F'\t' '$1!="server"{print $2}')"
AGENT_IPS_JSON="$(printf '%s\n' "$AGENT_IPS" | awk 'NF{printf "%s\"%s\"", sep, $0; sep=","} END{print ""}')"
echo "    node IPs: server ${SERVER_IP}; agents $(printf '%s' "$AGENT_IPS" | tr '\n' ' ')"

# ── 2. OpenTofu: clone the VMs (workspace per cluster) ───────────────────────────
export VSPHERE_SERVER VSPHERE_USER VSPHERE_PASSWORD
export VSPHERE_ALLOW_UNVERIFIED_SSL="${VSPHERE_ALLOW_UNVERIFIED_SSL:-false}"
export TF_VAR_cluster="$CLUSTER"
export TF_VAR_server_ip="$SERVER_IP"
export TF_VAR_agent_ips="[${AGENT_IPS_JSON}]"
export TF_VAR_cpus="${VSPHERE_NODE_CPUS:-4}"
export TF_VAR_memory_gb="${VSPHERE_NODE_MEM_GB:-8}"
export TF_VAR_disk_gb="${VSPHERE_NODE_DISK_GB:-40}"
export TF_VAR_datacenter="$VSPHERE_DATACENTER"
export TF_VAR_compute_cluster="$VSPHERE_COMPUTE_CLUSTER"
export TF_VAR_datastore="$VSPHERE_DATASTORE"
export TF_VAR_network="$VSPHERE_NETWORK"
export TF_VAR_net_gateway="$VSPHERE_NET_GATEWAY"
export TF_VAR_net_dns="$VSPHERE_NET_DNS"
export TF_VAR_net_prefix="$VSPHERE_NET_PREFIX"
export TF_VAR_ssh_pubkey="$(cat "$PUBKEY_PATH")"
export TF_VAR_k3s_version="${K3S_VERSION:-}"

echo "==> tofu apply (workspace '${CLUSTER}')"
"$TOFU" -chdir="$ROOT" init -input=false >/dev/null
"$TOFU" -chdir="$ROOT" workspace select -or-create "$CLUSTER" >/dev/null
"$TOFU" -chdir="$ROOT" apply -input=false -auto-approve

# ── 3. Kubeconfig: wait for SSH + k3s, then merge as context vsphere_<cluster> ───
echo "==> waiting for k3s on ${SERVER_IP} (SSH + kubeconfig; cloud-init installs on first boot)"
KUBE_TMP="$(mktemp)"; trap 'rm -f "$KUBE_TMP"' EXIT
DEADLINE=$(( $(date +%s) + 420 ))
until ssh $SSH_OPTS "solomog@${SERVER_IP}" sudo cat /etc/rancher/k3s/k3s.yaml > "$KUBE_TMP" 2>/dev/null \
      && [ -s "$KUBE_TMP" ]; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Error: k3s server not up on ${SERVER_IP} after 7 min." >&2
    echo "  Debug: ssh solomog@${SERVER_IP}  then  sudo cloud-init status --long; sudo journalctl -u k3s" >&2
    exit 1
  fi
  sleep 5
done

# k3s writes 127.0.0.1 + names everything "default" — point at the server and
# namespace the entries so multiple vsphere clusters can coexist in one kubeconfig.
sed -E -i '' \
  -e "s#https://127\.0\.0\.1:6443#https://${SERVER_IP}:6443#" \
  -e "s/^(( *-)? *(name|cluster|user|current-context)): default$/\1: ${CTX}/" \
  "$KUBE_TMP"

mkdir -p "$HOME/.kube"
if [ -f "$HOME/.kube/config" ]; then
  cp "$HOME/.kube/config" "$HOME/.kube/config.solomog-bak"
  MERGED="$(KUBECONFIG="$KUBE_TMP:$HOME/.kube/config" kubectl config view --flatten)"
  printf '%s\n' "$MERGED" > "$HOME/.kube/config"
else
  cp "$KUBE_TMP" "$HOME/.kube/config"
fi
chmod 600 "$HOME/.kube/config"
echo "    kube context '${CTX}' merged (backup: ~/.kube/config.solomog-bak)"

echo "==> waiting for $((NODES + 1)) Ready node(s)"
DEADLINE=$(( $(date +%s) + 420 ))
while :; do
  READY="$(kubectl --context "$CTX" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -c . || true)"
  [ "${READY:-0}" -ge $((NODES + 1)) ] && break
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Error: only ${READY:-0}/$((NODES + 1)) nodes Ready after 7 min." >&2
    kubectl --context "$CTX" get nodes >&2 || true
    exit 1
  fi
  sleep 5
done
echo "    ${READY} node(s) Ready"

# ── 4. MetalLB (the LoadBalancer vind/EKS gave for free — what `expose` rides on) ─
echo "==> installing MetalLB + address pool ${VSPHERE_LB_POOL}"
helmfile sync -f "$REPO_DIR/helmfiles/addons/metallb.yaml.gotmpl" --kube-context "$CTX"
i=0
until kubectl --context "$CTX" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: solomog-pool
  namespace: metallb-system
spec:
  addresses:
    - ${VSPHERE_LB_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: solomog-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - solomog-pool
EOF
do
  i=$((i + 1)); [ "$i" -ge 6 ] && { echo "Error: MetalLB CRs would not apply (webhook not ready?)." >&2; exit 1; }
  echo "    MetalLB webhook not ready yet — retrying ($i/5)"; sleep 5
done

if [ "${SNAPSHOT:-false}" = "true" ]; then
  echo "    (SNAPSHOT=true noted — baseline snapshots + vsphere:reset land in spec phase 4)"
fi

# ── 5. Register — from here CLUSTER=<name> works like any vind/EKS cluster ───────
solomog_register_context "$CLUSTER" "$CTX"

echo ""
echo "✓ vSphere k3s cluster ready — context: ${CTX}"
echo "  server ${SERVER_IP} + ${NODES} agent(s); LoadBalancer pool ${VSPHERE_LB_POOL}"
echo "  Now just use CLUSTER=${CLUSTER}:"
echo "    solomog agentgateway expose apps:utils ROUTE=true CLUSTER=${CLUSTER}   # smoke test"
echo "    solomog apply BUNDLE=<bundle> CLUSTER=${CLUSTER}"
echo "    solomog vsphere:delete CLUSTER=${CLUSTER}                              # tear down"
