# ATTACH POINT 2 — gateway-enforced promptGuard (42-promptguard-bedrock.yaml.tmpl).
#
# The GATEWAY calls ApplyGuardrail before the model, so a block never reaches Bedrock's inference
# path at all and the deny is the gateway's own response — with the status code and message set
# in the policy. That makes this the assertable one: expect exactly 403.
#
# The backend behind this route carries NO guardrail of its own, so a 403 here can only have come
# from the policy. Compare: 10- (same prompt, no guardrail, 200) and 50- (same prompt, native
# passthrough, 200 + intervention text).
set -euo pipefail
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
code="$(curl -sS -o "$out" -w '%{http_code}' "https://$HOST/bedrock/guard/promptguard" \
  -H 'content-type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Should I buy Tesla stock right now?"}]}')"

echo "HTTP $code"; cat "$out"; echo

if [ "$code" = "403" ]; then
  echo "PASS: gateway denied the request with the policy status code"
  exit 0
fi

echo "FAIL: expected 403 from the promptGuard policy, got ${code}" >&2
case "$code" in
  200) echo "  200 = the guardrail did not fire. Either the policy is not attached to the" >&2
       echo "  bedrock-guard-promptguard HTTPRoute, or the DENY topic is missing:" >&2
       echo "    kubectl get enterpriseagentgatewaypolicy bedrock-promptguard -n agentgateway-system -o yaml" >&2 ;;
  401) echo "  401 = expired AWS creds in bedrock-secret. Refresh AND re-apply (refresh alone" >&2
       echo "  only rewrites .env; the hook is what pushes it into the cluster):" >&2
       echo "    solomog aws:refresh apply BUNDLE=llmroute-bedrock-guardrails CLUSTER=$CLUSTER" >&2 ;;
  5*)  echo "  5xx often means the guardrail CALL failed rather than denied — this filter has its" >&2
       echo "  OWN policies.auth.aws credential, separate from the backend, and its own region." >&2
       echo "  Check the proxy logs for an ApplyGuardrail error:" >&2
       echo "    kubectl logs -n agentgateway-system deploy/agw --tail=50" >&2 ;;
esac
exit 1
