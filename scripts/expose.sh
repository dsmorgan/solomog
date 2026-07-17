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
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-cluster-one}"
CTX="$(solomog_context "$CLUSTER")"   # vind default, or CONTEXT verbatim when external (EKS)
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
# vind: host is the local .test name (known up front). external (EKS): default the host to
# the cloud LB's public hostname, which we only learn AFTER the Gateway's LB provisions — so
# leave it empty here and resolve it below (unless the caller pinned a real DNS name via HOST).
if solomog_is_external "$CLUSTER"; then
  HOST="${HOST:-}"
else
  HOST="${HOST:-${NAME}.${CLUSTER}.test}"
fi
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

# Emit the Gateway manifest. $1=yes adds the HTTPS listener (needs the cert secret to exist).
emit_gateway() {   # args: <include_https: yes|no>
  local https=""
  if [[ "$1" == "yes" ]]; then
    https="
    - name: https
      port: ${HTTPS_PORT}
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${SECRET}
      allowedRoutes:
        namespaces:
          from: All"
  fi
  cat <<EOF
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
          from: All${https}
EOF
}

# Wait for the Gateway's LoadBalancer address (an IP on vind, a public hostname on a cloud LB).
wait_for_gateway_address() {   # args: <timeout-seconds>
  local addr="" elapsed=0 timeout="$1"
  until [[ -n "$addr" ]]; do
    addr=$(kubectl --context "$CTX" get gateway "$NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    [[ -n "$addr" ]] && break
    if [[ $elapsed -ge $timeout ]]; then
      echo "Error: timed out after ${timeout}s waiting for a Gateway address." >&2
      echo "       Check: kubectl --context $CTX get gateway $NAME -n $NAMESPACE" >&2
      exit 1
    fi
    echo "    waiting... (${elapsed}s)"; sleep 5; elapsed=$((elapsed + 5))
  done
  printf '%s' "$addr"
}

kubectl --context "$CTX" create namespace "$NAMESPACE" --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

if solomog_is_external "$CLUSTER"; then
  # ── EXTERNAL (cloud, e.g. EKS) ────────────────────────────────────────────
  # Public LB with self-signed TLS, no /etc/hosts. Two-pass: the cert must name the
  # LB's public hostname, which only exists once the Gateway's LB Service provisions.
  # So create the HTTP Gateway → wait for the hostname → mkcert it → re-apply with HTTPS.
  # We own the client's trust in this flow (the phase-4c agent bundles the mkcert CA),
  # which is why self-signed is fine. (A real DNS name + public cert can be pinned via HOST.)
  echo "==> Exposing gateway '${NAME}' (class ${CLASS}) in ${NAMESPACE} on EXTERNAL context ${CTX}"

  echo "==> Creating Gateway ${NAME} (HTTP listener; awaiting cloud LB hostname)"
  emit_gateway no | kubectl --context "$CTX" apply -f -

  echo "==> Waiting for the cloud LoadBalancer to assign a hostname (can take a few minutes)..."
  LB_ADDR="$(wait_for_gateway_address 300)"
  echo "    address: ${LB_ADDR}"

  HOST="${HOST:-$LB_ADDR}"
  echo "    TLS host: ${HOST}  secret=${SECRET}  http=${HTTP_PORT} https=${HTTPS_PORT}"

  echo "==> Generating mkcert (self-signed) TLS cert for ${HOST}"
  mkcert -install
  CERT_DIR="$(mktemp -d)"
  mkcert -cert-file "$CERT_DIR/tls.crt" -key-file "$CERT_DIR/tls.key" "$HOST"
  kubectl --context "$CTX" create secret tls "$SECRET" \
    --cert="$CERT_DIR/tls.crt" --key="$CERT_DIR/tls.key" -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
  rm -rf "$CERT_DIR"

  echo "==> Adding HTTPS listener to Gateway ${NAME}"
  emit_gateway yes | kubectl --context "$CTX" apply -f -

  echo ""
  echo "✓ Gateway '${NAME}' reachable over the public internet as ${HOST}"
  if [[ "$HTTPS_PORT" == "443" ]]; then HTTPS_URL="https://${HOST}/"; else HTTPS_URL="https://${HOST}:${HTTPS_PORT}/"; fi
  echo "  ${HTTPS_URL}   (self-signed — clients must trust the mkcert CA; see 'mkcert -CAROOT')"
  echo "  The ELB may take ~30–60s to register the new 443 port. Verify with a client that trusts the mkcert CA."
else
  # ── VIND (local) ──────────────────────────────────────────────────────────
  echo "==> Exposing gateway '${NAME}' (class ${CLASS}) in ${NAMESPACE} on ${CTX}"
  echo "    host=${HOST}  secret=${SECRET}  http=${HTTP_PORT} https=${HTTPS_PORT}"

  # 1. TLS cert via mkcert → secret  (ported from my-stuff/01-tls-setup.sh)
  echo "==> Generating mkcert TLS cert for ${HOST}, *.${HOST}"
  mkcert -install
  CERT_DIR="$(mktemp -d)"
  mkcert -cert-file "$CERT_DIR/tls.crt" -key-file "$CERT_DIR/tls.key" "$HOST" "*.$HOST"
  kubectl --context "$CTX" create secret tls "$SECRET" \
    --cert="$CERT_DIR/tls.crt" --key="$CERT_DIR/tls.key" -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
  rm -rf "$CERT_DIR"

  # 2. Create the Gateway (HTTP + HTTPS listeners; HTTPS terminates with the secret)
  echo "==> Creating Gateway ${NAME}"
  emit_gateway yes | kubectl --context "$CTX" apply -f -

  # 3. Wait for the LoadBalancer address  (ported from my-stuff/02-hosts-update.sh)
  echo "==> Waiting for the vcluster LoadBalancer to assign an address..."
  LB_IP="$(wait_for_gateway_address 150)"
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
fi
