#!/usr/bin/env bash
set -euo pipefail
#
# Refreshes AWS credentials in .env for the Bedrock backend. AWS SSO issues SHORT-LIVED
# credentials (access key + secret + session token) that expire with the SSO session
# (<=12h), so re-run this when the bedrock backend starts returning 401/403/ExpiredToken.
#
# Like gcp:refresh, scope is deliberately small: this ONLY updates .env. Re-run your bundle
# to push the new creds into the cluster secret — the bundle owns how they become a Secret:
#     solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<name>
# That chaining works because solomog runs each task as its own `task` invocation, and
# go-task re-reads dotenv (.env) per invocation — so `apply` sees the freshly written creds.
# (A raw `task aws:refresh apply` in one process would read .env once and miss them.)
#
# Auth: assumes you've configured an SSO profile once with `aws configure sso` (session name
# default "SOlo"). If the session is expired this runs `aws sso login` (opens a browser),
# then exports the temporary creds. Override the profile with AWS_PROFILE (set it in .env so
# export-credentials targets the right one) and the session name with AWS_SSO_SESSION.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
SSO_SESSION="${AWS_SSO_SESSION:-SOlo}"

if ! command -v aws &>/dev/null; then
  echo "Error: aws CLI not found. Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Copy .env.example to .env first." >&2
  exit 1
fi

# Export creds in env format (KEY=VALUE lines). If the SSO session token is still valid the
# CLI mints fresh role creds from cache; if it's expired this returns empty and we re-login.
export_creds() { aws configure export-credentials --format env-no-export 2>/dev/null; }

echo "==> Exporting AWS credentials (aws configure export-credentials)"
CREDS="$(export_creds || true)"
if [[ -z "$CREDS" ]]; then
  echo "    no valid credentials — logging in via SSO (aws sso login)"
  echo "    (this may open a browser to authenticate)"
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws sso login --profile "$AWS_PROFILE"
  else
    aws sso login --sso-session "$SSO_SESSION"
  fi
  CREDS="$(export_creds || true)"
fi
if [[ -z "$CREDS" ]]; then
  echo "Error: could not obtain AWS credentials. Configure SSO once with:" >&2
  echo "         aws configure sso     (session name: $SSO_SESSION)" >&2
  echo "       then set AWS_PROFILE (in .env or your shell) to the profile it created." >&2
  exit 1
fi

# Pull the three values out of the env-format output. cut -f2- keeps any trailing '=' that
# base64 session tokens carry. head -n1 guards against an unexpected duplicate line.
get() { printf '%s\n' "$CREDS" | grep "^$1=" | head -n1 | cut -d= -f2-; }
AKID="$(get AWS_ACCESS_KEY_ID)"
SECRET="$(get AWS_SECRET_ACCESS_KEY)"
TOKEN="$(get AWS_SESSION_TOKEN)"
if [[ -z "$AKID" || -z "$SECRET" ]]; then
  echo "Error: export-credentials returned no access key / secret." >&2
  exit 1
fi
# Long-term creds have no session token; the bundle still works without one, so warn + allow.
[[ -z "$TOKEN" ]] && echo "    note: no session token (long-term creds?) — writing empty AWS_SESSION_TOKEN"

# Rewrite .env: drop the three AWS_* lines, append the fresh values. Filter-and-append (not
# sed s///) so values with /,+,= can't break the rewrite; atomic swap via a 0600 temp file
# on the same filesystem. Order/format mirror gcp-refresh.sh.
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
chmod 600 "$TMP"
grep -vE '^(AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN)=' "$ENV_FILE" > "$TMP" || true
{
  printf 'AWS_ACCESS_KEY_ID=%s\n'     "$AKID"
  printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$SECRET"
  printf 'AWS_SESSION_TOKEN=%s\n'     "$TOKEN"
} >> "$TMP"
mv "$TMP" "$ENV_FILE"

# Confirm without leaking secrets (access-key prefix + token length only).
echo "✓ AWS creds updated in .env  (AWS_ACCESS_KEY_ID=${AKID:0:4}…, session token ${#TOKEN} chars)"
echo "  Push them to the cluster by re-running your bundle, e.g.:"
echo "    solomog aws:refresh apply BUNDLE=llmroute-bedrock CLUSTER=<name>"
echo "  SSO creds are short-lived (<=12h) — re-run this when a Bedrock route starts returning 401/403."
