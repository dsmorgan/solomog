"""Offline end-to-end exercise of src/resource_as.py — leg 2 without Okta.

Fakes the enterprise IdP: generates an RSA key, mints an ID-JAG with it, stubs the module's JWKS
client to return the matching public key, then drives the real HTTP /token endpoint.
"""
import base64, importlib.util, json, os, sys, tempfile, threading, time, urllib.request, urllib.error

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

SRC = sys.argv[1]
PORT = 18099
OKTA_DOMAIN = "dev-fake.okta.com"
AS_ISSUER = "https://evidence-resource-as.agent-evidence.svc.cluster.local"
RESOURCE_API = "https://claims.evidence.test/mcp"
CLIENT_ID, CLIENT_SECRET = "xaa-resource-client", "s3cr3t"
AGENT_A = "0oaAAAAAAAAAAAAAAAAA"

tmp = tempfile.mkdtemp()

# the AS's own signing key
as_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
as_pem = os.path.join(tmp, "private.pem")
with open(as_pem, "wb") as fh:
    fh.write(as_key.private_bytes(serialization.Encoding.PEM,
                                 serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption()))

# the fake IdP's key (stands in for Okta's org signing key)
idp_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
idp_pem = idp_key.private_bytes(serialization.Encoding.PEM,
                                serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())

os.environ.update(
    OKTA_DOMAIN=OKTA_DOMAIN, RESOURCE_AS_ISSUER=AS_ISSUER,
    RESOURCE_API_AUDIENCE=RESOURCE_API, RESOURCE_CLIENT_ID=CLIENT_ID,
    RESOURCE_CLIENT_SECRET=CLIENT_SECRET, SIGNING_KEY_PATH=as_pem,
    SIGNING_KID="test-kid", GROUPS_FALLBACK="llm-premium", PORT=str(PORT),
)

