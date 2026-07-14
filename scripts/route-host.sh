#!/usr/bin/env bash
set -euo pipefail
#
# Routes an in-cluster Service through the gateway created by `solomog expose`, on
# its OWN sub-host nested under expose's wildcard — e.g. ui.agw.<cluster>.test.
#
# Why a sub-host instead of a path prefix: the Solo UI (served under /age/) and
# Grafana both assume they own their base path, so the httpbin-style "match /foo,
# rewrite prefix to /" trick breaks their assets. Giving each its own host and
# routing at "/" sidesteps all of that.
#
# Two things make this cheap:
#   * TLS — `expose` already mints a wildcard cert for HOST + *.HOST, so
#     <label>.agw.<cluster>.test is already covered. No new cert.
#   * Gateway — expose's listeners set no `hostname` and allow routes from all
#     namespaces, so they accept any sub-host and any namespace's HTTPRoute.
#
# The one catch: /etc/hosts has NO wildcard support (expose only writes the bare
# HOST). We append an explicit line for this sub-host (same LB IP). Needs sudo.
#
# Usage: route-host.sh <context> <cluster> <label> <svc> <svc-ns> <svc-port> [gw-name] [gw-ns]
#   label    sub-host label (e.g. "ui", "grafana")
#   gw-name  gateway to attach to (default agw)   — the host root we nest under
#   gw-ns    gateway namespace    (default agentgateway-system)

CONTEXT="${1:?Usage: route-host.sh <context> <cluster> <label> <svc> <svc-ns> <svc-port> [gw-name] [gw-ns]}"
CLUSTER="${2:?cluster required}"
LABEL="${3:?sub-host label required}"
SVC="${4:?service name required}"
SVC_NS="${5:?service namespace required}"
SVC_PORT="${6:?service port required}"
GW_NAME="${7:-agw}"
GW_NS="${8:-agentgateway-system}"

HOST="${LABEL}.${GW_NAME}.${CLUSTER}.test"

echo "==> Routing ${SVC}.${SVC_NS}:${SVC_PORT} → ${HOST} (via gateway ${GW_NAME}/${GW_NS}, at /)"

# HTTPRoute lives in the Service's namespace (so the backendRef is same-namespace —
# no ReferenceGrant needed), and attaches to the gateway in its own namespace.
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${LABEL}
  namespace: ${SVC_NS}
spec:
  parentRefs:
    - name: ${GW_NAME}
      namespace: ${GW_NS}
  hostnames:
    - ${HOST}
  rules:
    - backendRefs:
        - name: ${SVC}
          port: ${SVC_PORT}
EOF

# Resolve the gateway's LoadBalancer address and pin the sub-host to it in /etc/hosts.
if ! kubectl --context "$CONTEXT" get gateway "$GW_NAME" -n "$GW_NS" >/dev/null 2>&1; then
  echo "    NOTE: Gateway '${GW_NAME}' not found in ${GW_NS} — run 'solomog expose' so the route programs"
  echo "          and the wildcard cert/DNS exist, then re-run this with ROUTE=true."
  exit 0
fi

LB_IP="$(kubectl --context "$CONTEXT" get gateway "$GW_NAME" -n "$GW_NS" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
if [[ -z "$LB_IP" ]]; then
  echo "    NOTE: Gateway '${GW_NAME}' has no address yet — skipping /etc/hosts. Re-run after 'solomog expose'."
  exit 0
fi

echo "==> Updating /etc/hosts (sudo): ${HOST} → ${LB_IP}"
sudo sed -i '' "/[[:space:]]${HOST}\$/d;/[[:space:]]${HOST}[[:space:]]/d" /etc/hosts 2>/dev/null || true
echo "${LB_IP} ${HOST}" | sudo tee -a /etc/hosts >/dev/null

echo "    https://${HOST}/   (mkcert CA trusted; wildcard cert from 'solomog expose')"
