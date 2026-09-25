#!/usr/bin/env python3
"""Claims MCP server: the protected resource behind the checkpoint.

A small prior-authorization tool set for a health-insurer demo. Three benign tools any claims agent
may use, one sensitive tool (`approve_prior_auth`) that only a named agent acting for an entitled
reviewer may see or call, and `whoami` for introspection.

The server makes NO authorization decision. The gateway validated the token and applied the tool
policy before the relay forwarded the call. That is the point of the demo: the control, and the
evidence of it, live at the checkpoint rather than in each application.

Each tool call also prints an APPLICATION LOG line to stdout, in the server's own words, carrying
the W3C trace id it received. That line is deliberately "what an app team logs today": useful, and
self-reported. The gateway's access record for the same call carries the same trace id, which is how
the two join (tests/80, helpers/evidence-query.sh).
"""

import base64
import json
import sys
import time

from mcp.server.fastmcp import Context, FastMCP

# stateless_http=True: each request is self-contained, which is what the gateway's MCP relay wants.
mcp = FastMCP(host="0.0.0.0", port=8000, stateless_http=True)

CLAIMS = {
    "CLM-1001": {"member": "M-20417", "procedure": "MRI lumbar spine", "cpt": "72148",
                 "status": "pending-prior-auth", "requested_by": "Dr. Okafor"},
    "CLM-1002": {"member": "M-31108", "procedure": "Physical therapy x12", "cpt": "97110",
                 "status": "pending-prior-auth", "requested_by": "Dr. Lindqvist"},
}


def _headers(ctx: Context) -> dict:
    try:
        req = getattr(getattr(ctx, "request_context", None), "request", None)
        if req is not None and getattr(req, "headers", None) is not None:
            return {k.lower(): v for k, v in req.headers.items()}
    except Exception:  # noqa: BLE001
        pass
    return {}


def _claims(token: str) -> dict:
    """Decode a JWT payload WITHOUT verifying it. Safe only because the gateway already did."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # noqa: BLE001
        return {}


def _token_claims(ctx: Context) -> dict:
    auth = _headers(ctx).get("authorization", "")
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else auth.strip()
    return _claims(token)


def _trace_id(ctx: Context) -> str:
    # traceparent = version-traceid-spanid-flags
    tp = _headers(ctx).get("traceparent", "")
    parts = tp.split("-")
    return parts[1] if len(parts) == 4 else ""


def _app_log(ctx: Context, action: str, **fields) -> None:
    """The application's own account of what happened. Self-reported, by design."""
    c = _token_claims(ctx)
    act = c.get("act") or {}
    line = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "claims-mcp",
        "trace_id": _trace_id(ctx),
        "action": action,
        "user": c.get("email") or c.get("sub"),
        "agent": act.get("sub") if isinstance(act, dict) else None,
        **fields,
    }
    print("app-log " + json.dumps(line), file=sys.stdout, flush=True)


# ── benign tools ─────────────────────────────────────────────────────────────────────────────────


@mcp.tool()
def get_claim(claim_id: str = "CLM-1001", ctx: Context = None) -> dict:
    """Read a claim record."""
    _app_log(ctx, "get_claim", claim_id=claim_id)
    return {"claim_id": claim_id, **CLAIMS.get(claim_id, {"status": "not-found"})}


@mcp.tool()
def check_eligibility(member_id: str = "M-20417", ctx: Context = None) -> dict:
    """Check a member's plan eligibility for a procedure."""
    _app_log(ctx, "check_eligibility", member_id=member_id)
    return {"member_id": member_id, "eligible": True, "plan": "PPO Gold", "requires_prior_auth": True}


@mcp.tool()
def summarize_record(claim_id: str = "CLM-1001", ctx: Context = None) -> dict:
    """Summarize the clinical notes attached to a claim."""
    _app_log(ctx, "summarize_record", claim_id=claim_id)
    return {"claim_id": claim_id,
            "summary": "Chronic lower back pain, 8 weeks conservative therapy, no red flags."}


# ── the sensitive tool: the tool policy's target ─────────────────────────────────────────────────


@mcp.tool()
def approve_prior_auth(claim_id: str = "CLM-1001", ctx: Context = None) -> dict:
    """Approve a prior-authorization request (SENSITIVE: named agents acting for reviewers only)."""
    _app_log(ctx, "approve_prior_auth", claim_id=claim_id, result="approved")
    return {"claim_id": claim_id, "decision": "approved", "status": "prior-auth-approved"}


# ── identity introspection ───────────────────────────────────────────────────────────────────────


@mcp.tool()
def whoami(ctx: Context) -> dict:
    """Report the identity claims of the token this server received."""
    c = _token_claims(ctx)
    act = c.get("act") or {}
    return {
        "sub": c.get("sub"),
        "email": c.get("email"),
        "act": act,
        "act_sub": act.get("sub") if isinstance(act, dict) else c.get("act_sub"),
        "iss": c.get("iss"),
        "aud": c.get("aud"),
        "scp": c.get("scp"),
        "groups": c.get("groups"),
        "trace_id": _trace_id(ctx),
    }


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
