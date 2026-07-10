#!/usr/bin/env bash
# CORE test: prove the SINGLE /bedrock path routes by Okta group. Decode the cached token's
# groups, compute the tier the gateway should pick (premium > standard), then hit /bedrock and
# assert the SERVED model matches that tier — Sonnet for premium, Haiku for standard. The model
# is read from the Bedrock response body (`.model`), which the pinned backend forces regardless
# of the requested model, so this directly proves which backend the header routed us to.
#
# Needs a cached token:  bash bundles/agw-okta-bedrock-llm2/helpers/okta-device-login.sh
# Real Bedrock call (costs tokens) + current AWS SSO creds — if it 401/403s on the AWS side,
# refresh: solomog aws:refresh apply BUNDLE=agw-okta-bedrock-llm2 CLUSTER=<cluster>
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached device token — run: bash bundles/agw-okta-bedrock-llm2/helpers/okta-device-login.sh" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "✗ cached token unreadable — re-run the login helper" >&2; exit 1; }

# Decode groups in python (same base64/json path the login helper uses). NB: never name the
# shell var GROUPS — it's a bash built-in (user GIDs); use TIER_GROUPS. See bundle1's 30- test.
RAW=$(TOKEN="$TOKEN" uv run --python 3.12 - <<'PY'
import base64, json, os
p = os.environ["TOKEN"].split(".")[1]; p += "=" * (-len(p) % 4)
groups = json.loads(base64.urlsafe_b64decode(p)).get("groups", [])
if not isinstance(groups, list): groups = []
print("TIER_GROUPS=" + json.dumps(groups))
print("HAS_STANDARD=" + ("true" if "llm-standard" in groups else "false"))
print("HAS_PREMIUM=" + ("true" if "llm-premium" in groups else "false"))
PY
)
TIER_GROUPS=$(printf '%s\n' "$RAW" | sed -n 's/^TIER_GROUPS=//p')
HAS_STANDARD=$(printf '%s\n' "$RAW" | sed -n 's/^HAS_STANDARD=//p')
HAS_PREMIUM=$(printf '%s\n' "$RAW" | sed -n 's/^HAS_PREMIUM=//p')

# Expected tier follows the gateway's precedence: premium beats standard.
if [ "$HAS_PREMIUM" = "true" ]; then
  want_tier=premium; want_model=sonnet
elif [ "$HAS_STANDARD" = "true" ]; then
  want_tier=standard; want_model=haiku
else
  echo "⊘ SKIP: cached token groups=$TIER_GROUPS include neither llm-standard nor llm-premium —"
  echo "  nothing to route. Get a tiered token (Okta group membership) and re-run."
  exit 0
fi
echo "cached token groups=$TIER_GROUPS -> expecting tier '$want_tier' (model contains '$want_model')"

# Capture body AND status separately (NOT --fail-with-body): under set -e a --fail-with-body
# non-zero exit aborts the script before we can print the captured body, so all you'd see is
# curl's terse "(22) ... 404" — not the Bedrock error JSON. This way any non-200 is shown in full.
resp=$(curl -sk -w $'\n%{http_code}' "https://${HOST}/bedrock" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"","messages":[{"role":"user","content":"Reply with the single word: ok"}]}')
code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" != "200" ]; then
  echo "✗ /bedrock returned HTTP $code (expected 200 for tier '$want_tier') — response body:"
  echo "$body"
  exit 1
fi

served=$(printf '%s' "$body" | jq -r '.model // empty' 2>/dev/null || true)
echo "served model: ${served:-<none>}"
case "$served" in
  *"$want_model"*) echo "✓ /bedrock routed a '$want_tier' token to the $want_model backend — group-based routing works" ;;
  *) echo "✗ expected a '$want_model' model for tier '$want_tier', got '${served:-<none>}'"; echo "$body"; exit 1 ;;
esac
