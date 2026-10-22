"""Streamable HTTP MCP server whose tool list you change while it runs.

Standard library only. POST /mcp speaks JSON-RPC and answers application/json.

  POST /admin/tools {"tools": ["add", "multiply"]}   replace the tool list
  GET  /requests                                      the log, as JSON lines

Every tool returns "TOOL-<name>-OK". Each log line has the JSON-RPC method, the tool name for
tools/call, and the Authorization and X-User-Id headers, so a test can see what the caller's
identity looked like on arrival.
"""
import json, sys, time, uuid, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS, LOG, LOCK = ["add"], [], threading.Lock()

def schema(name):
    return {"name": name, "description": f"Mock tool {name}: combines two numbers.",
            "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body=None, headers=None, ctype="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(code)
        if body is not None:
            self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/requests"):
            with LOCK:
                return self.send(200, ("\n".join(json.dumps(r) for r in LOG) + "\n").encode(), ctype="text/plain")
        if self.path.startswith("/admin/tools"):
            with LOCK:
                return self.send(200, {"tools": TOOLS})
        self.send(405, {"error": "use POST"})

    def do_DELETE(self):
        self.send(200, {})

    def do_POST(self):
        global TOOLS
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) or b"{}"
        if self.path.startswith("/admin/tools"):
            with LOCK:
                TOOLS = list(json.loads(raw).get("tools") or [])
            print(json.dumps({"admin": "tools", "tools": TOOLS}), flush=True)
            return self.send(200, {"tools": TOOLS})
        try:
            msg = json.loads(raw)
        except ValueError:
            return self.send(400, {"error": "bad json"})
        batch = isinstance(msg, list)
        out = [r for r in (self.handle_one(m) for m in (msg if batch else [msg])) if r is not None]
        hdr = {"Mcp-Session-Id": self.headers.get("Mcp-Session-Id") or str(uuid.uuid4())}
        if not out:
            return self.send(202, None, hdr)
        self.send(200, out if batch else out[0], hdr)

    def handle_one(self, m):
        method, mid, params = m.get("method"), m.get("id"), m.get("params") or {}
        rec = {"ts": time.time(), "method": method, "tool": params.get("name") if method == "tools/call" else None,
               "auth": self.headers.get("Authorization", ""), "user": self.headers.get("X-User-Id", "")}
        with LOCK:
            LOG.append(rec)
            tools = list(TOOLS)
        print(json.dumps(rec), flush=True)
        if mid is None:
            return None
        if method == "initialize":
            res = {"protocolVersion": params.get("protocolVersion") or "2025-06-18",
                   "capabilities": {"tools": {"listChanged": True}},
                   "serverInfo": {"name": "mock-mcp", "version": "1.0.0"}}
        elif method == "ping":
            res = {}
        elif method == "tools/list":
            res = {"tools": [schema(t) for t in tools]}
        elif method == "tools/call":
            name = params.get("name")
            if name not in tools:
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"Unknown tool: {name}"}}
            res = {"content": [{"type": "text", "text": f"TOOL-{name}-OK"}], "isError": False}
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"no method {method}"}}
        return {"jsonrpc": "2.0", "id": mid, "result": res}

ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8080), H).serve_forever()
