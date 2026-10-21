#!/usr/bin/env bash
# The real assertion: a WebSocket opened THROUGH the gateway reaches the backend and carries a
# full Realtime exchange both ways.
#
# Canaries that only a proxied session can produce:
#   - session.created.mock.path == /v1/realtime    the request reached the backend on that path
#   - delta contains MOCK-REALTIME-CANARY + our text   client->server and server->client frames flowed
#
# How to read a failure:
#   handshake error / HTTP 4xx-5xx   the route did not match, or `routes: /v1/realtime: realtime`
#                                    is missing and the gateway did not do a WebSocket upgrade
#   CERTIFICATE_VERIFY_FAILED        mkcert CA not in the OS trust store (truststore is injected)
#   timeout waiting for response.done  frames stalled in one direction
set -uo pipefail
: "${HOST:?HOST not set}"

HOST="$HOST" uv run --with websockets --with truststore --python 3.12 - <<'PY'
import asyncio, json, os, sys
import truststore; truststore.inject_into_ssl()
import websockets

URL = "wss://%s/v1/realtime?model=mock-realtime" % os.environ["HOST"]

async def recv_until(ws, want, timeout=10):
    seen = []
    while True:
        ev = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        seen.append(ev)
        if ev["type"] == want:
            return seen

async def main():
    async with websockets.connect(URL, additional_headers={"Authorization": "Bearer mock-client-key"}) as ws:
        created = (await recv_until(ws, "session.created"))[-1]
        path = created["session"]["mock"]["path"]
        print("session.created via gateway, backend saw path:", path)
        assert path.split("?")[0] == "/v1/realtime", "backend saw unexpected path %r" % path

        await ws.send(json.dumps({"type": "session.update", "session": {"modalities": ["text"]}}))
        await recv_until(ws, "session.updated")

        await ws.send(json.dumps({"type": "conversation.item.create", "item": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "hello realtime"}]}}))
        await recv_until(ws, "conversation.item.created")

        await ws.send(json.dumps({"type": "response.create"}))
        events = await recv_until(ws, "response.done")
        delta = "".join(e.get("delta", "") for e in events if e["type"] == "response.output_text.delta")
        print("streamed text:", delta)
        assert "MOCK-REALTIME-CANARY" in delta and "hello realtime" in delta, "unexpected delta %r" % delta

try:
    asyncio.run(main())
except Exception as e:
    print("✗ FAIL:", type(e).__name__, e)
    sys.exit(1)
print("✓ full realtime round trip through the gateway")
PY
