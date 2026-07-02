#!/usr/bin/env bash
set -euo pipefail
kubectl --context "$CONTEXT" rollout status deployment/obo-agent-test \
  -n agentgateway-system --timeout=60s
echo "✓ obo-agent-test pod is Ready"
