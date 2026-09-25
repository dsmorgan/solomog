#!/usr/bin/env bash
# Mint the user's Okta **ID token** — the subject of the Cross App Access exchange.
#
# Lives under helpers/ ON PURPOSE: apply-bundle.sh execs bundle-root *.sh during `solomog apply`,
# and this opens a browser and blocks on a human login, so it must never fire automatically. Run it
# by hand:  bash bundles/agent-audit-evidence/helpers/xaa-login.sh
#
# ONE LOGIN, TWO AGENTS (the default). Cross App Access needs an ID token as the exchange subject, and
# an ID token's `aud` is the client id of the app it was issued to — so the login app and the route's
# edge audience are structurally the same value, which is why one is derived from the other here rather
# than configured twice. What XAA does NOT require is an app per agent: the login app only has to be a
# registered DELEGATED CALLER on each AI Agent (Okta: Directory → AI Agents → <agent> → Delegations).
# Register one app on both agents, set XAA_LOGIN_CLIENT_ID, and this performs a SINGLE browser round
# trip whose token works at every route. That is the shape the sibling flavors assume: one user, one
# login, two agents, one MCP server.
#
# That app is named `xaa-user-login` — for the USER, never for an agent. It is agent-agnostic by design:
# it decides WHO is logging in, and nothing about WHICH agent acts (that is the leg-1 credential the
# route selects). Naming it after an agent also collides with the AI Agents' own names, which makes a
# Delegations row read as if an agent were its own caller. See docs/OKTA-SETUP.md step 3.
#
# TWO LOGIN APPS is still supported and is strictly stronger. Point XAA_AGENT_A_LOGIN_CLIENT_ID and
# _B_ at different apps and each token becomes audience-bound to its agent, so presenting agent A's
# token at agent B's route fails edge validation. The cost is a second Okta app and a second login.
# Share by default; split when the audience is asking how to harden the route selector.
#
# When two apps ARE configured, the two logins are ONE user interaction in practice: after the first,
# Okta has a session cookie, so the second authorize round-trips silently (provided the user is
# assigned to both apps).
#
# ⚠️ Different Okta surface from the sibling bundles. This uses the **org** authorization
# server (/oauth2/v1/*), asks for `openid` (an ID token), and needs a CONFIDENTIAL app (client
# secret). agw-okta-mcp's okta-pkce-login.sh uses the **custom** /oauth2/default server, produces an
# ACCESS token with aud=api://default, and works with a public app. Neither is a substitute for the
# other; both can coexist since they cache to different files.
#
# .env knobs:
#   OKTA_DOMAIN                required   org host, no scheme
#   XAA_LOGIN_CLIENT_ID        recommended  the ONE OIDC app the user signs into, shared by both agents.
#                                         Must be a registered delegated caller on BOTH Okta AI Agents.
#                                         Set this and the per-agent vars below can stay unset.
#   XAA_LOGIN_CLIENT_SECRET    recommended  that app's secret (or XAA_LOGIN_PRIVATE_KEY for a
#                                         "Public key / Private key" app).
#   XAA_AGENT_[AB]_LOGIN_CLIENT_ID
#                              optional   per-agent override — the OIDC APP that performs that agent's
#                                         login. This is the SAME value the route pins as its edge JWT
#                                         audience, which is not a coincidence: the ID token is issued to
#                                         this app, so the login client and the edge audience are
#                                         structurally the same thing. Deriving one from the other means
#                                         they cannot drift. Set A and B to DIFFERENT apps to get the
#                                         audience-bound (hardened) shape.
#   XAA_AGENT_[AB]_LOGIN_CLIENT_SECRET / _LOGIN_PRIVATE_KEY
#                              optional   that per-agent app's own credential. Takes precedence over the
#                                         shared XAA_LOGIN_* pair, so set these only alongside a
#                                         per-agent _LOGIN_CLIENT_ID.
#   XAA_AGENT_[AB]_CLIENT_ID   required   the AI AGENTS' ids (`wlp…`) — the leg-1 clients. Used here ONLY
#                                         as the last-resort audience fallback for the legacy app-to-app
#                                         path, where the app and the leg-1 client are one object. On the
#                                         AI-Agent path that fallback is always wrong, so this script
#                                         refuses to run rather than let Okta answer
#                                         "'redirect_uri' parameter must be a Login redirect URI" with an
#                                         .../instance/null admin link (the id resolves to no app at all).
#   XAA_REDIRECT_URI           optional   default http://localhost:8899/callback — must be registered as
#                                         a Sign-in redirect URI on the login app (on BOTH, if you run
#                                         the two-app shape)
#   XAA_LOGIN_SCOPES           optional   default "openid profile email groups". `groups` is what
#                                         carries the user's groups into the ID token (and, we hope,
#                                         onward into the ID-JAG) — see the note this prints at the end.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ -f "$REPO_DIR/.env" ] && set -a && . "$REPO_DIR/.env" && set +a || true

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
: "${XAA_AGENT_A_CLIENT_ID:?set XAA_AGENT_A_CLIENT_ID in .env — see docs/OKTA-SETUP.md}"
: "${XAA_AGENT_B_CLIENT_ID:?set XAA_AGENT_B_CLIENT_ID in .env}"

