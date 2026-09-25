#!/usr/bin/env python3
"""Resource authorization server — LEG 2 of Cross App Access (ID-JAG).

Includes two additions for the audit-evidence demo: ACT_MODE=named (Okta's signed chain, with act.sub set to the readable per-connection alias)
and an `email` claim carried from the ID-JAG, so an audit record names the reviewer legibly.

WHY THIS EXISTS
---------------
Cross App Access needs TWO authorization servers, and they are deliberately in different trust
domains:

  * leg 1 — the **enterprise IdP** (here: real Okta, org authorization server) takes the user's
    OIDC ID token and mints an **ID-JAG** (RFC 8693 token exchange,
    `requested_token_type=urn:ietf:params:oauth:token-type:id-jag`). The ID-JAG is bound to a
    resource AS (`aud`) and records the *requesting app* (the agent) in `client_id`.
  * leg 2 — the **resource app's authorization server** takes that ID-JAG over the RFC 7523
    JWT-bearer grant and issues the access token the resource actually accepts.

Okta plays leg 1. It does **not** play leg 2 — in Okta's model the resource app's AS belongs to the
resource's own domain (Solo's reference example pairs Okta with Auth0, whose XAA support is a
private beta). This process is that resource AS, run in-cluster, so the demo needs exactly one
entitlement (Okta's Cross App Access feature) instead of two.

Running leg 2 ourselves also buys the thing the flavor is *about*: we control the final token's
claims, so the agent identity carried in the Okta-signed ID-JAG (`client_id`) is stamped into the
standardized RFC 8693 **`act`** claim — which is what the gateway's MCP tool RBAC keys on. Read the
trust boundary honestly: the *actor* is cryptographic (it comes out of an Okta-signed assertion this
server verifies), while the *final token* is signed by this server, so it is only as trustworthy as
this deployment. That is the normal resource-AS trust model, but it is worth saying out loud.

WHAT IT IS NOT
--------------
Not a general-purpose AS. No refresh tokens, no introspection, no revocation, no client registry
beyond the single leg-2 client, no DPoP. It implements exactly the one grant agentgateway's
`crossAppAccess` policy calls on leg 2, and it is deliberately strict about it so a
misconfiguration fails loudly rather than minting a token that hides the mistake.

ENDPOINTS
---------
  POST /token                            RFC 7523 jwt-bearer grant: ID-JAG -> access token
  GET  /jwks                             our public JWKS (the gateway validates the final token here)
  GET  /.well-known/openid-configuration discovery, for debugging by hand
  GET  /healthz                          liveness/readiness

ENV
---
  OKTA_DOMAIN            required  Okta org host, no scheme. Leg-1 issuer + JWKS source.
  RESOURCE_AS_ISSUER     required  our own issuer string; MUST equal the ID-JAG `aud` the gateway
                                   requests (crossAppAccess.audience) and the gateway's
                                   jwtAuthentication `issuer` for the final token.
  RESOURCE_API_AUDIENCE  required  `aud` stamped on the final token (the resource identifier).
  RESOURCE_CLIENT_ID     required  the leg-2 client agentgateway authenticates as.
  RESOURCE_CLIENT_SECRET required  its secret.
  SIGNING_KEY_PATH       required  PEM private key used to sign the final token.
  SIGNING_KID            required  `kid` published in /jwks and set in the token header.
  TOKEN_TTL_SECONDS      optional  final-token lifetime (default 900).
  ACT_MODE               optional  named | propagate (default) | synthesize. named keeps Okta's chain
                                   but sets act.sub to the ID-JAG client_id (the alias typed on the
                                   Okta connection) and keeps Okta's own id as act.okta_agent_id.
                                   propagate passes Okta's nested
                                   `act` chain through verbatim, so act.sub is the AGENT's Okta id;
                                   synthesize flattens to the ID-JAG's client_id (the resource-side
                                   alias). 54-tools-rbac.sh reads the same knob to pick the actor it
                                   names, so the two cannot disagree.
  ENTITLEMENTS           optional  JSON map of user -> groups, resolved resource-side because Okta
                                   cannot carry `groups` in an ID-JAG (verified — see the note at
                                   ENTITLEMENTS below). Keys are email or sub; "*" is the default.
                                   e.g. {"alice@corp.test": ["llm-premium"], "*": ["llm-basic"]}
  GROUPS_FALLBACK        optional  space-separated groups granted to EVERYONE when ENTITLEMENTS has
                                   no match. A bring-up shortcut only: it makes the user half of the
                                   RBAC decorative, and `groups_source` reports "fallback" to say so.
  LEEWAY_SECONDS         optional  clock-skew allowance for `nbf`/`iat` only (default 60).
  EXP_LEEWAY_SECONDS     optional  grace period past the ID-JAG's `exp` (default 0 = strict).
  IDJAG_MAX_AGE_SECONDS  optional  reject an assertion older than this many seconds even if it has
                                   not expired (default 0 = off; Okta's reference AS uses 30).
  ALLOWED_ACTORS         optional  comma/space list of permitted ID-JAG `client_id` values. Empty =
                                   accept any. Set it and an unknown actor can never reach `act.sub`.
  STRICT_TYP             optional  reject a header `typ` other than oauth-id-jag+jwt (default off).
                                   Deliberately separate from LEEWAY_SECONDS: skew tolerance is
                                   about when a token BECOMES valid, and reusing it on `exp` would
                                   silently extend every assertion's life (an ID-JAG lives ~300s at
                                   Okta, so 60s of slop is a 20% extension). Strict by default.
"""

