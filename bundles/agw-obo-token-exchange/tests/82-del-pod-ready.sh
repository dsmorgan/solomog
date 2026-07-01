#!/usr/bin/env bash
set -euo pipefail
kubectl --context "$CONTEXT" wait pod/obo-agent-test -n agentgateway-system \
  --for=condition=Ready --timeout=60s
echo "✓ obo-agent-test pod is Ready"
