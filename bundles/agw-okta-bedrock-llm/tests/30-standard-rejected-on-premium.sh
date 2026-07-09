#!/usr/bin/env bash
# Proves the CEL authorization gate actually fails CLOSED: a token that does NOT carry
# 'llm-premium' in its groups claim must be REJECTED on /bedrock/premium, not silently let
# through. This is the ⚠️ item flagged in 50-okta-jwt-authz.sh — `action: Allow` has no
# schema description, so this test is what actually proves its real semantics.
#
# Your Okta setup (Lab 1) put you in BOTH llm-standard and llm-premium, so your normal
# cached token always carries both groups and can't exercise this path. To run it for real:
#   1. Okta admin console: temporarily remove yourself from the llm-premium group
#   2. bash bundles/agw-okta-bedrock-llm/helpers/okta-device-login.sh   (re-auth -> fresh,
#      standard-only token)
#   3. bash bundles/agw-okta-bedrock-llm/tests/30-standard-rejected-on-premium.sh
#   4. Okta admin console: add yourself back to llm-premium
# Until then, this SKIPS (green) rather than false-failing on your dual-membership token.
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"

[ -f "$CACHE" ] || { echo "✗ no cached device token — run: bash bundles/agw-okta-bedrock-llm/helpers/okta-device-login.sh" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

# Decode the JWT + do the group-membership check entirely in Python (the same base64/json
# path okta-device-login.sh uses), printing clean `key=value` lines that bash then reads.
#
# ⚠️ Do NOT name the groups shell var `GROUPS`: that is a bash BUILT-IN special array (the
# current user's group IDs). Assigning to it is silently dropped, and `$GROUPS` then expands
# to a real GID (e.g. `20` = macOS `staff`) — which is exactly the bogus "20" / jq
# "Cannot index number" failure this test hit for real. We use TIER_GROUPS instead.
RAW=$(TOKEN="$TOKEN" uv run --python 3.12 - <<'PY'
import base64, json, os
t = os.environ["TOKEN"]
p = t.split(".")[1]
p += "=" * (-len(p) % 4)
groups = json.loads(base64.urlsafe_b64decode(p)).get("groups", [])
if not isinstance(groups, list):
    groups = []
print("TIER_GROUPS=" + json.dumps(groups))
print("HAS_STANDARD=" + ("true" if "llm-standard" in groups else "false"))
print("HAS_PREMIUM=" + ("true" if "llm-premium" in groups else "false"))
PY
)
# Parse the captured output with bash (printf|sed on an already-captured var is safe).
TIER_GROUPS=$(printf '%s\n' "$RAW" | sed -n 's/^TIER_GROUPS=//p')
HAS_STANDARD=$(printf '%s\n' "$RAW" | sed -n 's/^HAS_STANDARD=//p')
HAS_PREMIUM=$(printf '%s\n' "$RAW" | sed -n 's/^HAS_PREMIUM=//p')

if [ "$HAS_PREMIUM" = "true" ]; then
  echo "⊘ SKIP: cached token's groups=$TIER_GROUPS include llm-premium — can't test rejection with"
  echo "  this token. See this file's header comment for how to get a standard-only token."
  exit 0
fi
if [ "$HAS_STANDARD" != "true" ]; then
  echo "✗ cached token's groups=$TIER_GROUPS don't include llm-standard either — unexpected." >&2
  echo "  Re-run the login helper after confirming your Okta group membership." >&2
  exit 1
fi

echo "cached token groups=$TIER_GROUPS (llm-standard only) — expecting /bedrock/premium to reject it"
status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock/premium" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"hi"}]}')

if [ "$status" = "200" ]; then
  echo "✗ FAIL: an llm-standard-only token got 200 on /bedrock/premium — action:Allow is NOT" >&2
  echo "  failing closed as assumed. Swap to action:Require in 50-okta-jwt-authz.sh and retest." >&2
  exit 1
fi
echo "✓ /bedrock/premium rejected a llm-standard-only token (HTTP $status) — action:Allow gates as expected"