import base64
import json
import logging
import os
import re
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jwt
from cryptography.hazmat.primitives import serialization

# ── config ───────────────────────────────────────────────────────────────────────────────────────

JWT_BEARER_GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer"
# The ID-JAG's media type, per the ID-JAG draft. Okta sets this in the JWT header `typ`. We accept
# a plain "JWT" too, because a non-conformant IdP setting the generic type is a far less
# interesting failure than a wrong signature/issuer/audience, and rejecting it here would only
# produce a confusing error during the Okta bring-up.
IDJAG_TYP = "oauth-id-jag+jwt"


def _env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        print(f"FATAL: env {name} is required", file=sys.stderr)
        raise SystemExit(1)
    return v


OKTA_DOMAIN = _env("OKTA_DOMAIN")
OKTA_ISSUER = f"https://{OKTA_DOMAIN}"
OKTA_JWKS_URL = f"https://{OKTA_DOMAIN}/oauth2/v1/keys"  # ORG authorization server (XAA uses it)

RESOURCE_AS_ISSUER = _env("RESOURCE_AS_ISSUER")
RESOURCE_API_AUDIENCE = _env("RESOURCE_API_AUDIENCE")
RESOURCE_CLIENT_ID = _env("RESOURCE_CLIENT_ID")
RESOURCE_CLIENT_SECRET = _env("RESOURCE_CLIENT_SECRET")
SIGNING_KEY_PATH = _env("SIGNING_KEY_PATH")
SIGNING_KID = _env("SIGNING_KID")
TOKEN_TTL = int(os.environ.get("TOKEN_TTL_SECONDS") or 900)
GROUPS_FALLBACK = (os.environ.get("GROUPS_FALLBACK") or "").split()
# ── Resource-side entitlements ───────────────────────────────────────────────────────────────────
# MEASURED 2026-08-05: Okta's ID-JAG does NOT carry `groups`, and it cannot be made to — requesting
# `scope=groups` on leg 1 returns `invalid_scope: The following scopes are not allowed for this
# request: [groups]`, and the org authorization server cannot be given claim mappings. The user's ID
# token does carry groups; the assertion does not.
#
# So the user half of the authorization decision is resolved HERE, by the resource server, keyed on
# the IdP-verified `sub`/`email`. That is not a workaround dressed up — it is how a great many real
# resource servers work: the IdP attests WHO the user is, the resource owns WHAT they may do. The
# distinction is recorded in `groups_source` on every token so a reader can tell which happened.
#
# ENTITLEMENTS is JSON: {"<email-or-sub>": ["group", …], "*": ["default", …]}
def _load_entitlements() -> dict:
    raw = (os.environ.get("ENTITLEMENTS") or "").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        log.error("ENTITLEMENTS is not valid JSON (%s) — treating as empty", exc)
        return {}
    if not isinstance(parsed, dict):
        log.error("ENTITLEMENTS must be a JSON object, got %s — treating as empty", type(parsed).__name__)
        return {}
    out = {}
    for k, v in parsed.items():
        out[k] = v.split() if isinstance(v, str) else list(v)
    return out


