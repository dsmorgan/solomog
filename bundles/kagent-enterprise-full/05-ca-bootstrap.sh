#!/usr/bin/env bash
# The CA and JWT material Substrate mounts and no chart creates.
#
# Substrate issues certificates and tokens to actors, so it needs a private CA of its own. A chart
# can't create a private key, so this mints the pools before 20-substrate.sh runs. A projected
# Secret resolves in the namespace of the pod that mounts it, so each pool sits where its
# consumer runs:
#
#   ate-system
#     actor-id-ca-pool        ED25519    ate-api-server
#     actor-id-jwt-pool       ES256      ate-api-server
#     egress-mitm-ca-pool     ECDSAP256  atenet-egress (HTTPS credential injection)
#     actor-id-ca-certs       derived    atenet-egress: the actor root alone, under ca.crt
#     ate-api-authentication  ConfigMap  which service-account issuer ate-api-server trusts
#   podcertificate-controller-system
#     service-dns-ca-pool     ED25519    the certificate controller (substrate-podcert)
#     pod-identity-ca-pool    ED25519    the certificate controller
#     postgres-ca-pool        ED25519    the certificate controller refuses to start without it,
#                                        even when no PostgreSQL client certificate is requested
#
# kubectl-ate makes the pools: macOS openssl is LibreSSL and can't generate ED25519. Its
# make-*-pool subcommands talk only to the apiserver, so nothing needs to be running yet.
# Every pool is guarded on existence: regenerating one rotates the root under every issued
# certificate.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
say()  { printf '    %s\n' "$*"; }
good() { printf '    ✓ %s\n' "$*"; }

echo "==> CA bootstrap for Substrate ${KEF_SUBSTRATE_VERSION}"

# ── kubectl-ate, pinned and cached ───────────────────────────────────────────
case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) echo "    ✗ unsupported OS" >&2; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
REPO="$(cd "$HERE/../.." && pwd)"
ATE="$REPO/.solomog/bin/kubectl-ate-${KEF_ATE_CLI_VERSION}-${OS}-${ARCH}"
if [ ! -x "$ATE" ]; then
  URL="https://github.com/kagent-dev/substrate/releases/download/v${KEF_ATE_CLI_VERSION}/kubectl-ate-${OS}-${ARCH}"
  say "fetching kubectl-ate ${KEF_ATE_CLI_VERSION} (cached after this)"
  mkdir -p "$(dirname "$ATE")"
  curl -fsSL "$URL" -o "$ATE.part" || { rm -f "$ATE.part"; echo "    ✗ could not download ${URL}" >&2; exit 1; }
  chmod +x "$ATE.part"
  "$ATE.part" admin --help >/dev/null 2>&1 || { rm -f "$ATE.part"; echo "    ✗ the downloaded kubectl-ate doesn't run" >&2; exit 1; }
  mv "$ATE.part" "$ATE"
fi
good "kubectl-ate ${KEF_ATE_CLI_VERSION}"

# A failed first install blocks the retry; clear it before minting anything.
clear_failed_install "$CTX" substrate "$SUBSTRATE_NS"
clear_failed_install "$CTX" substrate-crds "$SUBSTRATE_NS"

for ns in "$SUBSTRATE_NS" "$PODCERT_NS"; do
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
done

ca_pool() {   # ca_pool NAME KEYTYPE NAMESPACE
  if k get secret "$1" -n "$3" >/dev/null 2>&1; then say "· $3/$1 exists, keeping it"; return 0; fi
  "$ATE" --context "$CTX" admin make-ca-pool --name "$1" --secret-namespace "$3" --ca-id 1 --key-type "$2" >/dev/null
  good "$3/$1 (CA pool, $2)"
}
if k get secret actor-id-jwt-pool -n "$SUBSTRATE_NS" >/dev/null 2>&1; then
  say "· ${SUBSTRATE_NS}/actor-id-jwt-pool exists, keeping it"
else
  "$ATE" --context "$CTX" admin make-jwt-pool --name actor-id-jwt-pool --secret-namespace "$SUBSTRATE_NS" --key-id 1 >/dev/null
  good "${SUBSTRATE_NS}/actor-id-jwt-pool (JWT pool, ES256)"
fi
ca_pool actor-id-ca-pool     ED25519   "$SUBSTRATE_NS"
ca_pool egress-mitm-ca-pool  ECDSAP256 "$SUBSTRATE_NS"
ca_pool service-dns-ca-pool  ED25519   "$PODCERT_NS"
ca_pool pod-identity-ca-pool ED25519   "$PODCERT_NS"
ca_pool postgres-ca-pool     ED25519   "$PODCERT_NS"

ROOT="$(k get secret actor-id-ca-pool -n "$SUBSTRATE_NS" -o jsonpath='{.data.tls\.crt}' | base64 -d)"
case "$ROOT" in *"BEGIN CERTIFICATE"*) ;; *) echo "    ✗ actor-id-ca-pool has no tls.crt" >&2; exit 1 ;; esac
k create secret generic actor-id-ca-certs -n "$SUBSTRATE_NS" --from-literal=ca.crt="$ROOT" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
good "${SUBSTRATE_NS}/actor-id-ca-certs"

# ate-api-server accepts a bearer token only when its iss equals this issuer exactly, so read it
# from the cluster. The CA and token files let it complete discovery against the in-cluster issuer.
ISSUER="$(k get --raw /.well-known/openid-configuration | jq -r .issuer)"
k create configmap ate-api-authentication -n "$SUBSTRATE_NS" --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: ${ISSUER}
  audiences: [api.${SUBSTRATE_NS}.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
good "${SUBSTRATE_NS}/ate-api-authentication (issuer ${ISSUER})"