# The login app authenticates with EITHER a secret or a key, so require a credential rather than one
# specific kind — demanding the secret would make a key-auth login app impossible to configure.
# XAA_LOGIN_CLIENT_SECRET is the shared-app spelling; the per-agent vars override it.
A_SECRET="${XAA_AGENT_A_LOGIN_CLIENT_SECRET:-${XAA_AGENT_A_CLIENT_SECRET:-${XAA_LOGIN_CLIENT_SECRET:-}}}"
B_SECRET="${XAA_AGENT_B_LOGIN_CLIENT_SECRET:-${XAA_AGENT_B_CLIENT_SECRET:-${XAA_LOGIN_CLIENT_SECRET:-}}}"

# The LOGIN client is the OIDC app, which on the AI-Agent path is NOT the leg-1 client (that is the AI
# Agent). This is the SAME value the route pins as its edge JWT audience, by construction rather than by
# convention: the ID token is issued to this app, so "the app we log in to" and "the audience the route
# accepts" are one value and cannot drift.
# MUST match 44-checkpoint1-policies.sh's A_AUDIENCE/B_AUDIENCE resolution exactly, or the token this
# mints is rejected at the edge by the very route it was minted for.
LOGIN_A="${XAA_AGENT_A_LOGIN_CLIENT_ID:-${XAA_LOGIN_CLIENT_ID:-$XAA_AGENT_A_CLIENT_ID}}"
LOGIN_B="${XAA_AGENT_B_LOGIN_CLIENT_ID:-${XAA_LOGIN_CLIENT_ID:-$XAA_AGENT_B_CLIENT_ID}}"
# ⚠️ Catch the fall-through BEFORE opening a browser. With every login-app var unset the resolution
# above lands on XAA_AGENT_*_CLIENT_ID, which under Path A is the AI Agent — and Okta answers that with
# `'redirect_uri' parameter must be a Login redirect URI` plus an admin link ending `/instance/null`
# (the id resolves to no app at all), which points nowhere near the real cause.
for pair in "A:$LOGIN_A" "B:$LOGIN_B"; do
  u=${pair%%:*}; id=${pair#*:}
  case "$id" in wlp*)
    echo "✗ agent ${u}'s login client resolved to ${id} — an Okta AI AGENT, not an app." >&2
    echo "  An AI Agent has no redirect URI, so the browser login cannot work against it." >&2
    echo "  Set XAA_LOGIN_CLIENT_ID in .env to the OIDC APP's client id (0oa…) — the Web Application" >&2
    echo "  the user signs into — plus XAA_LOGIN_CLIENT_SECRET or XAA_LOGIN_PRIVATE_KEY for that app." >&2
    echo "  See docs/OKTA-SETUP.md step 3. (Only the AI Agent uses private_key_jwt, on leg 1.)" >&2
    exit 1 ;;
  esac
done

if [ "$LOGIN_A" != "$XAA_AGENT_A_CLIENT_ID" ]; then
  echo "  login app A = ${LOGIN_A}  (leg-1 client is ${XAA_AGENT_A_CLIENT_ID} — the AI Agent)"
fi
if [ "$LOGIN_A" = "$LOGIN_B" ]; then
  echo "  login app SHARED by both agents — one browser round trip, one ID token, cached for both"
fi

