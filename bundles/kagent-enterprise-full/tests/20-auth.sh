#!/usr/bin/env bash
# The bundled IdP issues an admin token, and the controller accepts it on its API.
. "$(dirname "$0")/../helpers/checks.sh"

api_open || exit 1
p="$(cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+')"
while [ $(( ${#p} % 4 )) -ne 0 ]; do p="${p}="; done   # JWTs drop base64 padding
claims="$(base64 -d <<<"$p" 2>/dev/null)"
ok "admin token from :8085/autoauth/token (iss $(jq -r '.iss // "?"' <<<"$claims" 2>/dev/null), sub $(jq -r '.sub // "?"' <<<"$claims" 2>/dev/null))"
code="$(TOKEN="$TOKEN" "$(a2a_turn_bin)" -probe -addr "$API" -timeout 15s 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "ListSessions with the admin token: allowed" || no "ListSessions with the admin token: ${code:-exit ${rc}}"
code="$(TOKEN=not-a-token "$(a2a_turn_bin)" -probe -addr "$API" -timeout 15s 2>/dev/null)"; rc=$?
[ "$rc" != 0 ] && ok "ListSessions with a bad token: refused (${code:-exit ${rc}})" || no "ListSessions with a bad token was allowed"
pf_stop
exit "$fail"
