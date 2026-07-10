#!/usr/bin/env bash
# Device Authorization Grant (RFC 8628) against Okta's custom "default" authorization
# server — the CLI-friendly login: no local redirect listener, just a code to confirm in
# any browser (including one on a different machine, e.g. SSH'd into a devbox). This is
# what Claude Code / Cursor / Copilot use via the apiKeyHelper pattern (see README's Lab 5).
#
# Lives under helpers/ (NOT the bundle root) ON PURPOSE — same reason as okta-pkce-login.sh:
# apply-bundle.sh execs bundle-root *.sh during `solomog apply`, and this opens a browser +
# blocks on human confirmation. Run it by hand:
#   bash bundles/agw-okta-bedrock-llm/helpers/okta-device-login.sh
#
# Caches the token JSON to .solomog/okta-device-token.json (gitignored) and prints the
# access token to stdout — so callers can:  TOKEN=$(okta-device-login.sh)
#
# .env knobs (see .env.example):
#   OKTA_DOMAIN            required   org host, no scheme (e.g. dev-1234567.okta.com)
#   OKTA_DEVICE_CLIENT_ID  required   App E's client id (Device Authorization grant, public)
#   OKTA_DEVICE_SCOPES     optional   default "openid profile offline_access"
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[ -f "$REPO_DIR/.env" ] && set -a && . "$REPO_DIR/.env" && set +a || true

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
: "${OKTA_DEVICE_CLIENT_ID:?set OKTA_DEVICE_CLIENT_ID in .env (the App E client id — see OKTA-SETUP.md)}"

if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi

CACHE="$REPO_DIR/.solomog/okta-device-token.json"
mkdir -p "$REPO_DIR/.solomog"

OKTA_DOMAIN="$OKTA_DOMAIN" \
OKTA_DEVICE_CLIENT_ID="$OKTA_DEVICE_CLIENT_ID" \
OKTA_DEVICE_SCOPES="${OKTA_DEVICE_SCOPES:-openid profile offline_access}" \
CACHE="$CACHE" \
uv run --with requests --python 3.12 - <<'PY'
import base64, json, os, sys, time, webbrowser
import requests

domain    = os.environ["OKTA_DOMAIN"]
client_id = os.environ["OKTA_DEVICE_CLIENT_ID"]
scopes    = os.environ["OKTA_DEVICE_SCOPES"]
cache     = os.environ["CACHE"]

issuer      = f"https://{domain}/oauth2/default"
device_ep   = f"{issuer}/v1/device/authorize"
token_ep    = f"{issuer}/v1/token"

# --- Kick off the device flow -------------------------------------------------------------
r = requests.post(device_ep, data={"client_id": client_id, "scope": scopes})
if r.status_code != 200:
    print(f"✗ device authorize failed ({r.status_code}): {r.text}", file=sys.stderr); sys.exit(1)
d = r.json()
device_code = d["device_code"]
interval    = d.get("interval", 5)

complete_uri = d.get("verification_uri_complete", d["verification_uri"])
print(f"==> Opening browser to confirm login at Okta ({issuer}) ...", file=sys.stderr)
print(f"    If it doesn't open, visit {d['verification_uri']} and enter code: {d['user_code']}\n", file=sys.stderr)
webbrowser.open(complete_uri)

# --- Poll the token endpoint until the user confirms (or it expires) ----------------------
grant_type = "urn:ietf:params:oauth:grant-type:device_code"
deadline = time.time() + d.get("expires_in", 600)
tok = None
while time.time() < deadline:
    time.sleep(interval)
    r = requests.post(token_ep, data={
        "grant_type": grant_type, "device_code": device_code, "client_id": client_id,
    })
    body = r.json()
    if r.status_code == 200:
        tok = body
        break
    err = body.get("error")
    if err == "authorization_pending":
        continue
    if err == "slow_down":
        interval += 5
        continue
    print(f"✗ device flow failed: {body}", file=sys.stderr)
    sys.exit(1)

if tok is None:
    print("✗ timed out waiting for confirmation", file=sys.stderr); sys.exit(1)

with open(cache, "w") as f:
    json.dump(tok, f)

def claims(jwt):
    p = jwt.split(".")[1]; p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))
c = claims(tok["access_token"])
print(f"✓ logged in — access token cached to {cache}", file=sys.stderr)
print(f"  sub={c.get('sub')}  aud={c.get('aud')}  groups={c.get('groups')}  iss={c.get('iss')}", file=sys.stderr)
print(tok["access_token"])   # stdout = the raw token
PY
