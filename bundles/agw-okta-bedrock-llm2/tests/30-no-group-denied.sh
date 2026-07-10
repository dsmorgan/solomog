#!/usr/bin/env bash
# Proves the "deny if neither" behavior: a valid Okta token whose groups include NEITHER
# llm-standard NOR llm-premium produces x-llm-tier: none, which matches no route -> the gateway
# returns 404 (no fallback route defined). The token is still authentically signed — this is a
# routing denial, not an auth failure.
#
# Your Okta user is normally in llm-standard and/or llm-premium, so your cached token DOES
# carry a tier and can't exercise this path. To run it for real:
#   1. Okta admin console: temporarily remove yourself from BOTH llm-standard and llm-premium
#   2. bash bundles/agw-okta-bedrock-llm2/helpers/okta-device-login.sh   (fresh, group-less token)
#   3. bash bundles/agw-okta-bedrock-llm2/tests/30-no-group-denied.sh
#   4. Okta admin console: add yourself back to your group(s)
# Until then it SKIPS (green) rather than false-failing on your tiered token.
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached device token — run the login helper first" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

RAW=$(TOKEN="$TOKEN" uv run --python 3.12 - <<'PY'
import base64, json, os
p = os.environ["TOKEN"].split(".")[1]; p += "=" * (-len(p) % 4)
groups = json.loads(base64.urlsafe_b64decode(p)).get("groups", [])
if not isinstance(groups, list): groups = []
has_tier = ("llm-standard" in groups) or ("llm-premium" in groups)
print("TIER_GROUPS=" + json.dumps(groups))
print("HAS_TIER=" + ("true" if has_tier else "false"))
PY
)
TIER_GROUPS=$(printf '%s\n' "$RAW" | sed -n 's/^TIER_GROUPS=//p')
HAS_TIER=$(printf '%s\n' "$RAW" | sed -n 's/^HAS_TIER=//p')

if [ "$HAS_TIER" = "true" ]; then
  echo "⊘ SKIP: cached token groups=$TIER_GROUPS include a tier — can't test the no-group denial."
  echo "  See this file's header for how to get a group-less token."
  exit 0
fi

echo "cached token groups=$TIER_GROUPS (no tier) — expecting /bedrock to deny (no matching route)"
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"hi"}]}')
case "$status" in
  404|403) echo "✓ group-less token denied on /bedrock (HTTP $status) — no tier route matched" ;;
  200) echo "✗ FAIL: a group-less token got 200 — it should not route to any tier"; exit 1 ;;
  *) echo "✗ unexpected status $status (wanted 404/403)"; exit 1 ;;
esac
