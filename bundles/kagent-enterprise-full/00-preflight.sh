#!/usr/bin/env bash
# Preflight: refuse to install onto a cluster that can't run Substrate in native certificate mode.
#
# Each check maps to a failure that otherwise surfaces minutes later and reads like a product
# bug. A missing feature gate doesn't error: it silently drops the projected certificate volume,
# and the first symptom is a pod that never starts.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
FAIL=0
say()  { printf '    %s\n' "$*"; }
bad()  { printf '    ✗ %s\n' "$*"; FAIL=1; }
good() { printf '    ✓ %s\n' "$*"; }
RECREATE="solomog vind:create CLUSTER=<name> VCLUSTER_VALUES=bundles/kagent-enterprise-full/helpers/vcluster.yaml"

echo "==> preflight: can this cluster run kagent Enterprise on Substrate?"

# A chained `vind:create … apply` can reach this while the node is still joining.
for _ in $(seq 1 24); do
  [ "$(k get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)" -ge 1 ] && break
  sleep 5
done

VER="$(k version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' | sed 's/^v//; s/\.[0-9]*$//')"
case "$VER" in
  1.3[6-9]|1.[4-9][0-9]) good "kubernetes v${VER}" ;;
  "") bad "could not read the server version from context ${CTX}" ;;
  *)  bad "kubernetes v${VER}: PodCertificateRequest needs 1.36 or later" ;;
esac

# `get --raw`, not `api-resources`: discovery is cached under ~/.kube/cache, and a rebuilt cluster
# on the same host:port answers from the previous cluster's document for minutes.
if k get --raw /apis/certificates.k8s.io/v1beta1 2>/dev/null | grep -q podcertificaterequests; then
  good "certificates.k8s.io/v1beta1 serves podcertificaterequests"
else
  bad "no PodCertificateRequest API: the feature gates didn't apply. Recreate with: ${RECREATE}"
fi
if k get clustertrustbundles >/dev/null 2>&1; then
  good "ClusterTrustBundle is served"
else
  bad "ClusterTrustBundle isn't served. Recreate with: ${RECREATE}"
fi

# vind advertises 127.0.0.1 as the apiserver address, and unless --service-account-jwks-uri is
# set, the discovery document's jwks_uri points there: every pod's own loopback. ate-api-server
# then rejects every service-account token, long after the install looked healthy.
JWKS="$(k get --raw /.well-known/openid-configuration 2>/dev/null | jq -r '.jwks_uri // empty')"
case "$JWKS" in
  "") say "? could not read jwks_uri; continuing" ;;
  *127.0.0.1*|*localhost*) bad "jwks_uri is ${JWKS}, which no pod can reach. Recreate with: ${RECREATE}" ;;
  *) good "jwks_uri is pod-reachable (${JWKS})" ;;
esac

[ -n "$KEF_KAGENT_LICENSE" ] && good "kagent license (KAGENT_LICENSE_KEY or SOLO_LICENSE_KEY)" \
  || bad "no kagent license: set KAGENT_LICENSE_KEY in .env"
[ -n "$KEF_SUBSTRATE_LICENSE" ] && good "substrate license (AGENTGATEWAY_LICENSE_KEY)" \
  || bad "no substrate license: set AGENTGATEWAY_LICENSE_KEY in .env (atenet-router runs agentgateway)"
command -v go >/dev/null && good "go (tests build helpers/a2a-turn)" \
  || say "? no go on PATH: the install works, but the turn tests can't build their client"

if [ "$FAIL" -ne 0 ]; then
  echo "    preflight failed; nothing was installed."
  exit 1
fi
echo "    preflight passed"
