# expose recipe for scripts/explain.sh. Sourced, not executed.

explain_task_expose() {
  local product="${PRODUCT:-agentgateway}"
  local name ns class host secret http_port https_port

  name="${NAME:-${GATEWAY:-}}"
  ns="${NAMESPACE:-${GATEWAY_NS:-}}"
  class="${CLASS:-}"
  host="${HOST}"
  secret="${SECRET:-}"
  http_port="${HTTP_PORT:-8080}"
  https_port="${HTTPS_PORT:-443}"

  if [ -z "$name" ] || [ -z "$ns" ] || [ -z "$class" ]; then
    case "$product" in
      kgateway)
        name="${name:-kgw}"
        ns="${ns:-kgateway-system}"
        if [ "$EDITION" = "community" ]; then
          class="${class:-kgateway}"
        else
          class="${class:-enterprise-kgateway}"
        fi
        ;;
      *)
        name="${name:-agw}"
        ns="${ns:-agentgateway-system}"
        if [ "$EDITION" = "community" ]; then
          class="${class:-agentgateway}"
        else
          class="${class:-enterprise-agentgateway}"
        fi
        ;;
    esac
  fi
  host="${host:-${name}.${CLUSTER}.test}"
  secret="${secret:-${name}-tls}"

  explain_section "expose"
  echo "# Create a Gateway (HTTP ${http_port} + HTTPS ${https_port})."
  echo "# Lab-only (skip on a real cluster): mint a TLS secret with mkcert for"
  echo "# ${host} and *.${host}, and point DNS or /etc/hosts at the LoadBalancer."
  echo "# CLASS is edition-aware; override with CLASS= if your GatewayClass differs."
  echo
  cat <<EOF
kubectl create namespace ${ns} --dry-run=client -o yaml | kubectl apply -f -

# kubectl create secret tls ${secret} -n ${ns} \\
#   --cert=tls.crt --key=tls.key

kubectl apply -f - <<'GW'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  gatewayClassName: ${class}
  listeners:
    - name: http
      port: ${http_port}
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      port: ${https_port}
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${secret}
      allowedRoutes:
        namespaces:
          from: All
GW
EOF
  echo
  echo "# Hostname to advertise: ${host}"
  echo
}
