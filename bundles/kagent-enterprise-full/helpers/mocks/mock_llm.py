"""OpenAI-compatible chat completions endpoint that records every request.

Standard library only, so it runs on a stock python image with no install step.

The model name picks the behavior:
  nostream   HTTP 400 when stream=true, like a model runtime that can't stream
  fail       HTTP 500 on every call, for error-status tracing
  slow       answer after SLOW seconds (env MOCK_SLOW_SECONDS, default 45), to hold a worker
  anything   answer, streamed when asked

Content rules, for deterministic turns:
  last message is a tool result   -> "RESULT <tool text>"
  user text has CALL:<tool>       -> a tool call to the offered tool named, or ending in, <tool>,
                                     with ARGS:<json object> as its arguments when given, else {"a":2,"b":3}
  user text has JSON:<text>       -> exactly <text>, verbatim, for structured-output turns
  user text has WAIT:<seconds>    -> sleep that long first, but only before answering the user,
                                     not after a tool result, so a test can delay a tool call
  otherwise                       -> "ECHO <user text>"

Only /chat/completions is answered. Any other POST, such as /v1/responses, is recorded and
then refused with 404, so a test can still read the request a runtime built.

GET /requests returns the log as JSON lines. Each line has the path, the Authorization
header, the stream flag, the model, the offered tool names, and the last user text. It also
has `body`, the whole request with every string longer than 200 characters cut to its first 80
(a `data:` URL keeps its media type and the start of its base64), and `raw_len`, the request's
size in bytes: enough to see which content parts a runtime sent without logging megabytes.
"""
import json, os, re, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG, LOCK = [], threading.Lock()

def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""

def trim(v):
    if isinstance(v, str):
        return v if len(v) <= 200 else v[:80] + "...[%d chars]" % len(v)
    if isinstance(v, list):
        return [trim(x) for x in v]
    if isinstance(v, dict):
        return {k: trim(x) for k, x in v.items()}
    return v

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/requests"):
            with LOCK:
                self.send(200, ("\n".join(json.dumps(r) for r in LOG) + "\n").encode(), "text/plain")
        else:
            self.send(200, {"ok": True})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            raw = self.rfile.read(n)
            req = json.loads(raw or b"{}")
        except ValueError:
            return self.send(400, {"error": {"message": "bad json"}})
        msgs = req.get("messages") or []
        tools = [t.get("function", {}).get("name") for t in (req.get("tools") or [])]
        users = [m for m in msgs if m.get("role") == "user"]
        user = text_of(users[-1].get("content")) if users else ""
        last = msgs[-1] if msgs else {}
        rec = {"ts": time.time(), "path": self.path, "auth": self.headers.get("Authorization", ""),
               "baggage": self.headers.get("baggage", ""), "traceparent": self.headers.get("traceparent", ""),
               "stream": bool(req.get("stream")), "model": req.get("model"), "tools": tools,
               "last_role": last.get("role"), "user": user[:300],
               "raw_len": len(raw), "body": trim(req)}
        with LOCK:
            LOG.append(rec)
        print(json.dumps(rec), flush=True)
        if not self.path.endswith("/chat/completions"):
            return self.send(404, {"error": {"message": "only chat/completions"}})
        model = req.get("model") or "mock"
        if model == "fail":
            return self.send(500, {"error": {"message": "mock model failure", "type": "server_error"}})
        if model == "slow":
            time.sleep(float(os.environ.get("MOCK_SLOW_SECONDS", "45")))
        if model == "nostream" and req.get("stream"):
            return self.send(400, {"error": {"message": "stream=true is not supported by this model", "type": "invalid_request_error"}})

        wait = re.search(r"WAIT:(\d+)", user)
        if wait and last.get("role") != "tool":
            time.sleep(int(wait.group(1)))

        call, content = None, None
        if last.get("role") == "tool":
            content = "RESULT " + text_of(last.get("content"))
        else:
            # The runtime may prefix MCP tool names, so CALL:add matches "add" or "<prefix>_add".
            want = re.search(r"CALL:([A-Za-z0-9_-]+)", user)
            for name in tools:
                if want and name and (name == want.group(1) or name.endswith(want.group(1))):
                    call = name
                    break
            raw_json = re.search(r"JSON:(.*)", user, re.S)
            if call is None and raw_json:
                content = raw_json.group(1).strip()
            elif call is None:
                content = "ECHO " + user
        created = int(time.time())
        usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        args = re.search(r"ARGS:(\{[^\n]*\})", user)
        tc = [{"index": 0, "id": "call_1", "type": "function",
               "function": {"name": call, "arguments": args.group(1) if args else json.dumps({"a": 2, "b": 3})}}] if call else None

        if not req.get("stream"):
            msg = {"role": "assistant", "content": content}
            if tc:
                msg = {"role": "assistant", "content": None,
                       "tool_calls": [{k: v for k, v in tc[0].items() if k != "index"}]}
            return self.send(200, {"id": "cmpl-1", "object": "chat.completion", "created": created,
                                   "model": model, "usage": usage,
                                   "choices": [{"index": 0, "message": msg,
                                                "finish_reason": "tool_calls" if tc else "stop"}]})

        def chunk(delta, finish=None, extra=None):
            c = {"id": "cmpl-1", "object": "chat.completion.chunk", "created": created, "model": model,
                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if extra:
                c.update(extra)
            return "data: " + json.dumps(c) + "\n\n"

        parts = [chunk({"role": "assistant", "content": ""})]
        if tc:
            parts.append(chunk({"tool_calls": tc}))
            parts.append(chunk({}, "tool_calls"))
        else:
            parts.append(chunk({"content": content}))
            parts.append(chunk({}, "stop"))
        parts.append("data: " + json.dumps({"id": "cmpl-1", "object": "chat.completion.chunk", "created": created,
                                            "model": model, "choices": [], "usage": usage}) + "\n\n")
        parts.append("data: [DONE]\n\n")
        body = "".join(parts).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8080), H).serve_forever()
