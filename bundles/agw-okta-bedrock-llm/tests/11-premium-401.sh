#!/usr/bin/env bash
# Same as 10-standard-401.sh, other route.
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock/premium" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"hi"}]}')
[ "$status" -eq 401 ] || { echo "expected 401 (no token), got $status"; exit 1; }
echo "✓ /bedrock/premium rejects an unauthenticated request (401)"
