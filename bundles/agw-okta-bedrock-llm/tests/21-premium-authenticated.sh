#!/usr/bin/env bash
# Same as 20-standard-authenticated.sh, premium route/model. Needs llm-premium in the
# cached token's groups claim (Lab 1 put you in both groups, so this should just work).
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached device token — run: bash bundles/agw-okta-bedrock-llm/helpers/okta-device-login.sh" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

curl --fail-with-body -sS "https://${HOST}/bedrock/premium" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Why is ocean water more blue in tropical locations?"}]}'