ENTITLEMENTS = _load_entitlements()

# How the final token's `act` is built. MEASURED 2026-08-05: Okta's ID-JAG already carries a full
# nested RFC 8693 delegation chain, e.g.
#   "act": {"sub": "<agent wlp id>", "sub_profile": "ai_agent",
#           "act": {"sub": "<login app 0oa id>", "sub_profile": "web_app"}}
# with "sub_profile": "user" alongside `sub`. That is richer and more trustworthy than anything we can
# synthesize — it is IdP-signed and it names every hop — so propagating it is the default.
#   propagate  (default) pass Okta's `act` through verbatim. `act.sub` is then the AGENT's Okta id.
#   synthesize           build {"sub": <ID-JAG client_id>} ourselves. `act.sub` is then the
#                        resource-side alias from the connection form (e.g. priorauth-agent).
# The tool RBAC keys on act.sub, so this choice decides which identity the policy must name — see
# 54-tools-rbac.sh, which reads the same knob.
ACT_MODE = (os.environ.get("ACT_MODE") or "propagate").lower()
LEEWAY = int(os.environ.get("LEEWAY_SECONDS") or 60)
EXP_LEEWAY = int(os.environ.get("EXP_LEEWAY_SECONDS") or 0)
# Replay window. Okta's own reference resource AS (oktadev/okta-cross-app-access-mcp,
# packages/authorization-server/jwt-authorization-grant.js) rejects any assertion with
# `iat < now - 30` — an ID-JAG is meant to be redeemed immediately, so a long-lived one is a replay
# risk even before it expires. 0 disables the check; 30 mirrors the reference.
IDJAG_MAX_AGE = int(os.environ.get("IDJAG_MAX_AGE_SECONDS") or 0)
# Whitelist of agent actor ids (the ID-JAG's `client_id`). RFC 7523 means the assertion was issued
# FOR a specific client, and Okta's reference enforces `claims.client_id == the authenticated client`.
# We cannot use that equality: in this topology the authenticated leg-2 client is the GATEWAY, while
# `client_id` names the agent. Set membership is the faithful analogue — it stops an unknown actor id
# from reaching `act.sub`, which is what the tool RBAC decides on. Empty = accept any (back-compat).
ALLOWED_ACTORS = {a for a in re.split(r"[,\s]+", os.environ.get("ALLOWED_ACTORS") or "") if a}
# Reject a non-conformant `typ` outright instead of warning. Okta's reference is strict here.
STRICT_TYP = (os.environ.get("STRICT_TYP") or "").lower() in ("1", "true", "yes")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("resource-as")

with open(SIGNING_KEY_PATH, "rb") as fh:
    SIGNING_KEY_PEM = fh.read()
_PRIVATE_KEY = serialization.load_pem_private_key(SIGNING_KEY_PEM, password=None)
_PUBLIC_NUMBERS = _PRIVATE_KEY.public_key().public_numbers()

# PyJWT's JWKS client fetches + caches Okta's org signing keys and picks the one matching the
# assertion's `kid`, so key rotation at Okta needs no restart here.
_OKTA_JWKS = jwt.PyJWKClient(OKTA_JWKS_URL, cache_keys=True, lifespan=300)


