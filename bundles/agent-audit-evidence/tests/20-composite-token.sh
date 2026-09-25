#!/usr/bin/env bash
# Q2 "whose authority", proved on the token itself.
#
# Reads the token each probe route minted through both Cross App Access legs and asserts the
# composite: the SAME reviewer (sub, email) for both agents, a DIFFERENT named actor (act.sub = the
# alias on each agent's Okta connection), Okta's own agent id kept alongside it, and the reviewer's
# resource-side entitlement.
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
ev_require_login
fail=0
GROUP="${EVIDENCE_REVIEWER_GROUP:-priorauth-reviewer}"

for role in priorauth intake; do
  TOK=$(bash "$HELPERS/xaa-final-token.sh" "$role") || { fail=1; continue; }
  C=$(printf '%s' "$TOK" | ev_jwt_claims)
  printf '%s' "$C" > "/tmp/ev-claims-$role.$$"
  echo "── ${role}: the token /probe/${role} minted"
  printf '%s' "$C" | jq -c '{sub, email, act, act_source, scp, groups, iss, aud}' | sed 's/^/  /'
done
[ "$fail" = 0 ] || exit 1

P=/tmp/ev-claims-priorauth.$$; I=/tmp/ev-claims-intake.$$
trap 'rm -f "$P" "$I"' EXIT
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; fail=1; fi; }

check "same reviewer on both tokens (sub)"      '[ "$(jq -r .sub $P)" = "$(jq -r .sub $I)" ]'
check "reviewer email present"                   '[ -n "$(jq -r ".email // empty" $P)" ]'
check "priorauth act.sub = ${PRIORAUTH_ACTOR}"   '[ "$(jq -r .act.sub $P)" = "$PRIORAUTH_ACTOR" ]'
check "intake act.sub = ${INTAKE_ACTOR}"         '[ "$(jq -r .act.sub $I)" = "$INTAKE_ACTOR" ]'
check "Okta agent id kept (priorauth = XAA_AGENT_A_CLIENT_ID)" '[ "$(jq -r .act.okta_agent_id $P)" = "${XAA_AGENT_A_CLIENT_ID:-}" ]'
check "Okta agent id kept (intake = XAA_AGENT_B_CLIENT_ID)"    '[ "$(jq -r .act.okta_agent_id $I)" = "${XAA_AGENT_B_CLIENT_ID:-}" ]'
check "act chain names the login app (act.act.sub)" '[ "$(jq -r .act.act.sub $P)" = "${XAA_LOGIN_CLIENT_ID:-}" ]'
check "act_source = id-jag-named"                '[ "$(jq -r .act_source $P)" = id-jag-named ]'
check "reviewer holds ${GROUP}"                  'jq -e --arg g "$GROUP" ".groups | index(\$g)" $P >/dev/null'

if [ "$fail" != 0 ]; then
  echo "  If act.sub shows an old alias, the Okta connection's \"Client ID at the Resource Authorization"
  echo "  Server\" and EVIDENCE_*_ACTOR disagree (docs/OKTA-SETUP.md). If groups lack ${GROUP},"
  echo "  EVIDENCE_REVIEWERS does not contain the reviewer's email."
  exit 1
fi
echo "✓ one reviewer, two named agents, each in an Okta-signed delegation chain"
