#!/usr/bin/env bash
set -euo pipefail
#
# Exposes a Gateway on a cluster for local access. Ports the old my-stuff/01 (TLS)
# and 02 (DNS) scripts and adds the missing piece — creating the Gateway itself.
#
#   1. Generates an mkcert TLS cert for HOST + *.HOST → a tls Secret.
#   2. Creates a Gateway (http:8080 + https:443/TLS) of the given GatewayClass.
#   3. Waits for the vcluster LoadBalancer (haproxy) to assign an address.
#   4. Updates /etc/hosts so HOST resolves to that address (needs sudo).
#      (/etc/hosts has no wildcard support — only the bare HOST is written here;
#       sub-hosts like ui.HOST are backfilled below / via route-host.sh.)
#
# PRODUCT picks sensible defaults for the gateway name, namespace, and class:
#   agentgateway → agw / agentgateway-system / enterprise-agentgateway|agentgateway
#   kgateway     → kgw / kgateway-system     / enterprise-kgateway|kgateway
# CLASS is resolved from whatever GatewayClass is actually on the cluster
# (edition-aware). Any of NAME / NAMESPACE / CLASS / HOST / SECRET can still be
# overridden directly (e.g. for istio).
#
# Env:
#   CLUSTER     cluster name (context vcluster-docker_<CLUSTER>); default cluster-one
#   PRODUCT     agentgateway | kgateway — seeds the defaults below. When unset it is
#               auto-detected from the cluster's GatewayClasses (one product per
#               cluster is the common case); falls back to agentgateway if ambiguous.
#   NAME        Gateway name;        default per PRODUCT (agw / kgw)
#   NAMESPACE   namespace;           default per PRODUCT
#   CLASS       gatewayClassName;    default: detected enterprise-* or community name
#   HOST        hostname for TLS+DNS; default <NAME>.<CLUSTER>.test
#               (.test is RFC 6761 reserved for testing; .local is avoided because
#                it collides with mDNS/Bonjour and resolves slowly. Including the
#                cluster keeps the host unique when several clusters are up at once.)
#   SECRET      tls secret name;     default <NAME>-tls
#   HTTP_PORT   HTTP listener port;  default 8080
#   HTTPS_PORT  HTTPS listener port; default 443

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gateway.sh
source "$REPO_DIR/scripts/lib/gateway.sh"

CLUSTER="${CLUSTER:-cluster-one}"
CTX="vcluster-docker_${CLUSTER}"
PRODUCT="${PRODUCT:-}"

classes="$(solomog_gateway_classes "$CTX")"

# Auto-detect PRODUCT from the cluster's GatewayClasses when not set explicitly.
if [[ -z "$PRODUCT" ]]; then
  PRODUCT="$(solomog_detect_product "$classes")"
  case "$PRODUCT" in
    kgateway)
      echo "==> Auto-detected PRODUCT=kgateway (kgateway GatewayClass present)"
      ;;
    agentgateway)
      if [[ "$classes" == *agentgateway* && "$classes" == *kgateway* ]]; then
        echo "==> Both gateway products detected — defaulting PRODUCT=agentgateway (pass PRODUCT=kgateway to override)"
      elif [[ "$classes" == *agentgateway* ]]; then
        echo "==> Auto-detected PRODUCT=agentgateway (agentgateway GatewayClass present)"
      else
        echo "==> No known GatewayClass detected — defaulting PRODUCT=agentgateway (pass PRODUCT explicitly if wrong)"
      fi
      ;;
  esac
fi

case "$PRODUCT" in
  agentgateway) _NAME=agw; _NS=agentgateway-system ;;
  kgateway)     _NAME=kgw; _NS=kgateway-system ;;
  *) _NAME=""; _NS="" ;;
esac
_CLASS="$(solomog_resolve_gateway_class "$PRODUCT" "$classes")"

NAME="${NAME:-$_NAME}"
NAMESPACE="${NAMESPACE:-$_NS}"
CLASS="${CLASS:-$_CLASS}"
HOST="${HOST:-${NAME}.${CLUSTER}.test}"
SECRET="${SECRET:-${NAME}-tls}"
HTTP_PORT="${HTTP_PORT:-8080}"
HTTPS_PORT="${HTTPS_PORT:-443}"

if [[ -z "$NAME" || -z "$NAMESPACE" || -z "$CLASS" ]]; then
  echo "Error: unknown PRODUCT '$PRODUCT'. Either use PRODUCT=agentgateway|kgateway," >&2
  echo "       or set NAME, NAMESPACE, and CLASS explicitly." >&2
  exit 1
fi

