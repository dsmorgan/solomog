#!/usr/bin/env bash
# JWT policy is Strict, so an unauthenticated request must be rejected at the edge (401)
# before it ever reaches the Bedrock backend. Negative half of the proof; 20- is positive.
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock/standard" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"hi"}]}')
[ "$status" -eq 401 ] || { echo "expected 401 (no token), got $status"; exit 1; }
echo "✓ /bedrock/standard rejects an unauthenticated request (401)"
