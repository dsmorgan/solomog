#!/usr/bin/env bash
# Gateway-level JWT is Strict and runs PreRouting, so an unauthenticated request to the shared
# /bedrock path is rejected at the edge (401) before any routing/transformation happens.
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"hi"}]}')
[ "$status" -eq 401 ] || { echo "expected 401 (no token), got $status"; exit 1; }
echo "✓ /bedrock rejects an unauthenticated request (401)"