if ! command -v mkcert &>/dev/null; then
  echo "Error: mkcert not found. Install it:  brew install mkcert" >&2
  exit 1
fi

echo "==> Exposing gateway '${NAME}' (class ${CLASS}) in ${NAMESPACE} on ${CTX}"
echo "    host=${HOST}  secret=${SECRET}  http=${HTTP_PORT} https=${HTTPS_PORT}"

# 1. TLS cert via mkcert → secret  (ported from my-stuff/01-tls-setup.sh)
echo "==> Generating mkcert TLS cert for ${HOST}, *.${HOST}"
mkcert -install
CERT_DIR="$(mktemp -d)"
mkcert -cert-file "$CERT_DIR/tls.crt" -key-file "$CERT_DIR/tls.key" "$HOST" "*.$HOST"
kubectl --context "$CTX" create namespace "$NAMESPACE" --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -
kubectl --context "$CTX" create secret tls "$SECRET" \
  --cert="$CERT_DIR/tls.crt" --key="$CERT_DIR/tls.key" -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
rm -rf "$CERT_DIR"

# 2. Create the Gateway (HTTP + HTTPS listeners; HTTPS terminates with the secret)
echo "==> Creating Gateway ${NAME}"
kubectl --context "$CTX" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: ${CLASS}
  listeners:
    - name: http
      port: ${HTTP_PORT}
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      port: ${HTTPS_PORT}
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${SECRET}
      allowedRoutes:
        namespaces:
          from: All
EOF

# 3. Wait for the LoadBalancer address  (ported from my-stuff/02-hosts-update.sh)
echo "==> Waiting for the vcluster LoadBalancer to assign an address..."
LB_IP=""
ELAPSED=0; TIMEOUT=150
until [[ -n "$LB_IP" ]]; do
  LB_IP=$(kubectl --context "$CTX" get gateway "$NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  [[ -n "$LB_IP" ]] && break
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Error: timed out after ${TIMEOUT}s waiting for a Gateway address." >&2
    echo "       Check: kubectl --context $CTX get gateway $NAME -n $NAMESPACE" >&2
    exit 1
  fi
  echo "    waiting... (${ELAPSED}s)"; sleep 5; ELAPSED=$((ELAPSED + 5))
done
echo "    address: ${LB_IP}"

# 4. /etc/hosts  (needs sudo) — bare HOST only; wildcards are not supported.
echo "==> Updating /etc/hosts (sudo)"
sudo sed -i '' "/[[:space:]]${HOST}\$/d;/[[:space:]]${HOST}[[:space:]]/d" /etc/hosts 2>/dev/null || true
echo "${LB_IP} ${HOST}" | sudo tee -a /etc/hosts >/dev/null

# Backfill explicit entries for any sub-host routes already attached to this gateway
# (e.g. ui.${HOST}, grafana.${HOST} from agentgateway:ui / monitoring with ROUTE=true).
# /etc/hosts has no wildcard support, so each sub-host needs its own line. This makes
# ordering not matter: route-host.sh adds the entry when the gateway already exists,
# and expose backfills it when the route was created first. Requires jq (already a
# solomog dependency).
if command -v jq &>/dev/null; then
  SUBHOSTS="$(kubectl --context "$CTX" get httproute -A -o json 2>/dev/null \
    | jq -r --arg gw "$NAME" --arg suffix ".$HOST" '
        .items[]
        | select([.spec.parentRefs[]?.name] | index($gw))
        | .spec.hostnames[]?
        | select(endswith($suffix))' 2>/dev/null | sort -u || true)"
  for h in $SUBHOSTS; do
    sudo sed -i '' "/[[:space:]]${h}\$/d;/[[:space:]]${h}[[:space:]]/d" /etc/hosts 2>/dev/null || true
    echo "${LB_IP} ${h}" | sudo tee -a /etc/hosts >/dev/null
    echo "    + sub-host ${h} → ${LB_IP}"
  done
fi

echo ""
echo "✓ Gateway '${NAME}' reachable as ${HOST} → ${LB_IP}"
# Show the https port only when it isn't the default 443 (so the common case stays clean).
if [[ "$HTTPS_PORT" == "443" ]]; then HTTPS_URL="https://${HOST}/"; else HTTPS_URL="https://${HOST}:${HTTPS_PORT}/"; fi
echo "  http://${HOST}:${HTTP_PORT}/   and   ${HTTPS_URL}   (mkcert CA trusted)"
echo "  Attach routes with the per-app ROUTE flag, e.g.:  solomog apps:mcp-stripe ROUTE=true CLUSTER=${CLUSTER}"