# The login app's OWN credential. If it is set to "Public key / Private key" a secret cannot work, so
# accept a PEM for it — deliberately a SEPARATE var from XAA_AGENT_*_PRIVATE_KEY, which belongs to the
# AI Agent. On Path B (app == leg-1 client) the two are the same object, so fall back to it there.
LOGIN_KEY_A="${XAA_AGENT_A_LOGIN_PRIVATE_KEY:-${XAA_LOGIN_PRIVATE_KEY:-}}"
LOGIN_KEY_B="${XAA_AGENT_B_LOGIN_PRIVATE_KEY:-${XAA_LOGIN_PRIVATE_KEY:-}}"
if [ -z "$LOGIN_KEY_A" ] && [ "$LOGIN_A" = "${XAA_AGENT_A_CLIENT_ID}" ]; then
  LOGIN_KEY_A="${XAA_AGENT_A_PRIVATE_KEY:-}"
fi
if [ -z "$LOGIN_KEY_B" ] && [ "$LOGIN_B" = "${XAA_AGENT_B_CLIENT_ID}" ]; then
  LOGIN_KEY_B="${XAA_AGENT_B_PRIVATE_KEY:-}"
fi
[ -n "$LOGIN_KEY_A" ] && echo "  login auth A = private_key_jwt (${LOGIN_KEY_A})"
for pair in "A:$LOGIN_KEY_A:$A_SECRET" "B:$LOGIN_KEY_B:$B_SECRET"; do
  u=${pair%%:*}; rest=${pair#*:}; k=${rest%%:*}; sec=${rest#*:}
  if [ -z "$k" ] && [ -z "$sec" ]; then
    echo "✗ agent ${u}: the login app has no credential. Set XAA_AGENT_${u}_LOGIN_PRIVATE_KEY (if the" >&2
    echo "  app uses Public key / Private key) or XAA_AGENT_${u}_LOGIN_CLIENT_SECRET." >&2
    exit 1
  fi
done

if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi

mkdir -p "$REPO_DIR/.solomog"

OKTA_DOMAIN="$OKTA_DOMAIN" \
XAA_AGENT_A_CLIENT_ID="$LOGIN_A" \
XAA_AGENT_A_CLIENT_SECRET="$A_SECRET" \
XAA_AGENT_B_CLIENT_ID="$LOGIN_B" \
XAA_AGENT_B_CLIENT_SECRET="$B_SECRET" \
XAA_AGENT_A_LOGIN_PRIVATE_KEY="$LOGIN_KEY_A" \
XAA_AGENT_B_LOGIN_PRIVATE_KEY="$LOGIN_KEY_B" \
XAA_LOGIN_KEY_KID="${XAA_LOGIN_KEY_KID:-}" \
XAA_REDIRECT_URI="${XAA_REDIRECT_URI:-http://localhost:8899/callback}" \
XAA_LOGIN_SCOPES="${XAA_LOGIN_SCOPES:-openid profile email groups}" \
CACHE_DIR="$REPO_DIR/.solomog" \
uv run --with requests --with 'pyjwt[crypto]>=2.8,<3' --python 3.12 - <<'PY'
import base64, hashlib, http.server, json, os, secrets, sys, threading, time, urllib.parse, webbrowser
import requests

domain    = os.environ["OKTA_DOMAIN"]
redirect  = os.environ["XAA_REDIRECT_URI"]
scopes    = os.environ["XAA_LOGIN_SCOPES"]
cache_dir = os.environ["CACHE_DIR"]

# Cross App Access is served by the ORG authorization server — no /oauth2/default segment.
issuer   = f"https://{domain}"
auth_ep  = f"{issuer}/oauth2/v1/authorize"
token_ep = f"{issuer}/oauth2/v1/token"

parsed = urllib.parse.urlparse(redirect)
host, port = parsed.hostname, parsed.port or 80

AGENTS = [
    ("a", os.environ["XAA_AGENT_A_CLIENT_ID"], os.environ["XAA_AGENT_A_CLIENT_SECRET"],
     os.environ.get("XAA_AGENT_A_LOGIN_PRIVATE_KEY", "")),
    ("b", os.environ["XAA_AGENT_B_CLIENT_ID"], os.environ["XAA_AGENT_B_CLIENT_SECRET"],
     os.environ.get("XAA_AGENT_B_LOGIN_PRIVATE_KEY", "")),
]


def claims(token: str) -> dict:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def client_auth(client_id: str, client_secret: str, key_path: str, token_ep: str):
    """Return (auth, extra_form_fields) for the code exchange.

    An app configured for "Public key / Private key" REJECTS a client secret — and rejects sending no
    credential at all — with an identical `invalid_client`, so the failure does not tell you which
    mode the app is in. Passing the app's PEM here handles that case without flipping the Okta setting
    back and forth. Note this is the LOGIN APP's key, which on Path A is a different key from the AI
    Agent's (that one signs leg 1). Same var name for two objects is exactly the trap.
    """
    if not key_path:
        return (client_id, client_secret), {}
    import jwt as _jwt          # only needed on this path; pyjwt is pulled in by --with below
    now = int(time.time())
    kid = os.environ.get("XAA_LOGIN_KEY_KID") or None
    assertion = _jwt.encode(
        {"iss": client_id, "sub": client_id, "aud": token_ep,
         "jti": secrets.token_urlsafe(16), "iat": now, "exp": now + 300},
        open(key_path).read(), algorithm="RS256",
        headers={"kid": kid} if kid else None,
    )
    return None, {
        "client_id": client_id,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }


def login(letter: str, client_id: str, client_secret: str, key_path: str = "") -> dict:
    """One Authorization Code + PKCE round trip against the org AS, returning the token response.

    `letter` is "a"/"b" when each agent has its own login app, or "shared" when one app serves both —
    it only shapes the messages, since the flow is identical either way.
    """
    # WHO is logging in, for the human-facing strings. "agent A" is wrong when one app serves both.
    who = "the user" if letter == "shared" else f"agent {letter.upper()}"
    env_hint = "" if letter == "shared" else f"_AGENT_{letter.upper()}"
    verifier  = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)

    authorize_url = auth_ep + "?" + urllib.parse.urlencode({
        "client_id": client_id, "response_type": "code", "scope": scopes,
        "redirect_uri": redirect, "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256",
    })

    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):  # keep stdout clean
            pass

        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            result.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            ok = "code" in result and result.get("state") == state
            self.wfile.write(
                f"<h2>{who.capitalize()}: ID token captured - you can close this tab.</h2>".encode()
                if ok else b"<h2>Login failed - check the terminal.</h2>")
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    srv = http.server.HTTPServer((host, port), Handler)
    print(f"==> {who}: logging in at Okta as client {client_id}", file=sys.stderr)
    print(f"    if the browser doesn't open, visit:\n    {authorize_url}\n", file=sys.stderr)
    webbrowser.open(authorize_url)
    srv.serve_forever()   # returns once Handler calls shutdown()

    if result.get("state") != state:
        raise SystemExit(f"✗ {who}: state mismatch or login error: {result}")
    if "code" not in result:
        # Okta puts the real reason in error_description — surface it rather than a generic message.
        raise SystemExit(
            f"✗ {who}: no authorization code. Okta said: "
            f"{result.get('error')}: {result.get('error_description')}\n"
            f"  Common causes: the redirect URI is not registered on this app, the user is not "
            f"assigned to it, or the app is not an Authorization Code (Web) app.")

    auth, extra = client_auth(client_id, client_secret, key_path, token_ep)
    r = requests.post(
        token_ep,
        data={"grant_type": "authorization_code", "code": result["code"],
              "redirect_uri": redirect, "code_verifier": verifier, **extra},
        auth=auth,                         # None when authenticating with a client_assertion
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30,
    )
    if r.status_code != 200:
        hint = ""
        if "invalid_client" in r.text:
            hint = (
                "\n  invalid_client here means the LOGIN APP rejected these credentials. It looks the "
                "same whether\n  the secret is wrong, the secret is stale, or the app is set to "
                '"Public key / Private key"\n  (which rejects secrets AND no-credential identically). '
                "Either:\n"
                "    • set XAA%s_LOGIN_PRIVATE_KEY to the APP's PEM (not the AI Agent's), or\n"
                "    • switch the app back to Client secret in Okta and re-copy the secret\n"
                "  Reminder: on Path A the app and the agent are different objects with different "
                "credentials." % env_hint
            )
        raise SystemExit(
            f"✗ {who}: code exchange failed ({r.status_code}): {r.text}{hint}")
    tok = r.json()
    if "id_token" not in tok:
        raise SystemExit(
            f"✗ {who}: no id_token in the response (got {sorted(tok)}). "
            f"Add `openid` to XAA_LOGIN_SCOPES and confirm the app grants it.")
    return tok


