#!/usr/bin/env bash
# The HTTP route actually forwards an EXCHANGED token upstream. go-httpbin echoes what it
# received, so this asserts the credential that arrived, not merely that the request succeeded.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOKEN="$(bash "$HERE/../helpers/get-token.sh")"

body="$(curl -sk --fail-with-body --max-time 20 "https://${HOST}/exchange-http" \
  -H "Authorization: Bearer ${TOKEN}")" || { echo "✗ /exchange-http failed: $body" >&2; exit 1; }

recv="$(printf '%s' "$body" | jq -r '.headers.Authorization | if type=="array" then .[0] else . end // empty')"
recv="${recv#Bearer }"
[ -n "$recv" ] || { echo "✗ no Authorization reached the upstream — the exchange forwarded nothing" >&2; exit 1; }

claims="$(printf '%s' "$recv" | cut -d. -f2 | { p=$(cat); printf '%s' "$p$(printf '%*s' $(( (4-${#p}%4)%4 )) '' | tr ' ' '=')"; } | tr '_-' '/+' | base64 --decode 2>/dev/null)"
azp="$(printf '%s' "$claims" | jq -r '.azp // "-"')"
[ "$azp" = "exchange-client" ] || {
  echo "✗ upstream received azp=$azp, expected exchange-client." >&2
  echo "  azp=login-client means the inbound token was forwarded unexchanged." >&2; exit 1; }
echo "✓ HTTP route forwards the exchanged token upstream (azp=$azp, sub=$(printf '%s' "$claims" | jq -r .sub))"
