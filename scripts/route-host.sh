#!/usr/bin/env bash
set -euo pipefail
#
# Routes an in-cluster Service through the gateway created by `solomog expose`, on
# its OWN sub-host — e.g. ui.agw.<cluster>.test, or ui-agw-<cluster>.<domain> when
# the gateway was exposed with DNS=real.
#
# Why a sub-host instead of a path prefix: the Solo UI (served under /age/) and
# Grafana both assume they own their base path, so the httpbin-style "match /foo,
# rewrite prefix to /" trick breaks their assets. Giving each its own host and
# routing at "/" sidesteps all of that.
#
# The DNS mode comes from the gateway itself: expose stamps the reachable base host
# on the Gateway (solomog.io/host annotation), and the sub-host derives from it —
#   local  agw.<cluster>.test        → <label>.agw.<cluster>.test  (nested under the
#          mkcert HOST + *.HOST wildcard; /etc/hosts line, sudo)
#   real   agw-<cluster>.<domain>    → <label>-agw-<cluster>.<domain>  (FLAT — still
#          one label, so the same *.<domain> LE cert covers it; DNS record upserted
#          via the OPNsense API like expose does, no /etc/hosts)
# Either way expose's listeners set no `hostname` and allow all namespaces, so the
# gateway accepts the sub-host route without changes.
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

# Base host: what expose stamped on the Gateway (encodes the DNS mode); fall back
# to the local default when the gateway/annotation doesn't exist yet.
GW_HOST="$(kubectl --context "$CONTEXT" get gateway "$GW_NAME" -n "$GW_NS" \
  -o jsonpath='{.metadata.annotations.solomog\.io/host}' 2>/dev/null || true)"
[ -n "$GW_HOST" ] || GW_HOST="${GW_NAME}.${CLUSTER}.test"
case "$GW_HOST" in
  *.test) DNS_MODE=local; HOST="${LABEL}.${GW_HOST}" ;;
  *)      DNS_MODE=real;  HOST="${LABEL}-${GW_HOST}" ;;   # flat: one label under *.<domain>
esac

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

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
if [ "$DNS_MODE" = "real" ]; then
  # Same automation as expose's DNS=real endgame: upsert the record, manual fallback.
  # The descr prefix "solomog <cluster>/" is what vsphere:delete matches for cleanup.
  # shellcheck source=lib/opnsense.sh
  source "$LIB_DIR/opnsense.sh"
  DNS_LABEL="${HOST%%.*}"; DOMAIN="${HOST#*.}"
  echo "==> DNS: upserting ${HOST} → ${LB_IP} via the OPNsense API"
  UPSERT_RC=0
  if solomog_opnsense_ready; then
    solomog_opnsense_dns_upsert "$DNS_LABEL" "$DOMAIN" "$LB_IP" "solomog ${CLUSTER}/${LABEL}-${GW_NAME} (DNS=real)" || UPSERT_RC=$?
  else
    UPSERT_RC=1
  fi
  if [ "$UPSERT_RC" -eq 2 ]; then
    # rc=2: the record saved but the dnsmasq apply failed — don't tell the user to create it.
    echo "    NOTE: record saved but not applied — press Apply in the OPNsense UI, or re-run this task."
  elif [ "$UPSERT_RC" -ne 0 ]; then
    echo "    NOTE: OPNsense API upsert failed — add the record manually (Services → Dnsmasq DNS → Hosts):"
    echo "          host=${DNS_LABEL}  domain=${DOMAIN}  ip=${LB_IP}"
  fi
  echo "    https://${HOST}/   (covered by the *.${DOMAIN} Let's Encrypt cert from 'solomog expose')"
else
  echo "==> Updating /etc/hosts (sudo): ${HOST} → ${LB_IP}"
  # shellcheck source=lib/hosts.sh
  source "$LIB_DIR/hosts.sh"
  solomog_hosts_set "$HOST" "$LB_IP"
  echo "    https://${HOST}/   (mkcert CA trusted; wildcard cert from 'solomog expose')"
fi
