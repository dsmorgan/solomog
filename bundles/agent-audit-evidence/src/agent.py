#!/usr/bin/env python3
"""The faux claims agent: in-cluster, deterministic, no LLM.

ONE codebase, deployed twice (priorauth-agent, intake-agent), differing only by AGENT_NAME. If the
two get different tool access from identical code for the same reviewer, the difference provably
comes from the identity the gateway attached, not from anything the agent did.

Per request it:

  1. reports the decoded claims of the credential checkpoint 1 attached (never the raw token; the
     /probe/* routes exist for that);
  2. opens an MCP session back through the gateway to /claims-tools with that credential, lists the
     tools, calls a benign one, then forces the sensitive one (approve_prior_auth) over raw HTTP so a
     refusal is data rather than an SDK exception;
  3. declares its own name and version in headers (logged by the gateway as audit.declared.*), and
     forwards the inbound traceparent so every tool call joins the same trace;
  4. writes its own "app-log" line to stdout: the application's account of what it did.

The hairpin is plaintext http:// to the gateway's cluster-local Service, which is fine for a
throwaway demo cluster and not what you would ship (mesh mTLS, or the HTTPS listener).

Env:
  AGENT_NAME         reported name (priorauth-agent | intake-agent). Declared only; the identity
                     that decides anything is act.sub inside the token.
  AGENT_VERSION      declared version (default 0.0.0)
  AGW_BASE_URL       gateway address (default http://agw.agentgateway-system.svc.cluster.local:8080)
  AGW_MCP_PATH       default /claims-tools
  MCP_BENIGN_TOOL    default get_claim
  MCP_SENSITIVE_TOOL default approve_prior_auth
  CLAIM_ID           default CLM-1001
  PORT               default 8080
"""

import asyncio
import base64
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AGENT_NAME = os.environ.get("AGENT_NAME", "unnamed-agent")
AGW_BASE_URL = os.environ.get(
    "AGW_BASE_URL", "http://agw.agentgateway-system.svc.cluster.local:8080"
).rstrip("/")
AGW_MCP_PATH = os.environ.get("AGW_MCP_PATH", "/claims-tools")
AGENT_VERSION = os.environ.get("AGENT_VERSION", "0.0.0")
BENIGN_TOOL = os.environ.get("MCP_BENIGN_TOOL", "get_claim")
SENSITIVE_TOOL = os.environ.get("MCP_SENSITIVE_TOOL", "approve_prior_auth")
CLAIM_ID = os.environ.get("CLAIM_ID", "CLM-1001")
PORT = int(os.environ.get("PORT", "8080"))

MCP_URL = f"{AGW_BASE_URL}{AGW_MCP_PATH}"