def _b64u_uint(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


PUBLIC_JWKS = {
    "keys": [
        {
            "kty": "RSA",
            "use": "sig",
            "alg": "RS256",
            "kid": SIGNING_KID,
            "n": _b64u_uint(_PUBLIC_NUMBERS.n),
            "e": _b64u_uint(_PUBLIC_NUMBERS.e),
        }
    ]
}


# ── leg 2: validate the ID-JAG ───────────────────────────────────────────────────────────────────


class OAuthError(Exception):
    """An RFC 6749 §5.2 error response. `status` defaults to 400; 401 for client-auth failures."""

    def __init__(self, error: str, description: str, status: int = 400):
        super().__init__(description)
        self.error = error
        self.description = description
        self.status = status


def validate_idjag(assertion: str) -> dict:
    """Verify the Okta-signed ID-JAG and return its claims.

    Every check here is load-bearing:
      * signature against Okta's ORG JWKS  -> the assertion really came from the enterprise IdP,
                                              which is the ONLY reason the actor identity below can
                                              be called cryptographic rather than self-declared.
      * `iss` == the Okta org issuer       -> not some other IdP's assertion.
      * `aud` == our issuer                -> the ID-JAG was minted *for this resource AS*. Without
                                              this, an ID-JAG bound to a different resource could be
                                              replayed here (the whole point of binding `aud`).
      * exp/nbf                            -> freshness (ID-JAGs are short-lived, ~5 min at Okta).

    `exp` is checked separately from PyJWT's `leeway`, because that one knob would apply the
    nbf/iat clock-skew allowance to expiry as well and quietly extend the life of every assertion.
    """
    try:
        header = jwt.get_unverified_header(assertion)
    except jwt.PyJWTError as exc:
        raise OAuthError("invalid_grant", f"assertion is not a JWT: {exc}") from exc

    typ = (header.get("typ") or "").lower()
    if typ not in (IDJAG_TYP, "jwt", ""):
        if STRICT_TYP:
            raise OAuthError(
                "invalid_grant", f"invalid JWT type, expected typ: {IDJAG_TYP} (got {typ!r})")
        log.warning("assertion typ=%r is neither %r nor JWT — continuing", typ, IDJAG_TYP)
    elif STRICT_TYP and typ != IDJAG_TYP:
        raise OAuthError(
            "invalid_grant", f"invalid JWT type, expected typ: {IDJAG_TYP} (got {typ!r})")

    try:
        signing_key = _OKTA_JWKS.get_signing_key_from_jwt(assertion)
    except Exception as exc:  # noqa: BLE001 - PyJWKClient raises several unrelated types
        raise OAuthError(
            "invalid_grant",
            f"cannot resolve the assertion's signing key at {OKTA_JWKS_URL}: {exc}",
        ) from exc

    try:
        claims = jwt.decode(
            assertion,
            signing_key.key,
            algorithms=["RS256"],
            issuer=OKTA_ISSUER,
            audience=RESOURCE_AS_ISSUER,
            leeway=LEEWAY,
            # exp enforced below with its own (strict) allowance.
            options={"require": ["sub", "aud", "iss", "exp"], "verify_exp": False},
        )
        expiry = int(claims["exp"])
        if time.time() > expiry + EXP_LEEWAY:
            raise jwt.ExpiredSignatureError(
                f"assertion expired at {expiry} ({int(time.time()) - expiry}s ago)")
    except jwt.InvalidAudienceError as exc:
        # By far the most common bring-up failure, so name both sides of the mismatch.
        raise OAuthError(
            "invalid_grant",
            f"assertion aud != this resource AS ({RESOURCE_AS_ISSUER}): {exc}. The gateway's "
            f"crossAppAccess.audience must equal RESOURCE_AS_ISSUER exactly.",
        ) from exc
    except jwt.PyJWTError as exc:
        raise OAuthError("invalid_grant", f"assertion rejected: {exc}") from exc

    # Replay window — deliberately AFTER signature verification, so an unsigned assertion can never
    # reach it. LEEWAY covers clock skew in the other direction.
    if IDJAG_MAX_AGE and "iat" in claims:
        age = time.time() - int(claims["iat"])
        if age > IDJAG_MAX_AGE + LEEWAY:
            raise OAuthError(
                "invalid_grant",
                f"assertion is {int(age)}s old, older than IDJAG_MAX_AGE_SECONDS "
                f"({IDJAG_MAX_AGE}s +{LEEWAY}s skew). An ID-JAG is single-use and short-lived; a "
                f"stale one is a replay.",
            )

    if ALLOWED_ACTORS:
        actor = next((claims[k] for k in ("client_id", "cid", "azp") if claims.get(k)), None)
        if actor not in ALLOWED_ACTORS:
            raise OAuthError(
                "invalid_grant",
                f"assertion actor {actor!r} is not a registered agent for this resource AS. "
                f"Expected one of {sorted(ALLOWED_ACTORS)}. On the Okta AI-Agents path this is the "
                f'"Client ID at the Resource Authorization Server" from the agent connection form '
                f"(XAA_AGENT_*_RESOURCE_CLIENT_ID); on the legacy path it is the app client id.",
            )

    return claims


def actor_from_idjag(claims: dict) -> str:
    """The agent identity: the ID-JAG's requesting-app client.

    The ID-JAG draft carries the requesting party in `client_id`. Okta has historically used `cid`
    for the same idea and `azp` is the OIDC spelling, so accept all three rather than have the demo
    hinge on which one this Okta build emits — whichever is present came out of the signed
    assertion, so all are equally trustworthy.
    """
    for key in ("client_id", "cid", "azp"):
        value = claims.get(key)
        if value:
            return str(value)
    raise OAuthError(
        "invalid_grant",
        "assertion carries no client_id/cid/azp, so there is no agent identity to place in `act`. "
        "Check that leg 1 really returned an ID-JAG (header typ oauth-id-jag+jwt) and not an "
        "ordinary access token.",
    )


def granted_scopes(idjag_claims: dict, requested: str) -> list[str]:
    """Narrow, never escalate.

    The ID-JAG's `scope` is the ceiling Okta authorized for this (user, agent, resource) triple. We
    grant the intersection with what leg 2 asked for, so a gateway policy can only ever request LESS
    than the IdP allowed — the guardrail DESIGN.md calls "narrow, never escalate".
    """
    ceiling = (idjag_claims.get("scope") or idjag_claims.get("scp") or "")
    ceiling_set = set(ceiling.split()) if isinstance(ceiling, str) else set(ceiling)
    asked = set(requested.split())

    if not ceiling_set:
        # No ceiling expressed in the assertion: fall back to what was asked. Logged, because a
        # scopeless ID-JAG usually means the Okta app has no scopes configured.
        log.warning("assertion carries no scope claim; granting the requested scopes verbatim")
        return sorted(asked)
    if not asked:
        return sorted(ceiling_set)
    return sorted(asked & ceiling_set)


def build_act(claims: dict) -> tuple:
    """Return (act, act_sub, act_source) for the final token.

    Propagating preserves the chain, including `act.act` for the app hop — which is the whole point of
    using a standard claim: an auditor can read who acted through whom without knowing our topology.
    Synthesizing flattens it to one actor, which is what a resource AS must do when the IdP asserts no
    chain at all (Okta's own reference implementation drops the actor entirely, so neither is unusual).
    """
    upstream = claims.get("act")
    if ACT_MODE == "propagate" and isinstance(upstream, dict) and upstream.get("sub"):
        return upstream, upstream["sub"], "id-jag"
    if ACT_MODE == "named" and isinstance(upstream, dict) and upstream.get("sub"):
        # Okta's chain, re-headed with the resource-side alias. Both values come out of the same
        # Okta-signed assertion: `client_id` is the "Client ID at the Resource Authorization Server"
        # an admin typed on the agent's connection, and act.sub is Okta's opaque AI Agent id. An
        # auditor reads the alias; the opaque id stays alongside it for correlation with Okta's logs.
        alias = actor_from_idjag(claims)
        named = dict(upstream)
        named["okta_agent_id"] = upstream["sub"]
        named["sub"] = alias
        return named, alias, "id-jag-named"
    # No chain to propagate (or explicitly asked to flatten): fall back to the assertion's client_id.
    actor = actor_from_idjag(claims)
    return {"sub": actor}, actor, "synthesized"


def resolve_groups(claims: dict) -> tuple:
    """Resolve the USER half of the authorization decision, and say where it came from.

    Precedence, most authoritative first:
      1. `groups` in the ID-JAG        -> "id-jag". Never observed on Okta (see ENTITLEMENTS above),
                                          but honoured first so a future IdP that DOES assert groups
                                          silently takes over and the demo needs no change.
      2. ENTITLEMENTS[email]           -> "entitlements:email"
      3. ENTITLEMENTS[sub]             -> "entitlements:sub"
      4. ENTITLEMENTS["*"]             -> "entitlements:default"
      5. GROUPS_FALLBACK               -> "fallback"  (bring-up shortcut; grants the same to everyone,
                                          so it makes the user half of the RBAC decorative)
      6. nothing                       -> "none"

    Keying on `email` first is deliberate: it is human-readable in a demo and it is the claim Okta
    actually puts in the ID-JAG (verified). `sub` is the stable identifier and works when email is
    absent, so both are accepted.
    """
    groups = claims.get("groups")
    if isinstance(groups, str):
        groups = groups.split()
    if groups:
        return list(groups), "id-jag"

    email = claims.get("email")
    if email and email in ENTITLEMENTS:
        return list(ENTITLEMENTS[email]), "entitlements:email"

    sub = claims.get("sub")
    if sub and sub in ENTITLEMENTS:
        return list(ENTITLEMENTS[sub]), "entitlements:sub"

    if "*" in ENTITLEMENTS:
        return list(ENTITLEMENTS["*"]), "entitlements:default"

    if GROUPS_FALLBACK:
        return list(GROUPS_FALLBACK), "fallback"

    return [], "none"


def mint_access_token(idjag_claims: dict, requested_scope: str) -> dict:
    """Issue the final access token — the composite principal (user ⊕ agent)."""
    now = int(time.time())
    act, actor, act_source = build_act(idjag_claims)
    scopes = granted_scopes(idjag_claims, requested_scope)

    groups, groups_source = resolve_groups(idjag_claims)

    claims = {
        "iss": RESOURCE_AS_ISSUER,
        "aud": RESOURCE_API_AUDIENCE,
        "sub": idjag_claims["sub"],          # the USER — delegation preserves the subject
        # Human-readable reviewer identity for the audit record. Okta puts `email` in the ID-JAG
        # (verified in the sibling bundle); absent, the key is simply omitted below.
        "iat": now,
        "nbf": now - LEEWAY,
        "exp": now + TOKEN_TTL,
        # RFC 8693 §4.1: the actor. THIS is the standardized agent identity that makes this flavor
        # different from Flavor 3 (Okta's proprietary `cid`) and Flavor 2 (a self-declared header).
        # Under ACT_MODE=propagate this is Okta's OWN nested chain, signed by the IdP and naming every
        # hop (user ← agent ← login app), not something we assembled.
        "act": act,
        # Which of the two it is, so a reader never has to guess whether the chain is IdP-attested.
        "act_source": act_source,
        # Flat mirror of act.sub. The gateway's RBAC CEL reads `jwt.act.sub`; this duplicate exists
        # purely so the policy can be pivoted to a flat key if nested claim traversal misbehaves on
        # a given build, without redeploying this server. See 54-mcp-tools-rbac.sh.
        "act_sub": actor,
        "azp": RESOURCE_CLIENT_ID,          # the leg-2 client that authenticated (per the docs)
        "client_id": RESOURCE_CLIENT_ID,
        "scp": scopes,                      # list form — matches what `jwt.scp` CEL expects
        "scope": " ".join(scopes),          # string form — what RFC 6749 clients expect
        "groups": groups,
        "groups_source": groups_source,
        # Audit linkage back to the assertion that authorized this token (the delegation chain).
        "idjag_jti": idjag_claims.get("jti"),
        "idjag_iss": idjag_claims.get("iss"),
        # The resource-side alias from the Okta connection form. Under propagate mode it is NOT act.sub
        # any more, but it is still the value the resource admin typed, so keep it for correlation.
        "idjag_client_id": idjag_claims.get("client_id"),
        # Okta types each hop ("user" / "ai_agent" / "web_app"); carry the subject's through.
        **({"sub_profile": idjag_claims["sub_profile"]} if idjag_claims.get("sub_profile") else {}),
        **({"email": idjag_claims["email"]} if idjag_claims.get("email") else {}),
    }

    token = jwt.encode(claims, SIGNING_KEY_PEM, algorithm="RS256", headers={"kid": SIGNING_KID})
    log.info(
        "issued access token sub=%s act.sub=%s (%s) scp=%s groups=%s (%s)",
        claims["sub"], actor, act_source, scopes, groups, groups_source,
    )
    return {
        "access_token": token,
        "token_type": "Bearer",
        "expires_in": TOKEN_TTL,
        "scope": claims["scope"],
        "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
    }


# ── client authentication (leg 2's confidential client) ──────────────────────────────────────────


def authenticate_client(headers, form: dict) -> None:
    """Accept ClientSecretBasic or ClientSecretPost — whichever the gateway policy is set to."""
    client_id = client_secret = None

    auth = headers.get("Authorization", "")
    if auth.lower().startswith("basic "):
        try:
            decoded = base64.b64decode(auth[6:].strip()).decode()
            client_id, _, client_secret = decoded.partition(":")
            # RFC 6749 §2.3.1 form-encodes the two halves before base64.
            client_id = urllib.parse.unquote_plus(client_id)
            client_secret = urllib.parse.unquote_plus(client_secret)
        except Exception as exc:  # noqa: BLE001
            raise OAuthError("invalid_client", f"malformed Basic credentials: {exc}", 401) from exc
    else:
        client_id = form.get("client_id")
        client_secret = form.get("client_secret")

    if not client_id or not client_secret:
        raise OAuthError("invalid_client", "no client credentials presented", 401)
    # Constant-time-ish comparison; the secret is low-value here but there is no reason to leak it.
    ok = client_id == RESOURCE_CLIENT_ID and _consteq(client_secret, RESOURCE_CLIENT_SECRET)
    if not ok:
        raise OAuthError(
            "invalid_client",
            f"unknown client or bad secret (presented client_id={client_id!r}); expected the "
            f"leg-2 resource client",
            401,
        )


def _consteq(a: str, b: str) -> bool:
    import hmac

    return hmac.compare_digest(a.encode(), b.encode())


# ── HTTP plumbing ────────────────────────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "evidence-resource-as/1.0"

    def log_message(self, fmt, *args):  # route access logs through logging, not stderr directly
        log.info("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
        if path == "/jwks":
            self._send_json(200, PUBLIC_JWKS)
        elif path == "/healthz":
            self._send_json(200, {"status": "ok"})
        elif path == "/.well-known/openid-configuration":
            self._send_json(
                200,
                {
                    "issuer": RESOURCE_AS_ISSUER,
                    "token_endpoint": f"{RESOURCE_AS_ISSUER}/token",
                    "jwks_uri": f"{RESOURCE_AS_ISSUER}/jwks",
                    "grant_types_supported": [JWT_BEARER_GRANT],
                    "token_endpoint_auth_methods_supported": [
                        "client_secret_basic",
                        "client_secret_post",
                    ],
                    "id_token_signing_alg_values_supported": ["RS256"],
                },
            )
        else:
            self._send_json(404, {"error": "not_found", "error_description": path})

    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
        if path != "/token":
            self._send_json(404, {"error": "not_found", "error_description": path})
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

        try:
            authenticate_client(self.headers, form)

            grant = form.get("grant_type", "")
            if grant != JWT_BEARER_GRANT:
                raise OAuthError(
                    "unsupported_grant_type",
                    f"this resource AS implements only {JWT_BEARER_GRANT} (leg 2 of Cross App "
                    f"Access); got {grant!r}",
                )
            assertion = form.get("assertion")
            if not assertion:
                raise OAuthError("invalid_request", "missing `assertion` (the ID-JAG)")

            idjag = validate_idjag(assertion)
            self._send_json(200, mint_access_token(idjag, form.get("scope", "")))
        except OAuthError as exc:
            log.warning("token request rejected: %s: %s", exc.error, exc.description)
            self._send_json(exc.status, {"error": exc.error, "error_description": exc.description})
        except Exception as exc:  # noqa: BLE001 - never 500 without an OAuth-shaped body
            log.exception("unhandled error minting a token")
            self._send_json(500, {"error": "server_error", "error_description": str(exc)})


if __name__ == "__main__":
    port = int(os.environ.get("PORT") or 8080)
    log.info("resource AS listening on :%s", port)
    log.info("  issuer          %s", RESOURCE_AS_ISSUER)
    log.info("  token audience  %s", RESOURCE_API_AUDIENCE)
    log.info("  leg-1 IdP       %s (jwks %s)", OKTA_ISSUER, OKTA_JWKS_URL)
    log.info("  leg-2 client    %s", RESOURCE_CLIENT_ID)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
