#!/usr/bin/env bash
# Real OpenAI Realtime through the gateway. CALLS THE REAL API (costs a few tokens).
#
# Self-skips (exit 0) without OPENAI_API_KEY in .env. Needs an account with Realtime access.
# Override the model with OPENAI_REALTIME_MODEL (default gpt-realtime, the GA model).
#
# The client sends NO credentials: the gateway injects the key from the openai-realtime-secret.
# Passing therefore proves the upgrade, the upstream auth, and the bidirectional flow.
#
# How to read a failure:
#   handshake HTTP 401/403    the secret is stale or empty: re-run `solomog apply`, check .env
#   error event invalid_model the account lacks that model: set OPENAI_REALTIME_MODEL
#   beta_api_shape_disabled   a client sent OpenAI-Beta: realtime=v1; the beta API is retired
#   handshake HTTP 404        route not matched or no upgrade: kubectl get httproute openai-realtime-real
#   timeout waiting for response.done   model produced nothing; see the printed event types
set -uo pipefail
: "${HOST:?HOST not set}"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "SKIP: OPENAI_API_KEY not set in .env (the mock tests 00-10 still cover the proxying)"
  exit 0
fi
kubectl --context "$CONTEXT" get secret openai-realtime-secret -n agentgateway-system >/dev/null 2>&1 || {
  echo "✗ openai-realtime-secret missing: run solomog apply with OPENAI_API_KEY set"; exit 1; }
st=$(kubectl --context "$CONTEXT" get httproute openai-realtime-real -n agentgateway-system \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$st" = "True" ] || { echo "✗ httproute openai-realtime-real Accepted=${st:-<missing>}"; exit 1; }

HOST="$HOST" MODEL="${OPENAI_REALTIME_MODEL:-gpt-realtime}" \
  uv run --with websockets --with truststore --python 3.12 - <<'PY'
import asyncio, json, os, sys
import truststore; truststore.inject_into_ssl()
import websockets

URL = "wss://%s/openai-realtime/v1/realtime?model=%s" % (os.environ["HOST"], os.environ["MODEL"])
TEXT_DELTAS = ("response.output_text.delta", "response.text.delta")   # GA name first; beta kept for safety

async def recv_until(ws, want, timeout=30):
    seen = []
    while True:
        ev = json.loads(await asyncio.wait_for(ws.recv(), timeout))
        seen.append(ev)
        if ev["type"] == "error":
            raise RuntimeError("OpenAI error event: %s" % json.dumps(ev.get("error", ev)))
        if ev["type"] == want:
            return seen

async def main():
    # GA API: no OpenAI-Beta header. Sending `realtime=v1` selects the retired beta shape and
    # OpenAI answers `beta_api_shape_disabled`.
    async with websockets.connect(URL) as ws:
        created = (await recv_until(ws, "session.created"))[-1]
        print("session.created, model:", created.get("session", {}).get("model"))

        await ws.send(json.dumps({"type": "session.update", "session": {
            "type": "realtime", "output_modalities": ["text"]}}))
        await ws.send(json.dumps({"type": "conversation.item.create", "item": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "Reply with the single word: ok"}]}}))
        await ws.send(json.dumps({"type": "response.create"}))

        events = await recv_until(ws, "response.done")
        print("event types:", sorted({e["type"] for e in events}))
        text = "".join(e.get("delta", "") for e in events if e["type"] in TEXT_DELTAS)
        print("model said:", repr(text))
        done = events[-1]["response"]
        assert done.get("status") == "completed", "response.status=%r" % done.get("status")
        assert text.strip(), "no text deltas before response.done"

try:
    asyncio.run(main())
except Exception as e:
    print("✗ FAIL:", type(e).__name__, e)
    sys.exit(1)
print("✓ real OpenAI realtime round trip through the gateway")
PY
