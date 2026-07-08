#!/usr/bin/env bash
# The whole point of eager-auth: the gateway serves its OWN AS metadata, so an MCP client discovers
# the gateway (not Okta) as its OAuth provider. Fetch the authorization-server discovery doc and
# assert registration_endpoint points at the gateway's /oauth-issuer — proving the issuer-proxy
# (resourceMetadata.agentgateway.dev/issuer-proxy) + the /oauth-issuer route + KGW_OAUTH_ISSUER_CONFIG
# are all wired. This is the automatable half; the browser login to Okta is the manual MCP-Inspector step.
set -euo pipefail
doc=$(curl -sk "https://${HOST}/.well-known/oauth-authorization-server/mcp")
reg=$(printf '%s' "$doc" | jq -r '.registration_endpoint // empty')
echo "registration_endpoint: ${reg:-<none>}"
case "$reg" in
  *"${HOST}/oauth-issuer"*) echo "✓ AS metadata served by the gateway (registration_endpoint → /oauth-issuer)";;
  "") echo "no registration_endpoint in AS metadata — issuer not registered? check KGW_OAUTH_ISSUER_CONFIG + the oauth-issuer route"; echo "$doc"; exit 1;;
  *) echo "registration_endpoint points elsewhere ($reg) — issuer-proxy annotation missing? (Okta metadata is being proxied instead)"; exit 1;;
esac
