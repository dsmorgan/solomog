#!/usr/bin/env bash
# Does THIS gateway version still need `http.version: HTTP1` for a real OpenAI WebSocket?
# A characterization test: it passes when the outcome is one of the two known ones, and prints
# which. It fails only on something unexpected (so a new failure mode is not hidden).
#
#   upgrade accepted           -> the pin is NOT needed on this version
#   HTTP 405 "Invalid method"  -> the pin IS still needed (upgrade lost, almost certainly h2)
#   anything else              -> FAIL, with the status
#
# Self-skips without OPENAI_API_KEY. Opens one WebSocket and sends nothing, so it costs no tokens.
set -uo pipefail
: "${HOST:?HOST not set}"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "SKIP: OPENAI_API_KEY not set in .env"; exit 0
fi

HOST="$HOST" MODEL="${OPENAI_REALTIME_MODEL:-gpt-realtime}" \
  uv run --with websockets --with truststore --python 3.12 - <<'PY'
import asyncio, json, os, sys
import truststore; truststore.inject_into_ssl()
import websockets
from websockets.exceptions import InvalidStatus

URL = "wss://%s/nopin-realtime/v1/realtime?model=%s" % (os.environ["HOST"], os.environ["MODEL"])

async def main():
    try:
        async with websockets.connect(URL) as ws:
            ev = json.loads(await asyncio.wait_for(ws.recv(), 15))
            print("handshake accepted, first event:", ev.get("type"))
            return "NOT_NEEDED" if ev.get("type") == "session.created" else "UNEXPECTED"
    except InvalidStatus as e:
        print("handshake rejected: HTTP", e.response.status_code, (e.response.body or b"")[:200])
        return "NEEDED" if e.response.status_code == 405 else "UNEXPECTED"

r = asyncio.run(main())
if r == "NOT_NEEDED":
    print("✓ RESULT: the HTTP1 pin is NOT needed on this gateway version")
elif r == "NEEDED":
    print("✓ RESULT: the HTTP1 pin IS STILL NEEDED on this gateway version (405 without it)")
else:
    print("✗ FAIL: unexpected outcome, see above"); sys.exit(1)
PY
