#!/usr/bin/env bash
# Assert the premium token rate limit returns 429. The premium budget is a deliberately small
# 1,000 tokens/min (50-okta-tier-routing.sh), so a handful of LARGE requests trips it — no config
# mutation here, just enough real token spend to cross the budget. Each request asks for a long
# answer (max_tokens 1024 ≈ ~1k tokens), so 1-2 of them exceed 1k and the gateway starts 429ing.
#
# Single-endpoint bundle: we POST /bedrock and the PreRouting transform routes a llm-premium
# token to the premium route (where the limit lives). So the cached token must carry llm-premium
# — else it routes to standard (no limit). These are real Bedrock calls (a few thousand tokens).
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached device token — run the login helper first" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

# Only a premium token routes to the premium tier where the limit lives.
HAS_PREMIUM=$(TOKEN="$TOKEN" uv run --python 3.12 - <<'PY'
import base64, json, os
p = os.environ["TOKEN"].split(".")[1]; p += "=" * (-len(p) % 4)
g = json.loads(base64.urlsafe_b64decode(p)).get("groups", [])
print("true" if isinstance(g, list) and "llm-premium" in g else "false")
PY
)
[ "$HAS_PREMIUM" = "true" ] || { echo "⊘ SKIP: cached token has no llm-premium group — /bedrock would route to standard (no limit)."; exit 0; }

BODY='{"max_tokens":1024,"messages":[{"role":"user","content":"Write a detailed explanation, at least 600 words, of why ocean water appears more blue in tropical locations. Cover optics, phytoplankton, and depth."}]}'
TRIES="${RATELIMIT_TRIES:-10}"
hit429=0
for i in $(seq 1 "$TRIES"); do
  status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d "$BODY")
  echo "  request $i -> $status"
  [ "$status" = "429" ] && { hit429=1; break; }
done

[ "$hit429" = "1" ] || { echo "✗ no 429 within $TRIES large requests against a 1k-token/min budget — rate limit NOT enforcing" >&2; exit 1; }
echo "✓ premium rate limit returned 429 — token budget enforcing"
