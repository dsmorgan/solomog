#!/usr/bin/env bash
set -euo pipefail
#
# Generates a shared root CA and per-cluster intermediate certs for Istio multi-cluster mTLS.
# Applies the cacerts secret to istio-system on each cluster (namespace created if absent).
#
# Certs are stored in certs/ (gitignored) and reused on subsequent runs.
# Delete certs/ to regenerate from a fresh root CA.
#
# Requires: step (brew install step)
#
# Usage: gen-certs.sh <cluster-name> [<cluster-name> ...]

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$REPO_DIR/certs"

if [[ $# -eq 0 ]]; then
  echo "Usage: gen-certs.sh <cluster-name> [<cluster-name> ...]" >&2
  exit 1
fi

CLUSTERS=("$@")

if ! command -v step &>/dev/null; then
  echo "Error: 'step' CLI not found — install with: brew install step" >&2
  exit 1
fi

mkdir -p "$CERTS_DIR/root"

# Root CA (shared across all clusters)
if [[ ! -f "$CERTS_DIR/root/root-cert.pem" ]]; then
  echo "==> Generating shared root CA..."
  step certificate create \
    "root.cluster.local" \
    "$CERTS_DIR/root/root-cert.pem" \
    "$CERTS_DIR/root/root-key.pem" \
    --profile root-ca \
    --no-password \
    --insecure \
    --not-after 87600h  # 10 years
else
  echo "==> Root CA already exists, reusing."
fi

for cluster in "${CLUSTERS[@]}"; do
  ctx="vcluster.${cluster}"
  cert_dir="$CERTS_DIR/$cluster"
  mkdir -p "$cert_dir"

  if [[ ! -f "$cert_dir/ca-cert.pem" ]]; then
    echo "==> Generating intermediate CA for: $cluster"
    step certificate create \
      "${cluster}.cluster.local" \
      "$cert_dir/ca-cert.pem" \
      "$cert_dir/ca-key.pem" \
      --ca "$CERTS_DIR/root/root-cert.pem" \
      --ca-key "$CERTS_DIR/root/root-key.pem" \
      --profile intermediate-ca \
      --no-password \
      --insecure \
      --not-after 43800h  # 5 years

    # cert-chain = intermediate + root (required by Istio)
    cat "$cert_dir/ca-cert.pem" "$CERTS_DIR/root/root-cert.pem" \
      > "$cert_dir/cert-chain.pem"
  else
    echo "==> Intermediate CA for '$cluster' already exists, reusing."
  fi

  echo "    Applying cacerts secret to $cluster (context: $ctx)..."
  kubectl --context "$ctx" \
    create namespace istio-system --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" \
    create secret generic cacerts \
    -n istio-system \
    --from-file=ca-cert.pem="$cert_dir/ca-cert.pem" \
    --from-file=ca-key.pem="$cert_dir/ca-key.pem" \
    --from-file=root-cert.pem="$CERTS_DIR/root/root-cert.pem" \
    --from-file=cert-chain.pem="$cert_dir/cert-chain.pem" \
    --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f -
done

echo ""
echo "==> Certificates ready."
