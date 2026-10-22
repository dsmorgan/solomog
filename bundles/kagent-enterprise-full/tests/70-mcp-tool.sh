#!/usr/bin/env bash
# A turn that calls an MCP tool: the mock model asks for `add`, the runtime calls the kmcp-deployed
# server, and the tool's answer comes back through the model.
. "$(dirname "$0")/../helpers/checks.sh"

before="$(mock_log "$KAGENT_NS" mock-mcp | grep -c '"tools/call"' || true)"
if turn toolcall "CALL:add please" && grep -q "TOOL-add-OK" <<<"$TURN_OUT"; then
  ok "turn returned the tool's answer (TOOL-add-OK)"
else
  no "turn didn't return TOOL-add-OK:"; printf '%s\n' "$TURN_OUT" | tail -8 | sed 's/^/      /'
  say "if the tool call never arrived, check the actor's egress: kubectl --context ${CTX} -n ${SUBSTRATE_NS} logs deploy/atenet-egress --tail=20"
fi
after="$(mock_log "$KAGENT_NS" mock-mcp | grep -c '"tools/call"' || true)"
[ "$after" -gt "$before" ] && ok "mock-mcp logged the tools/call (${before} → ${after})" || no "mock-mcp logged no new tools/call"
exit "$fail"
