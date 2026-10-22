#!/usr/bin/env bash
# The UI works the way a browser uses it, through one port-forward to its nginx:
#   - it serves the app, and env-config.js turns auto-auth on for this cluster
#   - /autoauth/token hands out an admin token (the bundled IdP, behind nginx)
#   - an API call on the UI's own route (gRPC-Web under /api/proxy/cluster/<cluster>/api/) lists
#     the Agents with that token, and is refused without it
. "$(dirname "$0")/../helpers/checks.sh"

pf "$KAGENT_NS" svc/kagent-ui 8080 || { no "no port-forward to svc/kagent-ui"; exit 1; }
UI="http://127.0.0.1:${PF_BASE}"
trap pf_stop EXIT

code="$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$UI/")"
case "$code" in 200\ text/html*) ok "GET / serves the app (${code})" ;; *) no "GET / returned ${code}" ;; esac

env="$(curl -s "$UI/env-config.js")"
v() { sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" <<<"$env"; }
[ "$(v KAGENT_UI_EXTENSION_AUTO_AUTH_ENABLED)" = true ] && ok "env-config.js: auto-auth on" || no "env-config.js: auto-auth is '$(v KAGENT_UI_EXTENSION_AUTO_AUTH_ENABLED)'"
[ "$(v KAGENT_UI_EXTENSION_LOCAL_CLUSTER_NAME)" = "$CLUSTER" ] && ok "env-config.js: cluster ${CLUSTER}" || no "env-config.js: cluster is '$(v KAGENT_UI_EXTENSION_LOCAL_CLUSTER_NAME)', want ${CLUSTER}"
[ "$(v KAGENT_UI_EXTENSION_TELEMETRY_BACKEND)" = clickhouse ] && ok "env-config.js: tracing reads ClickHouse" || no "env-config.js: telemetry backend '$(v KAGENT_UI_EXTENSION_TELEMETRY_BACKEND)'"

tok="$(admin_token "$PF_BASE")"
[ -n "$tok" ] && ok "admin token from the UI's /autoauth/token" || no "no token from the UI's /autoauth/token"

# One empty gRPC-Web frame: flag 0, length 0. ListAgents takes an empty request.
list_agents() {
  printf '\x00\x00\x00\x00\x00' | curl -s -D "$1.h" -o "$1.b" -X POST -H 'Content-Type: application/grpc-web+proto' \
    -H 'X-Grpc-Web: 1' ${2:+-H "Authorization: Bearer $2"} --data-binary @- \
    "$UI/api/proxy/cluster/${CLUSTER}/api/kagent.api.v1.AgentService/ListAgents"
}
tmp="$(mktemp -d)"
list_agents "$tmp/with" "$tok"
if grep -qi '^grpc-status: *0\|^HTTP/1.1 200' "$tmp/with.h" && grep -aq assistant "$tmp/with.b" && grep -aq toolcall "$tmp/with.b"; then
  ok "ListAgents through the UI's nginx returns assistant and toolcall"
else
  no "ListAgents through the UI: $(grep -i '^HTTP\|grpc-message' "$tmp/with.h" | tr -d '\r' | tr '\n' ' ')"
fi
list_agents "$tmp/without" ""
grep -q '^HTTP/1.1 401' "$tmp/without.h" && ok "the same call without a token: 401" || no "the same call without a token: $(head -1 "$tmp/without.h")"
rm -rf "$tmp"
exit "$fail"