spec = importlib.util.spec_from_file_location("resource_as", SRC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeJWKS:
    """Stands in for PyJWKClient — always returns the fake IdP's public key."""
    class _K:
        def __init__(self, key): self.key = key
    def get_signing_key_from_jwt(self, token):
        return self._K(idp_key.public_key())


mod._OKTA_JWKS = FakeJWKS()

srv = mod.ThreadingHTTPServer(("127.0.0.1", PORT), mod.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()


def mint_idjag(typ="oauth-id-jag+jwt", **over):
    now = int(time.time())
    claims = {
        "iss": f"https://{OKTA_DOMAIN}", "aud": AS_ISSUER, "sub": "alice@example.test",
        "client_id": AGENT_A, "scope": "claims.read claims.approve",
        "groups": ["llm-premium", "claims-admin"],
        "email": "alice@example.test",
        "iat": now, "exp": now + 300, "jti": "idjag-abc123",
    }
    claims.update(over)
    for k in [k for k, v in claims.items() if v is None]:
        del claims[k]
    return jwt.encode(claims, idp_pem, algorithm="RS256",
                      headers={"typ": typ, "kid": "okta-kid"})


def post_token(assertion, scope="claims.read claims.approve", secret=CLIENT_SECRET,
               grant="urn:ietf:params:oauth:grant-type:jwt-bearer"):
    body = urllib.parse.urlencode(
        {"grant_type": grant, "assertion": assertion, "scope": scope}).encode()
    basic = base64.b64encode(f"{CLIENT_ID}:{secret}".encode()).decode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/token", data=body,
                                 headers={"Authorization": f"Basic {basic}",
                                          "Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def claims_of(token):
    p = token.split(".")[1]
    p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))


results = []


def check(name, cond, detail=""):
    results.append((name, cond, detail))
    print(("  ✓ " if cond else "  ✗ ") + name + (f"   {detail}" if detail and not cond else ""))


print("── happy path ─────────────────────────────────────────────")
status, resp = post_token(mint_idjag())
check("leg 2 returns 200", status == 200, f"got {status}: {resp}")
if status == 200:
    c = claims_of(resp["access_token"])
    print(f"    minted claims: {json.dumps({k: c[k] for k in ('sub','act','act_sub','azp','aud','iss','scp','groups','groups_source','idjag_jti')}, indent=6)}")
    check("sub preserved (the user)", c["sub"] == "alice@example.test")
    check("act.sub == the agent from the ID-JAG client_id", c["act"]["sub"] == AGENT_A)
    check("act_sub flat mirror matches", c["act_sub"] == AGENT_A)
    check("aud == the resource identifier", c["aud"] == RESOURCE_API)
    check("iss == the resource AS", c["iss"] == AS_ISSUER)
    check("azp == the leg-2 client", c["azp"] == CLIENT_ID)
    check("groups carried from the ID-JAG", c["groups"] == ["llm-premium", "claims-admin"])
    check("groups_source == id-jag", c["groups_source"] == "id-jag")
    check("scp granted both scopes", sorted(c["scp"]) == ["claims.approve", "claims.read"])
    check("idjag_jti recorded for audit", c["idjag_jti"] == "idjag-abc123")
    check("token header carries our kid",
          jwt.get_unverified_header(resp["access_token"])["kid"] == "test-kid")

print("── narrow, never escalate ─────────────────────────────────")
# ID-JAG ceiling is read-only; request write anyway -> must NOT be granted.
status, resp = post_token(mint_idjag(scope="claims.read"), scope="claims.read claims.approve")
if status == 200:
    c = claims_of(resp["access_token"])
    check("requested scope above the ID-JAG ceiling is dropped", c["scp"] == ["claims.read"],
          f"got {c['scp']}")
else:
    check("requested scope above the ceiling is dropped", False, f"{status}: {resp}")

print("── groups fallback (ID-JAG carries none) ──────────────────")
status, resp = post_token(mint_idjag(groups=None))
if status == 200:
    c = claims_of(resp["access_token"])
    check("falls back to GROUPS_FALLBACK", c["groups"] == ["llm-premium"], f"got {c['groups']}")
    check("and reports groups_source=fallback", c["groups_source"] == "fallback")
else:
    check("groups fallback path", False, f"{status}: {resp}")

print("── rejections ─────────────────────────────────────────────")
status, resp = post_token(mint_idjag(aud="https://some-other-resource.example"))
check("wrong ID-JAG aud rejected (replay containment)",
      status == 400 and resp["error"] == "invalid_grant", f"{status}: {resp}")
check("  ...and the error names both sides", "resource AS" in resp.get("error_description", ""))

status, resp = post_token(mint_idjag(iss="https://evil.example"))
check("wrong issuer rejected", status == 400 and resp["error"] == "invalid_grant", f"{status}: {resp}")

status, resp = post_token(mint_idjag(exp=int(time.time()) - 10))
check("expired assertion rejected", status == 400 and resp["error"] == "invalid_grant", f"{status}: {resp}")

status, resp = post_token(mint_idjag(client_id=None, cid=None, azp=None))
check("assertion with no agent identity rejected",
      status == 400 and "no client_id" in resp.get("error_description", ""), f"{status}: {resp}")

status, resp = post_token(mint_idjag(), secret="wrong")
check("bad leg-2 client secret rejected 401",
      status == 401 and resp["error"] == "invalid_client", f"{status}: {resp}")

status, resp = post_token(mint_idjag(), grant="authorization_code")
check("wrong grant_type rejected",
      status == 400 and resp["error"] == "unsupported_grant_type", f"{status}: {resp}")

print("── the act delegation chain (Okta signs a nested one; we propagate it) ────────")

# What Okta actually issues, verified against a developer org on 2026-08-05.
OKTA_ACT = {"sub": "wlp15zoksrttxdR7C698", "sub_profile": "ai_agent",
            "act": {"sub": "0oa15zl1hmqnl5bA7698", "sub_profile": "web_app"}}

status, resp = post_token(mint_idjag(act=OKTA_ACT, sub_profile="user"))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("propagate: act chain passed through verbatim", c.get("act") == OKTA_ACT, json.dumps(c.get("act")))
check("  ...act.sub is the AGENT, not the connection alias",
      c.get("act", {}).get("sub") == "wlp15zoksrttxdR7C698")
check("  ...the app hop survives in act.act",
      c.get("act", {}).get("act", {}).get("sub") == "0oa15zl1hmqnl5bA7698")
check("  ...flat act_sub mirrors the chain head", c.get("act_sub") == "wlp15zoksrttxdR7C698")
check("  ...act_source says id-jag", c.get("act_source") == "id-jag")
check("  ...sub_profile carried through", c.get("sub_profile") == "user")
check("  ...and the connection alias is still recorded for correlation",
      c.get("idjag_client_id") == AGENT_A, c.get("idjag_client_id"))

# An IdP that asserts NO chain must still yield a usable actor — Okta's own reference AS drops the
# actor entirely, so this is the realistic non-Okta case, not a hypothetical.
status, resp = post_token(mint_idjag(act=None))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("no upstream chain -> synthesized from client_id", c.get("act") == {"sub": AGENT_A},
      json.dumps(c.get("act")))
check("  ...act_source says synthesized", c.get("act_source") == "synthesized")

mod.ACT_MODE = "named"
status, resp = post_token(mint_idjag(act=OKTA_ACT))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("named: act.sub is the connection alias", c.get("act", {}).get("sub") == AGENT_A,
      json.dumps(c.get("act")))
check("  ...Okta's own agent id kept as act.okta_agent_id",
      c.get("act", {}).get("okta_agent_id") == "wlp15zoksrttxdR7C698")
check("  ...the app hop still survives in act.act",
      c.get("act", {}).get("act", {}).get("sub") == "0oa15zl1hmqnl5bA7698")
check("  ...act_source says id-jag-named", c.get("act_source") == "id-jag-named")
check("  ...email carried into the final token", c.get("email") == "alice@example.test")

mod.ACT_MODE = "synthesize"
status, resp = post_token(mint_idjag(act=OKTA_ACT))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("synthesize mode flattens even when a chain exists", c.get("act") == {"sub": AGENT_A},
      json.dumps(c.get("act")))
check("  ...act_source says synthesized", c.get("act_source") == "synthesized")
mod.ACT_MODE = "propagate"

print("── resource-side entitlements (Okta cannot carry groups in an ID-JAG) ────────")

# Precedence is the whole point here, so exercise each rung of the ladder rather than just the happy
# path. mod.ENTITLEMENTS is set directly, the same way _OKTA_JWKS is stubbed above.
mod.ENTITLEMENTS = {"alice@example.test": ["llm-premium", "claims-admin"],
                    "00uOTHER": ["llm-basic"],
                    "*": ["llm-guest"]}
mod.GROUPS_FALLBACK = ["should-never-be-used"]

status, resp = post_token(mint_idjag(email="alice@example.test", groups=None))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("entitlements matched on email", c.get("groups") == ["llm-premium", "claims-admin"],
      f"{status}: {c.get('groups')}")
check("  ...and groups_source says so", c.get("groups_source") == "entitlements:email",
      c.get("groups_source"))

status, resp = post_token(mint_idjag(sub="00uOTHER", email=None, groups=None))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("entitlements matched on sub when email is absent", c.get("groups") == ["llm-basic"],
      f"{status}: {c.get('groups')}")
check("  ...reported as entitlements:sub", c.get("groups_source") == "entitlements:sub")

status, resp = post_token(mint_idjag(sub="00uNOBODY", email="nobody@example.test", groups=None))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("an unlisted user falls to the \"*\" default", c.get("groups") == ["llm-guest"],
      f"{status}: {c.get('groups')}")
check("  ...reported as entitlements:default", c.get("groups_source") == "entitlements:default")

# A future IdP that DOES assert groups must win over our local map, or the demo would silently keep
# using stale local entitlements after the IdP gained the capability.
status, resp = post_token(mint_idjag(email="alice@example.test", groups=["from-the-idp"]))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("an ID-JAG that DOES carry groups outranks the local map", c.get("groups") == ["from-the-idp"],
      f"{status}: {c.get('groups')}")
check("  ...reported as id-jag", c.get("groups_source") == "id-jag")

# With no map at all, the blunt fallback still works but must announce itself.
mod.ENTITLEMENTS = {}
status, resp = post_token(mint_idjag(email="alice@example.test", groups=None))
c = claims_of(resp["access_token"]) if status == 200 else {}
check("no map -> GROUPS_FALLBACK, flagged as such", c.get("groups_source") == "fallback",
      c.get("groups_source"))

mod.ENTITLEMENTS = {"alice@example.test": ["llm-premium", "claims-admin"]}
mod.GROUPS_FALLBACK = ["llm-premium"]

print("── hardening the Okta reference AS enforces (oktadev/okta-cross-app-access-mcp) ────────")

# Their jwt-authorization-grant.js rejects `iat < now - 30`: an ID-JAG is meant to be redeemed
# immediately, so a still-unexpired but stale one is a replay risk. Ours is off by default, so prove
# BOTH directions — that the knob is what rejects, not staleness in general.
stale = mint_idjag(iat=int(time.time()) - 600)          # exp is still 300s in the future
status, resp = post_token(stale)
check("stale-but-unexpired assertion accepted when IDJAG_MAX_AGE_SECONDS is off",
      status == 200, f"{status}: {resp}")

mod.IDJAG_MAX_AGE = 30
status, resp = post_token(stale)
check("  ...and rejected once the replay window is set",
      status == 400 and resp["error"] == "invalid_grant", f"{status}: {resp}")
check("  ...with an error that says why", "replay" in resp.get("error_description", "").lower(),
      resp.get("error_description"))
status, _ = post_token(mint_idjag())
check("  ...while a FRESH assertion still passes", status == 200)
mod.IDJAG_MAX_AGE = 0

# RFC 7523 means the assertion was issued FOR a specific client, and their AS enforces
# client_id == the authenticated client. We cannot: our leg-2 client is the gateway, while client_id
# names the agent. Set membership is the faithful analogue — an unknown actor must not reach act.sub.
mod.ALLOWED_ACTORS = {AGENT_A}
status, resp = post_token(mint_idjag(client_id="some-unregistered-agent"))
check("unregistered actor rejected when ALLOWED_ACTORS is set",
      status == 400 and resp["error"] == "invalid_grant", f"{status}: {resp}")
check("  ...and the error names the expected actors", AGENT_A in resp.get("error_description", ""),
      resp.get("error_description"))
status, resp = post_token(mint_idjag())
check("  ...while a registered actor passes", status == 200, f"{status}: {resp}")
mod.ALLOWED_ACTORS = set()

# Their AS hard-rejects a header typ other than oauth-id-jag+jwt. Ours warns by default (a
# non-conformant IdP is likelier than an attack) but can be made strict.
status, resp = post_token(mint_idjag(typ="JWT"))
check("generic typ=JWT tolerated by default", status == 200, f"{status}: {resp}")
mod.STRICT_TYP = True
status, resp = post_token(mint_idjag(typ="JWT"))
check("  ...and rejected under STRICT_TYP",
      status == 400 and resp["error"] == "invalid_grant", f"{status}: {resp}")
status, _ = post_token(mint_idjag())
check("  ...while the conformant typ still passes", status == 200)
mod.STRICT_TYP = False

print("── the discovery + jwks endpoints the gateway uses ────────")
with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/jwks") as r:
    jwks = json.load(r)
check("/jwks serves one RSA key with our kid",
      len(jwks["keys"]) == 1 and jwks["keys"][0]["kid"] == "test-kid" and jwks["keys"][0]["alg"] == "RS256")
# the real proof: can a JWKS consumer verify a token we minted?
status, resp = post_token(mint_idjag())
pub = jwt.PyJWK(jwks["keys"][0]).key
verified = jwt.decode(resp["access_token"], pub, algorithms=["RS256"],
                      audience=RESOURCE_API, issuer=AS_ISSUER)
check("a token minted by the AS verifies against its published JWKS", verified["sub"] == "alice@example.test")
with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/healthz") as r:
    check("/healthz ok", json.load(r)["status"] == "ok")

srv.shutdown()
failed = [n for n, ok, _ in results if not ok]
print("\n" + ("=" * 60))
print(f"{len(results) - len(failed)}/{len(results)} passed")
if failed:
    print("FAILED: " + ", ".join(failed))
sys.exit(1 if failed else 0)