def _claims(token: str) -> dict:
    """Decode a JWT payload WITHOUT verifying it.

    Safe here, and only here: the gateway validated this token at checkpoint 1 (it minted it) and
    validates it again at checkpoint 2 before the relay forwards it. This agent makes no
    authorization decision — it reports. The decision is the gateway's, which is the whole point of
    the PEP-at-the-gateway model.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # noqa: BLE001
        return {}


def _saw(headers) -> dict:
    """The echo half — SECRET-SAFE. Reports header names, presence booleans, and the DECODED claims
    of the credential that arrived. Never the raw token: the /probe/* routes exist for that.
    """
    lower = {k.lower(): v for k, v in headers.items()}
    auth = lower.get("authorization", "") or ""
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else auth.strip()
    c = _claims(token)
    act = c.get("act") or {}
    return {
        "header_names": sorted(headers.keys()),
        "authorization": {"present": bool(token), "looks_like_jwt": token.count(".") == 2},
        # The composite the gateway minted through both XAA legs. `act` is a standardized RFC 8693
        # actor derived from an Okta-signed ID-JAG, not a header the agent wrote itself.
        "token": {
            "sub": c.get("sub"),
            "act": act,
            "act_sub": act.get("sub") if isinstance(act, dict) else c.get("act_sub"),
            "act_source": c.get("act_source"),
            "email": c.get("email"),
            "iss": c.get("iss"),
            "aud": c.get("aud"),
            "scp": c.get("scp"),
            "groups": c.get("groups"),
            "groups_source": c.get("groups_source"),
        } if token else None,
    }


def _explain(exc) -> str:
    """Flatten an exception (unwrapping the anyio/MCP ExceptionGroup) to its leaf causes.

    The MCP streamable-HTTP client raises inside a TaskGroup, so the top-level string is the useless
    'unhandled errors in a TaskGroup'. Walk to the leaves and include any HTTP status/body so a
    failure is diagnosable from the agent's own response.
    """
    leaves = []

    def walk(x):
        subs = getattr(x, "exceptions", None)
        if subs:
            for s in subs:
                walk(s)
            return
        msg = f"{type(x).__name__}: {str(x)[:200]}"
        resp = getattr(x, "response", None)
        if resp is not None:
            try:
                msg += f" [HTTP {resp.status_code}: {resp.text[:200]}]"
            except Exception:  # noqa: BLE001
                pass
        leaves.append(msg)

    walk(exc)
    return "; ".join(leaves) or f"{type(exc).__name__}: {str(exc)[:200]}"


def _declared(traceparent: str) -> dict:
    """Headers this agent DECLARES about itself on every tool call.

    Name and version are self-reported, and the gateway logs them under audit.declared.* so a reader
    never mistakes them for the IdP-asserted identity in `act`. traceparent is forwarded from the
    inbound request so the tool calls join the same trace as the call that started the task.
    """
    h = {"X-Agent-Name": AGENT_NAME, "X-Agent-Version": AGENT_VERSION,
         "User-Agent": f"{AGENT_NAME}/{AGENT_VERSION}"}
    if traceparent:
        h["traceparent"] = traceparent
    return h


def _app_log(traceparent: str, **fields) -> None:
    """The agent's own account of what it did: the application log an app team keeps today."""
    parts = (traceparent or "").split("-")
    line = {"source": AGENT_NAME, "trace_id": parts[1] if len(parts) == 4 else "", **fields}
    print("app-log " + json.dumps(line), file=sys.stdout, flush=True)


async def _call_raw(token: str, session_id, name: str, args: dict, extra: dict) -> tuple:
    """tools/call over raw HTTP, so a gateway DENY is a status code rather than an exception.

    THIS IS NOT A STYLISTIC CHOICE. Measured on 2026.7.1, the relay denies a tool by pretending it
    does not exist: filtered out of `tools/list`, and a call anyway answers

        HTTP 400  {"jsonrpc":"2.0","error":{"code":-32602,"message":"Unknown tool: transfer_funds"}}

    Good security property — the agent is never told a tool exists but is out of reach. Awkward
    client mechanic: the SDK's transport raises HTTPStatusError on any non-2xx from inside its anyio
    task group, tearing down the whole session rather than returning an error to the `call_tool`
    caller. That escapes a `try` around the call entirely. Issuing this one call over raw httpx, on
    the SDK's own session id, turns the denial into data we can report.

    Returns (http_status, jsonrpc_error_or_None). The relay frames success as SSE and rejection as
    plain JSON, so both are unwrapped.
    """
    import httpx

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        **extra,
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    body = {"jsonrpc": "2.0", "id": 99, "method": "tools/call",
            "params": {"name": name, "arguments": args}}
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(MCP_URL, headers=headers, json=body)

    payload = {}
    for line in r.text.splitlines():
        if line.startswith("data: "):
            payload = json.loads(line[6:])
            break
    else:
        try:
            payload = r.json()
        except Exception:  # noqa: BLE001
            payload = {}
    return r.status_code, payload.get("error")


async def _mcp_probe(token: str, traceparent: str) -> dict:
    """One MCP session through checkpoint 2: who arrived, what is visible, what is callable.

    Reports FACTS, never a verdict. Agent A is expected to be permitted and agent B denied, so a
    single "rbac_enforced" boolean would be wrong for one of them by construction — the assertion
    belongs in the test, which knows which agent it is talking to.
    """
    try:
        from mcp import ClientSession
        import mcp.client.streamable_http as _sh
        # The transport factory was renamed across SDK versions; accept either name.
        streamablehttp_client = (getattr(_sh, "streamablehttp_client", None)
                                 or _sh.streamable_http_client)

        extra = _declared(traceparent)
        auth = {"Authorization": f"Bearer {token}", **extra}
        async with streamablehttp_client(MCP_URL, headers=auth) as (r, w, get_sid):
            async with ClientSession(r, w) as s:
                await s.initialize()
                tools = sorted(t.name for t in (await s.list_tools()).tools)

                # What did the MCP SERVER see? Proves the composite survived the relay's passthrough.
                whoami = None
                if "whoami" in tools:
                    try:
                        res = await s.call_tool("whoami", {})
                        texts = [c.text for c in res.content if hasattr(c, "text")]
                        whoami = json.loads(texts[0]) if texts else None
                    except Exception as e:  # noqa: BLE001
                        whoami = {"error": f"{type(e).__name__}: {str(e)[:120]}"}

                try:
                    await s.call_tool(BENIGN_TOOL, {"claim_id": CLAIM_ID})
                    benign_ok, benign_err = True, None
                except Exception as e:  # noqa: BLE001
                    benign_ok, benign_err = False, f"{type(e).__name__}: {str(e)[:160]}"

                # Visibility and callability are SEPARATE enforcement points — check both. A tool
                # filtered from tools/list but still callable would be a real hole.
                sid = get_sid() if callable(get_sid) else None
                status, err = await _call_raw(
                    token, sid, SENSITIVE_TOOL, {"claim_id": CLAIM_ID}, extra)

        blocked = status >= 400 or err is not None
        _app_log(traceparent, action=SENSITIVE_TOOL, claim_id=CLAIM_ID,
                 result="refused" if blocked else "approved", http_status=status)
        return {
            "mcp_url": MCP_URL,
            "tools_visible": tools,
            "benign_tool": BENIGN_TOOL,
            "benign_ok": benign_ok,
            "benign_error": benign_err,
            "sensitive_tool": SENSITIVE_TOOL,
            "sensitive_visible": SENSITIVE_TOOL in tools,
            "sensitive_permitted": not blocked,
            "sensitive_error": (f"HTTP {status}"
                                + (f" {err.get('code')}: {err.get('message')}" if err else "")
                                ) if blocked else None,
            "whoami": whoami,
        }
    except BaseException as e:  # noqa: BLE001  (ExceptionGroup is a BaseException)
        return {"mcp_url": MCP_URL, "error": _explain(e)}


def handle(headers) -> dict:
    saw = _saw(headers)
    traceparent = {k.lower(): v for k, v in headers.items()}.get("traceparent", "") or ""
    token = ""
    auth = {k.lower(): v for k, v in headers.items()}.get("authorization", "") or ""
    if auth.lower().startswith("bearer "):
        token = auth[7:].strip()
    elif auth:
        token = auth.strip()

    return {
        "agent": AGENT_NAME,
        "status": "reached",
        "saw": saw,
        "traceparent": traceparent,
        "mcp": (asyncio.run(_mcp_probe(token, traceparent)) if token
                else {"skipped": "no credential arrived — checkpoint 1 attached nothing, so the "
                                 "Cross App Access exchange did not complete"}),
        "note": "deterministic agent — no LLM invoked",
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _respond(self):
        # /healthz answers without touching the gateway, so the readiness probe never depends on
        # checkpoint 2 being up (or on holding a token).
        if self.path.rstrip("/").endswith("/healthz"):
            body = json.dumps({"ok": True, "agent": AGENT_NAME}).encode()
        else:
            try:
                body = json.dumps(handle(self.headers), indent=2).encode()
            except Exception as e:  # noqa: BLE001
                body = json.dumps({"agent": AGENT_NAME,
                                   "error": f"{type(e).__name__}: {str(e)[:300]}"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # Any method, any path — the agent is a dead-end reporter, so a GET is as valid as a POST and
    # the demo can be driven with a bare curl.
    do_GET = _respond

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)      # drain the body; the agent takes no input
        self._respond()

    def log_message(self, fmt, *args):
        sys.stderr.write(f"{AGENT_NAME} {fmt % args}\n")


if __name__ == "__main__":
    print(f"{AGENT_NAME} listening on :{PORT} — MCP hairpin target {MCP_URL}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
