#!/usr/bin/env bash
set -euo pipefail

NS=agentgateway-system
marker=solomog.bundle

curl --fail-with-body -sS "https://$HOST/logging/healthz" >/dev/null

attempt=0
while [ "$attempt" -lt 10 ]; do
  if kubectl --context "$CONTEXT" logs deployment/"$GATEWAY" -n "$NS" \
       --since=2m 2>/dev/null | grep -q "$marker"; then
    echo "  ✓ access log includes custom '$marker' attribute"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 2
done

echo "access log marker '$marker' not found in deployment/$GATEWAY logs" >&2
kubectl --context "$CONTEXT" logs deployment/"$GATEWAY" -n "$NS" \
  --since=2m 2>/dev/null || true
exit 1
