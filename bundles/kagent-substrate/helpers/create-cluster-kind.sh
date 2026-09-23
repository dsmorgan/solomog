#!/usr/bin/env bash
# Create a kind cluster that can run Agent Substrate, and register it with solomog so the
# bundle can target it as CLUSTER=<name> like any other.
#
#   bash bundles/kagent-substrate/helpers/create-cluster-kind.sh kas
#
# This is the PROVEN path — the same config substrate's own hack/create-kind-cluster.sh
# produces. Use it if the vind path fails on gVisor, or to get a known-good baseline when
# something in the bundle misbehaves and you need to rule the cluster out.
#
# What you give up versus vind: solomog's flat-network routing, expose/mkcert TLS and the
# LoadBalancer conveniences. None of them are needed here — substrate-scope and the kagent
# UI are both reached by port-forward.
set -euo pipefail

CLUSTER="${1:?usage: create-cluster-kind.sh <cluster-name>}"
NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.36.1}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CTX="kind-${CLUSTER}"

command -v kind >/dev/null || { echo "kind not found in PATH — brew install kind" >&2; exit 1; }

# Node image must be k8s 1.36+. kind v0.31.0 defaults to v1.35.0, where
# PodCertificateRequest is not a recognised gate: kubeadm silently drops it and the
# apiserver comes up with only ClusterTrustBundle=true. The runtimeConfig below targeting
# certificates.k8s.io/v1beta1 is the tell that substrate expects 1.36.
CFG="$(mktemp -t kind-substrate-XXXX.yaml)"
trap 'rm -f "$CFG"' EXIT
cat > "$CFG" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
featureGates:
  ClusterTrustBundle: true
  ClusterTrustBundleProjection: true
  PodCertificateRequest: true
runtimeConfig:
  "certificates.k8s.io/v1beta1": "true"
kubeadmConfigPatches:
- |
  kind: KubeletConfiguration
  serializeImagePulls: false
  maxParallelImagePulls: 4
YAML

_EXISTING="$(kind get clusters 2>/dev/null)"
if grep -qx "$CLUSTER" <<<"$_EXISTING"; then
  echo "==> kind cluster '$CLUSTER' already exists — not recreating."
else
  echo "==> Creating kind cluster '$CLUSTER' ($NODE_IMAGE)"
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config "$CFG"
fi

# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib/target.sh"
solomog_register_context "$CLUSTER" "$CTX"

echo "==> Waiting for the PodCertificateRequest API"
i=0
while [ "$i" -lt 30 ]; do
  RAW="$(kubectl --context "$CTX" get --raw /apis/certificates.k8s.io/v1beta1 2>/dev/null || true)"
  if grep -q podcertificaterequests <<<"$RAW"; then
    echo "    ✓ PodCertificateRequest present"
    echo
    echo "    Next: solomog apply BUNDLE=kagent-substrate CLUSTER=$CLUSTER"
    exit 0
  fi
  i=$((i + 1))
  sleep 2
done

echo "    ✗ PodCertificateRequest API missing after 60s — feature gates did not apply." >&2
echo "      Check the node image is k8s 1.36+: kubectl --context $CTX get nodes -o wide" >&2
exit 1
