#!/usr/bin/env bash
# Substrate: CRDs, the certificate controller, then the control plane, in native certificate mode.
#
# usePodCertificateAPI=true (the chart default) means every Substrate pod and worker gets its
# certificates from projected podCertificate and clusterTrustBundle volumes, which the vind
# feature gates in helpers/vcluster.yaml make available. No ate-ca compatibility layer, no
# ate-ca-agent sidecars, no trust ConfigMaps to copy into each namespace.
#
# Three releases, in this order:
#   substrate-crds     ate-system
#   substrate-podcert  podcertificate-controller-system: signs the podCertificate requests. The
#                      substrate chart doesn't deploy it; one serves the cluster.
#   substrate          ate-system. The release name MUST be `substrate`: the chart's fullname
#                      helper then emits bare object names (api, atenet-router), which kagent's
#                      default endpoints assume.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
h() { helm --kube-context "$CTX" "$@"; }
good() { printf '    ✓ %s\n' "$*"; }

echo "==> substrate-enterprise ${KEF_SUBSTRATE_VERSION} → ${SUBSTRATE_NS} (native certificates)"
for s in "$SUBSTRATE_NS/actor-id-ca-pool" "$SUBSTRATE_NS/substrate-postgres-owner" "$PODCERT_NS/postgres-ca-pool"; do
  k get secret "${s#*/}" -n "${s%%/*}" >/dev/null 2>&1 \
    || { echo "    ✗ secret ${s} missing: run 05-ca-bootstrap.sh and 10-postgres.sh first" >&2; exit 1; }
done

kef_anon_helm
VALUES="$(mktemp)"
trap 'rm -f "$VALUES"; rm -rf "${_KEF_ANON:-}"' EXIT
chmod 600 "$VALUES"   # carries the license key; kept off the command line

h upgrade --install substrate-crds "$(chart "$KEF_SUBSTRATE_CHARTS" substrate-crds "$KEF_SUBSTRATE_VERSION")" \
  --version "$KEF_SUBSTRATE_VERSION" -n "$SUBSTRATE_NS" --wait >/dev/null
good "substrate-crds"

h upgrade --install substrate-podcert "$(chart "$KEF_SUBSTRATE_CHARTS" substrate-podcert "$KEF_SUBSTRATE_VERSION")" \
  --version "$KEF_SUBSTRATE_VERSION" -n "$PODCERT_NS" --reset-values \
  --set image.tag="$KEF_SUBSTRATE_TAG" --wait --timeout 5m >/dev/null
good "substrate-podcert (certificate controller) in ${PODCERT_NS}"

# The credential provider is default-deny: an atespace reads Secrets only from namespaces a
# policy names. An agent's atespace is its namespace.
#
# otel.endpoint sends Substrate's metrics, router traces and actor events (OTLP logs) to kagent's
# telemetry collector, which writes them to ClickHouse's substrate_* tables: the UI dashboard's
# fleet figures. The collector arrives with 30-kagent.sh; until then the exporters retry.
# k8s-credential-provider doesn't get the OTEL_* env (enterprise-kagent#557).
cat > "$VALUES" <<EOF
usePodCertificateAPI: true
otel:
  endpoint: ${COLLECTOR_URL}
global:
  licensing:
    licenseKey: "${KEF_SUBSTRATE_LICENSE}"
credentialProvider:
  namespacePolicies:
  - atespace: ${KAGENT_NS}
    allowedNamespaces: [${KAGENT_NS}]
EOF

# 15 minutes: a cold node pulls about 570 MB of images.
if ! h upgrade --install substrate "$(chart "$KEF_SUBSTRATE_CHARTS" substrate "$KEF_SUBSTRATE_VERSION")" \
    --version "$KEF_SUBSTRATE_VERSION" -n "$SUBSTRATE_NS" --reset-values -f "$VALUES" --wait --timeout 15m; then
  echo "    ✗ substrate didn't become ready. Pods not Running:" >&2
  k get pods -n "$PODCERT_NS" 2>/dev/null | awk 'NR==1 || $3!="Running"' | sed 's/^/      /' >&2
  k get pods -n "$SUBSTRATE_NS" 2>/dev/null | awk 'NR==1 || $3!="Running"' | sed 's/^/      /' >&2
  echo "    Recent warnings:" >&2
  k get events -n "$SUBSTRATE_NS" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
    | tail -10 | sed 's/^/      /' >&2
  exit 1
fi
good "substrate ready"
k get pods -n "$SUBSTRATE_NS" --no-headers | awk '{print "      " $1 "  " $3}'
