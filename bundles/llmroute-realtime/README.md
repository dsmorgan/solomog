# llmroute-realtime — proxy OpenAI's Realtime API (WebSocket) through agentgateway

OpenAI's `/v1/realtime` endpoint is a long-lived WebSocket, not request/response HTTP. This
bundle maps it as a `Realtime` route on an agentgateway AI backend so the gateway upgrades the
connection and proxies events in both directions. Two routes run side by side: one to an
in-cluster mock (no key), and one to the real OpenAI API (needs `OPENAI_API_KEY` in `.env`).

```bash
solomog agentgateway expose apply BUNDLE=llmroute-realtime CLUSTER=<c>
solomog test BUNDLE=llmroute-realtime CLUSTER=<c>
```

Status, file and test reference, and gotchas: [docs/details.md](docs/details.md).
