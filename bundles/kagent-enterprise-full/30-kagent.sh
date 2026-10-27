#!/usr/bin/env bash
# Enterprise kagent into its own namespace, with every component this release ships turned on.
#
# What's on, and the value that does it:
#   agentevals            agentevals.enabled starts the evaluation service (image tag defaults to
#                         the chart version); controller.agentevals.enabled runs the controller's
#                         agentevals migrations and turns on its eval API. It keeps its runs in
#                         PostgreSQL (the agentevals login from 10-postgres.sh) and writes results
#                         to ClickHouse database agentevals.
#   UI                    ui.enabled (default true). nginx in front of the SPA, the controller's
#                         API proxied under /api.
#   Bundled IdP           enterprise.oidc.issuer left empty. The controller pod gets an `idp`
#                         sidecar, the UI's nginx an /autoauth/ route, and the UI fetches an admin
#                         token itself, so there's no login page. It issues a token to anyone:
#                         treat this install as unauthenticated.
#   ClickHouse            clickhouse.enabled (default true). Where the UI's tracing pages read.
#   Telemetry collector   telemetry.enabled. Needs global.cluster, which it stamps on every span.
#   Trace export          config.telemetry.traces.endpoint (the controller) and
#                         config.runtimeDefaults.telemetry.traces.endpoint (every agent runtime),
#                         both at the collector's OTLP port. Neither is set by default.
#   Content capture       Not here: config.runtimeDefaults.telemetry.captureContent had no effect on
#                         the Go runtime at alpha11, so 40-agents.sh sets the env var on the Harness.
#   kmcp                  kmcp.enabled (default true). Deploys MCPServer resources (45-mcp-tool.sh).
#   gRPC reflection       config.server.grpcReflection, so grpcurl can list and call the API
#                         (helpers/api.sh). Off by default.
#   Substrate             controller.substrate.enabled and a WorkerPool of gVisor workers.
#
# And what's deliberately off:
#   global.istio.ambient  No Istio on this cluster; the flag only adds ambient labels.
#   enterprise.service    ClusterIP, not LoadBalancer: vind would make an haproxy container for the
#                         telemetry gateway, and nothing outside the cluster sends to it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
h() { helm --kube-context "$CTX" "$@"; }
good() { printf '    ✓ %s\n' "$*"; }

k get svc api -n "$SUBSTRATE_NS" >/dev/null 2>&1 \
  || { echo "    ✗ no Substrate api Service in ${SUBSTRATE_NS}: run 20-substrate.sh first" >&2; exit 1; }
k get secret kagent-postgres-readwrite -n "$KAGENT_NS" >/dev/null 2>&1 \
  || { echo "    ✗ no kagent-postgres-readwrite Secret in ${KAGENT_NS}: run 10-postgres.sh first" >&2; exit 1; }

kef_anon_helm
VALUES="$(mktemp)"
trap 'rm -f "$VALUES"; rm -rf "${_KEF_ANON:-}"' EXIT
chmod 600 "$VALUES"   # carries the license key

echo "==> kagent-enterprise-crds ${KEF_KAGENT_VERSION}"
h upgrade --install kagent-crds "$(chart "$KEF_KAGENT_CHARTS" kagent-enterprise-crds "$KEF_KAGENT_VERSION")" \
  --version "$KEF_KAGENT_VERSION" -n "$KAGENT_NS" --wait >/dev/null
good "kagent-enterprise-crds"

# The chart's default ModelConfig names this Secret. The agents use the mock model from
# 35-mock-model.sh, which ignores the key.
k create secret generic kagent-openai -n "$KAGENT_NS" --from-literal=OPENAI_API_KEY=mock-key \
  --dry-run=client -o yaml | k apply -f - >/dev/null

cat > "$VALUES" <<EOF
global:
  cluster: "${CLUSTER:-kef}"
  licensing:
    licenseKey: "${KEF_KAGENT_LICENSE}"
  istio:
    ambient:
      enabled: false
database:
  postgres:
    ownerConnectionStringSecretRef: {name: kagent-postgres-owner, key: ownerConnectionString}
    readWriteConnectionStringSecretRef: {name: kagent-postgres-readwrite, key: readWriteConnectionString}
config:
  server:
    grpcReflection: true
  telemetry:
    traces:
      endpoint: ${COLLECTOR_URL}
  runtimeDefaults:
    telemetry:
      traces:
        endpoint: ${COLLECTOR_URL}
enterprise:
  service:
    type: ClusterIP
telemetry:
  enabled: true
agentevals:
  enabled: true
  podLabels: {}   # the chart default enrolls it in Istio ambient
controller:
  agentevals:
    enabled: true
  substrate:
    enabled: true
substrateWorkerPool:
  create: true
  name: ${POOL}
  replicas: 2
  sandboxClass: ${SANDBOX_CLASS}
  workerImage: ${KEF_SUBSTRATE_IMAGES}/ateom-${SANDBOX_CLASS}:${KEF_SUBSTRATE_TAG}
EOF

echo "==> kagent-enterprise ${KEF_KAGENT_VERSION} → ${KAGENT_NS}"
clear_failed_install "$CTX" "$KAGENT_RELEASE" "$KAGENT_NS"
if ! h upgrade --install "$KAGENT_RELEASE" "$(chart "$KEF_KAGENT_CHARTS" kagent-enterprise "$KEF_KAGENT_VERSION")" \
    --version "$KEF_KAGENT_VERSION" -n "$KAGENT_NS" --reset-values -f "$VALUES" --wait --timeout 15m; then
  echo "    ✗ kagent didn't become ready. Containers not ready:" >&2
  k get pods -n "$KAGENT_NS" -o json 2>/dev/null | jq -r '.items[] | .metadata.name as $p
    | ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[]
    | select(.ready != true) | "      \($p) \(.name) restarts=\(.restartCount)"' >&2
  echo "    controller errors:" >&2
  k logs -n "$KAGENT_NS" deploy/kagent-controller -c controller 2>&1 | grep -iE '"level":"error"|ERROR' \
    | tail -5 | cut -c1-300 | sed 's/^/      /' >&2 || true
  exit 1
fi
good "kagent ready"
k get pods -n "$KAGENT_NS" --no-headers | awk '{print "      " $1 "  " $2 "  " $3}'
k get workerpools.ate.dev -A
