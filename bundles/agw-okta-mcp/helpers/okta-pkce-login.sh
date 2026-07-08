#!/usr/bin/env bash
# Interactive Authorization Code + PKCE login against Okta's custom "default" authorization
# server — produces a REAL USER access token (human `sub`), which is what the OBO / identity-
# propagation flow needs (unlike the m2m client-credentials token, whose sub is the client).
#
# Lives under helpers/ (NOT the bundle root) ON PURPOSE: apply-bundle.sh execs bundle-root
# *.sh during `solomog apply`, and this flow opens a browser + blocks on human login — it must
# never fire automatically. Run it by hand:  bash bundles/agw-okta-mcp/helpers/okta-pkce-login.sh
#
# It caches the token JSON to .solomog/okta-user-token.json (gitignored) so the OBO tests can
# reuse it within its lifetime, and prints the access token to stdout.
#
# .env knobs (see .env.example):
#   OKTA_DOMAIN            required   org host, no scheme (e.g. dev-1234567.okta.com)
#   OKTA_USER_CLIENT_ID   required   the user-facing OIDC app (Native/Web) client id
#   OKTA_USER_CLIENT_SECRET  optional  set only for a confidential Web app; omit for public/Native
#   OKTA_REDIRECT_URI     optional   default http://localhost:8888/callback (must be registered on the app)
#   OKTA_USER_SCOPES      optional   default "openid profile email mcp.access"
set -euo pipefail

# Load .env from the repo root (this file is bundles/agw-okta-mcp/helpers/, so ../../../).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ -f "$REPO_DIR/.env" ] && set -a && . "$REPO_DIR/.env" && set +a || true

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
: "${OKTA_USER_CLIENT_ID:?set OKTA_USER_CLIENT_ID in .env (your Native/Web OIDC app client id)}"

if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi

CACHE="$REPO_DIR/.solomog/okta-user-token.json"
mkdir -p "$REPO_DIR/.solomog"

OKTA_DOMAIN="$OKTA_DOMAIN" \
OKTA_USER_CLIENT_ID="$OKTA_USER_CLIENT_ID" \
OKTA_USER_CLIENT_SECRET="${OKTA_USER_CLIENT_SECRET:-}" \
OKTA_REDIRECT_URI="${OKTA_REDIRECT_URI:-http://localhost:8888/callback}" \
OKTA_USER_SCOPES="${OKTA_USER_SCOPES:-openid profile email mcp.access}" \
CACHE="$CACHE" \
uv run --with requests --python 3.12 - <<'PY'
import base64, hashlib, http.server, json, os, secrets, sys, threading, urllib.parse, webbrowser
import requests

domain    = os.environ["OKTA_DOMAIN"]
client_id = os.environ["OKTA_USER_CLIENT_ID"]
secret    = os.environ.get("OKTA_USER_CLIENT_SECRET") or ""
redirect  = os.environ["OKTA_REDIRECT_URI"]
scopes    = os.environ["OKTA_USER_SCOPES"]
cache     = os.environ["CACHE"]

issuer   = f"https://{domain}/oauth2/default"
auth_ep  = f"{issuer}/v1/authorize"
token_ep = f"{issuer}/v1/token"

# --- PKCE: random verifier, S256 challenge (RFC 7636) -----------------------------------
verifier  = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state     = secrets.token_urlsafe(16)

parsed = urllib.parse.urlparse(redirect)
host, port = parsed.hostname, parsed.port or 80

authorize_url = auth_ep + "?" + urllib.parse.urlencode({
    "client_id": client_id, "response_type": "code", "scope": scopes,
    "redirect_uri": redirect, "state": state,
    "code_challenge": challenge, "code_challenge_method": "S256",
})

# --- Tiny one-shot localhost server to catch Okta's redirect (the auth code) -------------
result = {}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass          # keep stdout clean
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        result.update({k: v[0] for k, v in q.items()})
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
        ok = "code" in result and result.get("state") == state
        self.wfile.write(b"<h2>Login complete - you can close this tab.</h2>" if ok
                         else b"<h2>Login failed - check the terminal.</h2>")
        threading.Thread(target=self.server.shutdown, daemon=True).start()

srv = http.server.HTTPServer((host, port), Handler)
print(f"==> Opening browser to log in at Okta ({issuer}) ...", file=sys.stderr)
print(f"    If it doesn't open, visit:\n    {authorize_url}\n", file=sys.stderr)
webbrowser.open(authorize_url)
srv.serve_forever()   # returns once Handler calls shutdown()

if result.get("state") != state:
    print(f"✗ state mismatch (possible CSRF) or login error: {result}", file=sys.stderr); sys.exit(1)
if "code" not in result:
    print(f"✗ no authorization code returned: {result}", file=sys.stderr); sys.exit(1)

# --- Exchange the code (+ the verifier) for tokens ---------------------------------------
data = {"grant_type": "authorization_code", "code": result["code"],
        "redirect_uri": redirect, "code_verifier": verifier, "client_id": client_id}
auth = (client_id, secret) if secret else None          # confidential Web app vs public/Native
if secret:
    data.pop("client_id")                               # sent via Basic auth instead
r = requests.post(token_ep, data=data, auth=auth,
                  headers={"Content-Type": "application/x-www-form-urlencoded"})
if r.status_code != 200:
    print(f"✗ token exchange failed ({r.status_code}): {r.text}", file=sys.stderr); sys.exit(1)

tok = r.json()
with open(cache, "w") as f:
    json.dump(tok, f)

# Decode the access token payload just to show the human identity we obtained.
def claims(jwt):
    p = jwt.split(".")[1]; p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))
c = claims(tok["access_token"])
print(f"✓ user logged in — access token cached to {cache}", file=sys.stderr)
print(f"  sub={c.get('sub')}  aud={c.get('aud')}  scp={c.get('scp')}  iss={c.get('iss')}", file=sys.stderr)
print(f"  may_act={c.get('may_act', '(none — needed for delegation; see README)')}", file=sys.stderr)
print(tok["access_token"])   # stdout = the raw token, so callers can:  TOKEN=$(okta-pkce-login.sh)
PY
