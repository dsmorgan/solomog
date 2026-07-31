#!/usr/bin/env bash
set -euo pipefail

NS=agentgateway-system

for policy in logging-direct-response logging-access-logs; do
  attached=Unknown
  attempt=0
  while [ "$attempt" -lt 12 ]; do
    attached="$(kubectl --context "$CONTEXT" get enterpriseagentgatewaypolicy "$policy" \
      -n "$NS" -o json 2>/dev/null | jq -r \
      '[.status.ancestors[]?.conditions[]? | select(.type=="Attached") | .status][0] // "Unknown"')"
    [ "$attached" = "True" ] && break
    attempt=$((attempt + 1))
    sleep 5
  done

  if [ "$attached" != "True" ]; then
    echo "  ✗ EnterpriseAgentgatewayPolicy/$policy attached=$attached"
    kubectl --context "$CONTEXT" get enterpriseagentgatewaypolicy "$policy" \
      -n "$NS" -o yaml
    exit 1
  fi
  echo "  ✓ EnterpriseAgentgatewayPolicy/$policy attached=True"
done
