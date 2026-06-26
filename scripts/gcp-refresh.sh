#!/usr/bin/env bash
set -euo pipefail
#
# Refreshes the GCP access token in .env (GCP_ACCESS_TOKEN). gcloud's access tokens are
# short-lived (~1h), so re-run this when a GCP-backed backend (e.g. the vertexai provider)
# starts returning 401.
#
# Scope is deliberately small: this ONLY updates .env. Re-run your bundle to push the new
# token into the cluster secret — the bundle owns how the token becomes a Secret:
#     solomog gcp:refresh apply BUNDLE=<your-vertex-bundle> CLUSTER=<name>
# That chaining works because solomog runs each task as its own `task` invocation, and
# go-task re-reads dotenv (.env) per invocation — so `apply` sees the freshly written
# token. (A raw `task gcp:refresh apply` in one process would read .env once and miss it.)
#
# The value is a general GCP identity token (gcloud auth print-access-token), usable for
# any GCP API the active account can reach — not Vertex-specific, hence GCP_ACCESS_TOKEN.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

if ! command -v gcloud &>/dev/null; then
  echo "Error: gcloud not found. Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Copy .env.example to .env first." >&2
  exit 1
fi

echo "==> Fetching a fresh GCP access token (gcloud auth print-access-token)"
echo "    (this may open a browser to re-authenticate)"
TOKEN="$(gcloud auth print-access-token)"
if [[ -z "$TOKEN" ]]; then
  echo "Error: gcloud returned an empty token." >&2
  exit 1
fi

# Rewrite .env: drop any existing GCP_ACCESS_TOKEN line, append the fresh one. Filter-and-
# append (not sed s///) so the token value can't break the rewrite; atomic swap via a temp
# file next to .env (same filesystem). mktemp makes it 0600; keep it that way for a secret.
TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
chmod 600 "$TMP"
grep -v '^GCP_ACCESS_TOKEN=' "$ENV_FILE" > "$TMP" || true
printf 'GCP_ACCESS_TOKEN=%s\n' "$TOKEN" >> "$TMP"
mv "$TMP" "$ENV_FILE"

# Confirm without leaking the token (prefix + length only).
echo "✓ GCP_ACCESS_TOKEN updated in .env  (${TOKEN:0:6}…, ${#TOKEN} chars)"
echo "  Push it to the cluster by re-running your bundle, e.g.:"
echo "    solomog gcp:refresh apply BUNDLE=<vertex-bundle> CLUSTER=<name>"
echo "  Token is short-lived (~1h) — for hands-off refresh: /loop 50m solomog gcp:refresh"
