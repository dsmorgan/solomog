#!/usr/bin/env bash
# Positive half: a real Okta device-flow token (with llm-standard in its groups claim)
# reaches the standard-tier Bedrock backend. Needs a cached token:
#   bash bundles/agw-okta-bedrock-llm/helpers/okta-device-login.sh
# Real Bedrock call (costs tokens) and needs current AWS SSO creds — if it 401/403s on the
# AWS side (not the JWT), refresh: solomog aws:refresh apply BUNDLE=agw-okta-bedrock-llm CLUSTER=<cluster>
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached device token — run: bash bundles/agw-okta-bedrock-llm/helpers/okta-device-login.sh" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

curl --fail-with-body -sS "https://${HOST}/bedrock/standard" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
