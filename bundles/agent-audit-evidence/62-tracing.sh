# Span attributes, added to whichever tracing policy already owns the gateway.
#
# frontend.tracing is one proxy policy per Gateway, so a second policy setting it would conflict.
# `solomog agentgateway:ui` installs one named `tracing` (to the Solo UI collector): patch that one,
# backendRef untouched, so the UI's trace view shows the same identity as the access record. Create
# our own, pointed at the bundle's collector, only when the gateway has no tracing at all.
#
# Tracing also matters for the join: with it on, the gateway propagates W3C traceparent upstream, the
# agents forward it on their tool calls, and one trace.id ties checkpoint 1, the tool calls and each
# application's own log line together (tests/80).
#
# CONTEXT and GATEWAY exported by apply-bundle.sh.
set -euo pipefail

NS=agentgateway-system
EXISTING=$(kubectl --context "$CONTEXT" get enterpriseagentgatewaypolicy -n "$NS" \
  -o jsonpath="{range .items[?(@.spec.frontend.tracing)]}{.metadata.name}{'\n'}{end}" 2>/dev/null \
  | grep -v '^evidence-tracing$' | head -1 || true)

ATTRS='[
  {"name":"audit.agent.id","expression":"jwt.act.sub"},
  {"name":"audit.user.email","expression":"jwt.email"},
  {"name":"audit.token.scopes","expression":"jwt.scp"},
  {"name":"audit.declared.agent_name","expression":"request.headers[\"x-agent-name\"]"}
]'

if [ -n "$EXISTING" ]; then
  echo "==> span attributes: patching existing tracing policy '${EXISTING}' (backendRef untouched)"
  kubectl --context "$CONTEXT" patch enterpriseagentgatewaypolicy "$EXISTING" -n "$NS" \
    --type=merge -p "{\"spec\":{\"frontend\":{\"tracing\":{\"attributes\":{\"add\":${ATTRS}}}}}}" >/dev/null
  kubectl --context "$CONTEXT" delete enterpriseagentgatewaypolicy evidence-tracing -n "$NS" --ignore-not-found >/dev/null
  echo "✓ patched ${EXISTING}"
else
  echo "==> span attributes: no tracing policy on the gateway — creating evidence-tracing -> evidence-collector"
  kubectl --context "$CONTEXT" apply -f - <<YAML
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: evidence-tracing
  namespace: ${NS}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ${GATEWAY}
  frontend:
    tracing:
      backendRef:
        name: evidence-collector
        namespace: agent-evidence
        kind: Service
        port: 4317
      protocol: GRPC
      randomSampling: "true"
      attributes:
        add:
          - name: audit.agent.id
            expression: jwt.act.sub
          - name: audit.user.email
            expression: jwt.email
          - name: audit.token.scopes
            expression: jwt.scp
          - name: audit.declared.agent_name
            expression: request.headers["x-agent-name"]
YAML
  echo "✓ applied evidence-tracing"
fi
