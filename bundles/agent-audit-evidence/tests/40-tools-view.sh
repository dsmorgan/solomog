#!/usr/bin/env bash
# The tool policy, asserted directly: what each agent's token can SEE and CALL at /claims-tools.
#
# Uses the tokens the gateway minted on the probe routes and speaks MCP itself, so a failure here
# localises to the policy (tests/50 runs the same thing through the agents).
#   priorauth-agent + reviewer → approve_prior_auth listed, and a call is allowed
#   intake-agent    + reviewer → approve_prior_auth NOT listed, and a forced call is refused
#                                (HTTP 400, JSON-RPC -32602 "Unknown tool")
set -uo pipefail
. "$(dirname "$0")/_lib.bash"
ev_require_login

PTOK=$(bash "$HELPERS/xaa-final-token.sh" priorauth) || exit 1
ITOK=$(bash "$HELPERS/xaa-final-token.sh" intake) || exit 1

URL="https://${HOST}/claims-tools" PTOK="$PTOK" ITOK="$ITOK" TOOL="$SENSITIVE_TOOL" \
uv run --quiet --with 'mcp<2' --with truststore --with httpx --python 3.12 - <<'PY'
import asyncio, json, os, sys
import truststore; truststore.inject_into_ssl()
import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

URL, TOOL = os.environ["URL"], os.environ["TOOL"]

async def view(token, name):
    h = {"Authorization": f"Bearer {token}", "X-Agent-Name": f"test-{name}"}
    async with streamablehttp_client(URL, headers=h) as (r, w, sid):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = sorted(t.name for t in (await s.list_tools()).tools)
            session = sid()
    body = {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": {"name": TOOL, "arguments": {"claim_id": "CLM-1001"}}}
    hh = {**h, "Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session: hh["Mcp-Session-Id"] = session
    async with httpx.AsyncClient(timeout=30, verify=True) as c:
        resp = await c.post(URL, headers=hh, json=body)
    payload = {}
    for line in resp.text.splitlines():
        if line.startswith("data: "):
            payload = json.loads(line[6:]); break
    else:
        try: payload = resp.json()
        except Exception: payload = {}
    return tools, resp.status_code, payload

async def main():
    fail = 0
    for name, tok, allowed in (("priorauth", os.environ["PTOK"], True), ("intake", os.environ["ITOK"], False)):
        tools, code, payload = await view(tok, name)
        listed = TOOL in tools
        err = payload.get("error")
        print(f"── {name}-agent token")
        print(f"  tools/list: {', '.join(tools)}")
        print(f"  forced {TOOL}: HTTP {code} " + (json.dumps(err) if err else json.dumps(payload.get('result', {}).get('structuredContent') or 'ok')))
        if allowed:
            if not listed: print(f"  ✗ {TOOL} should be listed"); fail = 1
            if code != 200 or err: print(f"  ✗ {TOOL} should be allowed"); fail = 1
        else:
            if listed: print(f"  ✗ {TOOL} should NOT be listed"); fail = 1
            if code != 400 or not err or err.get("code") != -32602:
                print(f"  ✗ expected HTTP 400 + -32602, got {code} {err}"); fail = 1
    if fail:
        print("  Check claims-tools-rbac targets claims-mcp-relay, and that act.sub / groups in tests/20 look right.")
        sys.exit(1)
    print(f"✓ {TOOL}: visible and callable only for the named agent acting for an entitled reviewer")

asyncio.run(main())
PY
