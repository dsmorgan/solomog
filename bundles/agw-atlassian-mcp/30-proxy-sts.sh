# The agentgateway PROXY (data plane) needs to know where the in-cluster STS endpoint is, or
# elicitation-backed flows return "token exchange required but not configured" (proxy config shows
# tokenExchange: null). Set STS_URI + STS_AUTH_TOKEN on the proxy via EnterpriseAgentgatewayParameters
# and point the GatewayClass at it; the controller regenerates the proxy deployment WITH the STS env.
# Same wiring as agw-okta-mcp/88-snowflake-proxy-sts.sh. Workshop mcp-eager-auth-okta.md Step 4.
#
# NOTE (layering): patches the CLUSTER-SCOPED GatewayClass 'enterprise-agentgateway' — fine on a
# single-purpose PoV cluster. The long-term home is the agentgateway helmfile
# (gatewayClassParametersRefs + a managed params CR). Idempotent: re-applying the same params/ref is
# a no-op (no proxy restart unless values change). ⚠️ `solomog apply` re-runs this hook (rewrites the
# params CR to just STS env) — so it also clears any RUST_LOG you patched in for tracing; re-add after.
set -euo pipefail

STS_URI="http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/elicitations/oauth2/token"

echo "==> wiring proxy STS env (STS_URI) via EnterpriseAgentgatewayParameters + GatewayClass"
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: agentgateway-config
  namespace: agentgateway-system
spec:
  env:
    - name: STS_URI
      value: ${STS_URI}
    - name: STS_AUTH_TOKEN
      value: /var/run/secrets/xds-tokens/xds-token
EOF

kubectl --context "$CONTEXT" patch gatewayclass enterprise-agentgateway --type=merge -p='{"spec":{"parametersRef":{"group":"enterpriseagentgateway.solo.io","kind":"EnterpriseAgentgatewayParameters","name":"agentgateway-config","namespace":"agentgateway-system"}}}'

echo "✓ proxy STS env wired (STS_URI). The controller regenerates the proxy with the env; give it a"
echo "  few seconds to roll before testing."
