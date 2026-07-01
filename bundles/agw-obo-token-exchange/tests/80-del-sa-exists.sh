#!/usr/bin/env bash
set -euo pipefail
kubectl --context "$CONTEXT" get serviceaccount obo-agent -n agentgateway-system >/dev/null
echo "✓ obo-agent service account exists"