SHARED_CACHE = os.path.join(cache_dir, "xaa-id-token.json")
def per_cache(letter): return os.path.join(cache_dir, f"xaa-id-token-{letter}.json")


def write_cache(path: str, tok: dict) -> str:
    with open(path, "w") as fh:
        json.dump(tok, fh)
    return path


def drop(paths) -> list:
    """Remove cache files belonging to the OTHER layout.

    Exactly one layout must be on disk at a time. A leftover per-letter file from a previous two-app
    run would otherwise be preferred by helpers/xaa-token-path.sh and feed that agent a token minted
    for a different app — a 401 with a perfectly valid-looking cache sitting there. Cheaper to delete
    than to explain.
    """
    gone = []
    for p in paths:
        if os.path.exists(p):
            os.remove(p)
            gone.append(os.path.basename(p))
    return gone


# ONE login app -> ONE token -> ONE cache file. Both agents read it, which is the point: the same
# human credential drives /xaa-agent-a and /xaa-agent-b, so any difference in tool access is
# attributable to the agent's identity and nothing else.
shared = len({a[1] for a in AGENTS}) == 1

saw_groups = None
if shared:
    letter, client_id, client_secret, key_path = AGENTS[0]
    tok = login("shared", client_id, client_secret, key_path)
    path = write_cache(SHARED_CACHE, tok)
    stale = drop([per_cache(l) for l, *_ in AGENTS])
    c = claims(tok["id_token"])
    saw_groups = c.get("groups")
    print(f"✓ ONE ID token cached to {path} — used by both agents", file=sys.stderr)
    print(f"  sub={c.get('sub')}  aud={c.get('aud')}  iss={c.get('iss')}", file=sys.stderr)
    print(f"  groups={saw_groups if saw_groups else '(none)'}", file=sys.stderr)
    if stale:
        print(f"  removed stale per-agent caches: {', '.join(stale)}", file=sys.stderr)
    print("  the SAME credential drives /xaa-agent-a and /xaa-agent-b, so any difference in tool",
          file=sys.stderr)
    print("  access is the agent's identity, not the user's.", file=sys.stderr)
