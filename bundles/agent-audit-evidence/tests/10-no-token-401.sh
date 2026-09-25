#!/usr/bin/env bash
# Control: no credential, no entry, and the refusal is itself a record.
#
# Both checkpoints are Strict. A request with no token gets 401 before anything else runs, and the
# access log names the control that refused it (reason=JwtAuth) and why (error). This needs no Okta
# login, so it runs before the tests that do.
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
N=$(ev_nonce)
fail=0

for path in /agents/intake /claims-tools; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://${HOST}${path}" -H "X-Agent-Version: ${N}")
  if [ "$code" = 401 ]; then echo "✓ ${path} without a token → 401"; else echo "✗ ${path} without a token → ${code} (expected 401)"; fail=1; fi
done

LINE=$(ev_log_select "$N" '.["http.path"] == "/agents/intake"') || LINE=""
if [ -z "$LINE" ]; then
  echo "✗ no access record for the refused request (marker ${N}) — is 02-parameters.sh (json logs) applied?"
  exit 1
fi
echo "  the record of the refusal:"
ev_report_field "$LINE" http.status
ev_report_field "$LINE" reason || fail=1
ev_report_field "$LINE" error
ev_report_field "$LINE" trace.id
R=$(printf '%s' "$LINE" | jq -r '.reason // empty')
[ "$R" = JwtAuth ] || { echo "✗ reason=${R:-<absent>}, expected JwtAuth"; fail=1; }
[ "$fail" = 0 ] && echo "✓ a refusal is recorded with the control that made it" || exit 1
