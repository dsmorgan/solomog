#!/usr/bin/env bash
# Control: is this a cluster substrate can run on at all?
#
# Runs first so that a cluster problem never gets read as a substrate defect. If this
# fails, nothing below it is worth debugging.
set -euo pipefail

CTX="${CONTEXT:?CONTEXT not set}"
rc=0

echo "── cluster prerequisites (context $CTX)"

VER="$(kubectl --context "$CTX" version -o json 2>/dev/null \
  | sed -n 's/.*"gitVersion": *"v\([0-9]*\.[0-9]*\)[^"]*".*/\1/p' | tail -1)"
case "$VER" in
  1.3[6-9]|1.[4-9]*|[2-9].*) echo "  ✓ kubernetes v${VER}" ;;
  *) echo "  ✗ kubernetes v${VER:-unknown} — substrate needs 1.36+"; rc=1 ;;
esac

RAW="$(kubectl --context "$CTX" get --raw /apis/certificates.k8s.io/v1beta1 2>/dev/null || true)"
if grep -q podcertificaterequests <<<"$RAW"; then
  echo "  ✓ PodCertificateRequest served"
else
  echo "  ✗ PodCertificateRequest missing — feature gates are not applied"
  echo "    A missing gate does not error: the projected podcert volume source is"
  echo "    SILENTLY DROPPED, and the first visible symptom is postgres failing with"
  echo "    'could not load server certificate file'. Rebuild with helpers/create-cluster-*.sh"
  rc=1
fi

if kubectl --context "$CTX" get clustertrustbundles >/dev/null 2>&1; then
  echo "  ✓ ClusterTrustBundle served"
else
  echo "  ✗ ClusterTrustBundle not served"
  rc=1
fi

# Belongs in the cheap control because its real symptom is expensive: every token validation
# fails, but only ever visibly as an ActorTemplate that never bakes a golden, minutes later,
# in a different component's logs.
JWKS_URI="$(kubectl --context "$CTX" get --raw /.well-known/openid-configuration 2>/dev/null \
  | sed -n 's/.*"jwks_uri": *"\([^"]*\)".*/\1/p')"
case "$JWKS_URI" in
  "") echo "  · jwks_uri unreadable — skipping that check" ;;
  https://127.0.0.1*|https://localhost*|http://127.0.0.1*|http://localhost*)
    echo "  ✗ jwks_uri is '$JWKS_URI' — loopback, unreachable from any pod"
    echo "    substrate's ate-api-server fetches this to validate bearer tokens. It will"
    echo "    install cleanly and then fail every one:"
    echo "      invalid bearer token: while discovering keys from issuer: connection refused"
    echo "    Recreate with: solomog vind:create CLUSTER=<name> \\"
    echo "      VCLUSTER_VALUES=bundles/kagent-substrate/helpers/vcluster-substrate.yaml"
    rc=1 ;;
  *) echo "  ✓ jwks_uri pod-reachable ($JWKS_URI)" ;;
esac

exit $rc