else:
    for letter, client_id, client_secret, key_path in AGENTS:
        tok = login(letter, client_id, client_secret, key_path)
        path = write_cache(per_cache(letter), tok)
        c = claims(tok["id_token"])
        groups = c.get("groups")
        saw_groups = groups if saw_groups is None else saw_groups
        print(f"✓ agent {letter.upper()} ID token cached to {path}", file=sys.stderr)
        print(f"  sub={c.get('sub')}  aud={c.get('aud')}  iss={c.get('iss')}", file=sys.stderr)
        print(f"  groups={groups if groups else '(none)'}", file=sys.stderr)
    stale = drop([SHARED_CACHE])
    if stale:
        print(f"  removed stale shared cache: {', '.join(stale)}", file=sys.stderr)

print("", file=sys.stderr)
# The ID token's groups are INFORMATIONAL here. Okta cannot put groups in an ID-JAG at all (the org
# AS supports no claim mappings and rejects scope=groups), so the tool RBAC's user half comes from the
# resource AS's own entitlement map either way — XAA_PRIVILEGED_USERS keyed on the ID-JAG's email.
if not saw_groups:
    print("ℹ️  no `groups` claim in the ID token — expected, and it does not matter: Okta cannot carry",
          file=sys.stderr)
    print("    groups into an ID-JAG. The RBAC's user half is resolved by the resource AS from",
          file=sys.stderr)
    print("    XAA_PRIVILEGED_USERS; tests/20 prints which rung won as groups_source.", file=sys.stderr)
else:
    print("ℹ️  groups claim present in the ID token, but it is dropped at leg 1 — the resource AS",
          file=sys.stderr)
    print("    resolves the RBAC's user half from XAA_PRIVILEGED_USERS instead.", file=sys.stderr)
PY
