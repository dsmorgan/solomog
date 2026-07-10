#!/usr/bin/env bash
# Lab 5 — apiKeyHelper for Claude Code (and a token source for Cursor/Copilot).
#
# Prints a VALID Okta access token to stdout, and NOTHING else on stdout (Claude Code sends
# whatever this prints as the bearer). Diagnostics go to stderr. Claude Code re-runs the
# apiKeyHelper when the token TTL lapses or the gateway returns 401 — so the job here is to
# make that re-run cheap and SILENT whenever possible:
#
#   1. cached access token still valid  → print it (no network, instant)
#   2. expired but we have a refresh_token → refresh silently at Okta → print the new one
#   3. no cache / refresh rejected → fall back to the full device flow (okta-device-login.sh,
#      which opens a browser). Only this last path is interactive.
#
# The device login requests `offline_access` by default, so step 2 normally works and Okta
# re-auth stays invisible — exactly the workshop's "refresh-token extension" behavior.
#
# Wire it up (see TOOL-INTEGRATION.md):
#   ~/.claude/settings.json → { "apiKeyHelper": "<repo>/bundles/agw-okta-bedrock-llm/helpers/ag-token.sh" }
#   export ANTHROPIC_BASE_URL=https://agw.<cluster>.test/bedrock/premium
set -euo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HELPER_DIR/../../.." && pwd)"
[ -f "$REPO_DIR/.env" ] && set -a && . "$REPO_DIR/.env" && set +a || true

: "${OKTA_DOMAIN:?set OKTA_DOMAIN in .env}"
: "${OKTA_DEVICE_CLIENT_ID:?set OKTA_DEVICE_CLIENT_ID in .env (App E — see OKTA-SETUP.md)}"

command -v uv >/dev/null 2>&1 || { echo "✗ uv not found — brew install uv (or: solomog setup)" >&2; exit 1; }

CACHE="$REPO_DIR/.solomog/okta-device-token.json"

# Steps 1 & 2 (cache-hit / silent-refresh) in python; exit 3 signals "need full device flow".
set +e
OKTA_DOMAIN="$OKTA_DOMAIN" \
OKTA_DEVICE_CLIENT_ID="$OKTA_DEVICE_CLIENT_ID" \
OKTA_DEVICE_SCOPES="${OKTA_DEVICE_SCOPES:-openid profile offline_access}" \
CACHE="$CACHE" \
uv run --with requests --python 3.12 - <<'PY'
import base64, json, os, sys, time
import requests

domain    = os.environ["OKTA_DOMAIN"]
client_id = os.environ["OKTA_DEVICE_CLIENT_ID"]
scopes    = os.environ["OKTA_DEVICE_SCOPES"]
cache     = os.environ["CACHE"]
token_ep  = f"https://{domain}/oauth2/default/v1/token"

def claims(jwt):
    p = jwt.split(".")[1]; p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))

try:
    with open(cache) as f:
        tok = json.load(f)
except (OSError, ValueError):
    sys.exit(3)   # no usable cache → full device flow

# 1. Still valid (>60s of life left)? Use it as-is.
at = tok.get("access_token")
if at:
    try:
        if claims(at).get("exp", 0) - 60 > time.time():
            print(at)
            sys.exit(0)
    except Exception:
        pass

# 2. Expired but refreshable? Refresh silently.
rt = tok.get("refresh_token")
if rt:
    r = requests.post(token_ep, data={
        "grant_type": "refresh_token", "refresh_token": rt,
        "client_id": client_id, "scope": scopes,
    })
    if r.status_code == 200:
        new = r.json()
        tok.update(new)                      # keep prior refresh_token if Okta didn't rotate it
        with open(cache, "w") as f:
            json.dump(tok, f)
        print(f"↻ refreshed Okta token silently", file=sys.stderr)
        print(new["access_token"])
        sys.exit(0)
    print(f"refresh rejected ({r.status_code}) — falling back to device flow", file=sys.stderr)

sys.exit(3)   # need full device flow
PY
rc=$?
set -e

# 3. Fall back to the interactive device flow (also prints the token to stdout).
if [ "$rc" -eq 3 ]; then
  exec bash "$HELPER_DIR/okta-device-login.sh"
fi
exit "$rc"
