# llmroute-realtime — details

The README covers what the bundle is and how to run it. This page holds the rest.

## Status

| | |
|---|---|
| **covers** | `/v1/realtime` route type, WebSocket upgrade, bidirectional event flow |
| **needs** | an agentgateway cluster with a Gateway; `uv` locally; `OPENAI_API_KEY` in `.env` for the real leg only |
| **versions** | enterprise agentgateway; floor not determined (works on 2026.7.1-patch.4 and 2026.10.0) |
| **clash-safe** | yes: own namespace `realtime-mock`, own routes `/v1/realtime`, `/openai-realtime`, `/nopin-realtime` |
| **verified** | 4/4 on `rt1`, agw 2026.10.0, 2026-10-21 (mock + real `gpt-realtime`); 3/3 earlier on 2026.7.1-patch.4 |

## What it deploys

| File | Purpose |
|---|---|
| `10-mock-realtime-server.yaml` | In-cluster mock of the Realtime API (stdlib Python, no egress, no key) |
| `20-realtime-backend.yaml` | Backend and policy for the mock route (`/v1/realtime`) |
| `25-openai-secret.sh` | Hook: creates `openai-realtime-secret` from `OPENAI_API_KEY`; skips without it |
| `40-openai-real.yaml.tmpl` | Real OpenAI route (`/openai-realtime/v1/realtime`), HTTP/1.1 pinned |
| `45-pin-probe.yaml.tmpl` | Diagnostic twin of the real route without the pin (`/nopin-realtime`) |

`routes: {/v1/realtime: Realtime}` lives in the **policy** (`backend.ai.routes`), not on the
backend. It is a path-suffix map, which is why the real route can sit under a prefix.

## Tests

`TESTS=10` re-runs only the mock round trip; `TESTS=20` only the real one.

| Test | Asserts |
|---|---|
| `00-preflight` | mock ready, proxy rolled out (reports controller, template and running-pod versions), route and policy `Accepted` |
| `10-websocket-roundtrip` | mock: session opens through the gateway, backend sees `/v1/realtime`, `session.update` -> `conversation.item.create` -> `response.create` streams text back |
| `20-openai-real` | real OpenAI: same flow with no client credentials (the gateway injects the key); `response.done` is `completed` with non-empty text. Calls the real API (a few tokens); self-skips without the key |
| `30-pin-probe` | diagnostic: the real route WITHOUT the HTTP1 pin; passes on either known outcome and prints whether the pin is still needed. Opens one socket, sends nothing, costs no tokens |

Set the model with `OPENAI_REALTIME_MODEL` (default `gpt-realtime`) if your account lacks it.
The real route pins no model; the client picks it with `?model=`.

## Run against real OpenAI only

Set `OPENAI_API_KEY` in `.env` before `apply`. Without it the secret hook skips, and tests 20 and
30 self-skip (they pass without testing anything, so read the output for `SKIP`).

## Gotchas

- **Pin `backend.http.version: HTTP1` for real OpenAI.** Without it, `api.openai.com` answers
  `405 Invalid method for URL (GET /v1/realtime)`: a WebSocket upgrade does not survive HTTP/2.
  The plaintext mock never shows this. Confirmed on 2026.7.1-patch.4 and 2026.10.0: without the
  pin OpenAI answers 405 (test 30), with it the upgrade is accepted. The CRD doc says an unset
  version infers `HTTP1` for HTTPS; observed behavior disagrees. Likely mechanism, from source
  reading and not a packet capture: backend TLS offers ALPN `h2, http/1.1` unless a version
  override exists, and OpenAI picks h2.
- **Use the GA Realtime API, not beta.** Sending `OpenAI-Beta: realtime=v1` returns
  `beta_api_shape_disabled`. GA needs no beta header, the `gpt-realtime` model, and
  `session.update` with `session.type: realtime` and `output_modalities`.
- **`Accepted=True` on the route says nothing about the route type.** Only a real upgrade does.
- **Read the version from running pods, not one Deployment template.** Straight after an
  upgrade the proxy template can lag the controller; test 00 waits for the rollout.
- Prompt guards can apply to realtime frames only with `promptGuard.streaming: Enabled`.
