#!/usr/bin/env bash
# Best-effort/manual: the premium tier's rateLimit.local budget is 100k tokens/min (see
# 50-okta-jwt-authz.sh) — high enough that a quick loop may not trip it without burning real
# Bedrock spend. This fires a modest burst of small requests and reports whether a 429 showed
# up; it does NOT hard-fail if the limit wasn't hit (expected at this budget size for a
# handful of calls) — treat it as a smoke check, not a strict assertion. To actually validate
# the ceiling, temporarily lower tokens/burst in 50-okta-jwt-authz.sh, re-apply, run this,
# then restore.
set -euo pipefail
CACHE="$(cd "$(dirname "$0")/../../.." && pwd)/.solomog/okta-device-token.json"
[ -f "$CACHE" ] || { echo "✗ no cached device token — run the login helper first" >&2; exit 1; }
TOKEN=$(jq -r '.access_token' "$CACHE")

TRIES="${RATELIMIT_TRIES:-10}"
hit429=0
for i in $(seq 1 "$TRIES"); do
  status=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "https://${HOST}/bedrock/premium" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"model":"","messages":[{"role":"user","content":"hi"}]}')
  echo "  request $i -> $status"
  if [ "$status" = "429" ]; then hit429=1; break; fi
done

if [ "$hit429" = "1" ]; then
  echo "✓ saw a 429 within $TRIES requests — rate limit is enforcing"
else
  echo "⊘ no 429 within $TRIES requests — inconclusive at a 100k-token budget (not a failure)."
  echo "  To force it, temporarily lower tokens/burst in 50-okta-jwt-authz.sh, re-apply, rerun."
fi
