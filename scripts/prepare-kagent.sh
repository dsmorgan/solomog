#!/usr/bin/env bash
set -euo pipefail
#
# Validates kagent's selected LLM provider and prepares the two secrets required
# by the Solo Enterprise chart. Called by stack.sh immediately before Helm sync.
#
# Usage: prepare-kagent.sh <kube-context>
# Env:
#   EDITION                    enterprise (default) | community
#   KAGENT_PROVIDER            openAI (default) | anthropic | ollama
#   OPENAI_API_KEY             required for openAI
#   CLAUDE_API_KEY             required for anthropic
#   KAGENT_AUTOAUTH            true → force bundled auto-IdP for this run,
#                              ignoring persistent SOLO_UI_OIDC_* (CLI-only)
#   KAGENT_OIDC_ISSUER         controller issuer; defaults to SOLO_UI_OIDC_ISSUER,
#                              then the management chart's bundled auto-IdP
#   KAGENT_OIDC_CLIENT_ID      external-IdP client ID (default kagent-enterprise)
#   KAGENT_OIDC_CLIENT_SECRET  external-IdP secret; can be omitted when the
#                              kagent-enterprise-oidc-secret already exists

CONTEXT="${1:?Usage: prepare-kagent.sh <kube-context>}"
EDITION="${EDITION:-enterprise}"
PROVIDER="${KAGENT_PROVIDER:-openAI}"
AUTOAUTH="${KAGENT_AUTOAUTH:-false}"

case "$AUTOAUTH" in
  true|false) ;;
  *)
    echo "Error: KAGENT_AUTOAUTH must be true or false (got '$AUTOAUTH')." >&2
    exit 1
    ;;
esac

case "$PROVIDER" in
  openAI)
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
      echo "Error: KAGENT_PROVIDER=openAI requires OPENAI_API_KEY." >&2
      echo "       Set it in .env, or select KAGENT_PROVIDER=anthropic|ollama." >&2
      exit 1
    fi
    ;;
  anthropic)
    if [[ -z "${CLAUDE_API_KEY:-}" ]]; then
      echo "Error: KAGENT_PROVIDER=anthropic requires CLAUDE_API_KEY." >&2
      echo "       Set it in .env, or select KAGENT_PROVIDER=openAI|ollama." >&2
      exit 1
    fi
    ;;
  ollama)
    ;;
  *)
    echo "Error: unsupported KAGENT_PROVIDER='$PROVIDER'." >&2
    echo "       Choose: openAI | anthropic | ollama" >&2
    exit 1
    ;;
esac

[[ "$EDITION" == "enterprise" ]] || exit 0

if [[ -z "${KAGENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}" ]]; then
  echo "Warning: no KAGENT_LICENSE_KEY / SOLO_LICENSE_KEY set — Enterprise" >&2
  echo "         kagent will likely fail licensing. Set one in .env." >&2
fi

OIDC_SECRET=kagent-enterprise-oidc-secret
if [[ "$AUTOAUTH" == "true" ]]; then
  OIDC_ISSUER=""
else
  OIDC_ISSUER="${KAGENT_OIDC_ISSUER:-${SOLO_UI_OIDC_ISSUER:-}}"
fi
OIDC_CLIENT_ID="${KAGENT_OIDC_CLIENT_ID:-kagent-enterprise}"
OIDC_CLIENT_SECRET="${KAGENT_OIDC_CLIENT_SECRET:-}"

# External authentication must be configured in both charts. Validate all
# environment-only requirements before touching the cluster.
if [[ -n "$OIDC_ISSUER" ]]; then
  if [[ "$AUTOAUTH" != "true" && -n "${KAGENT_OIDC_ISSUER:-}" && -z "${SOLO_UI_OIDC_ISSUER:-}" ]]; then
    echo "Error: external kagent OIDC must also configure SOLO_UI_OIDC_ISSUER." >&2
    echo "       Enterprise authentication is configured in both the management" >&2
    echo "       and kagent-enterprise charts." >&2
    exit 1
  fi
  if [[ -n "${SOLO_UI_OIDC_ISSUER:-}" ]]; then
    for required_var in \
      SOLO_UI_OIDC_BACKEND_CLIENT_ID \
      SOLO_UI_OIDC_BACKEND_CLIENT_SECRET \
      SOLO_UI_OIDC_FRONTEND_CLIENT_ID; do
      eval "required_value=\${${required_var}:-}"
      if [[ -z "$required_value" ]]; then
        echo "Error: SOLO_UI_OIDC_ISSUER requires $required_var." >&2
        exit 1
      fi
    done
  fi
  if [[ -z "$OIDC_CLIENT_ID" ]]; then
    echo "Error: external kagent OIDC requires KAGENT_OIDC_CLIENT_ID." >&2
    exit 1
  fi
fi

# The management chart bundles cluster-scoped CRDs, so a second Helm release is
# unsupported. Solomog's canonical owner is agentgateway-system/management.
management_releases="$(
  helm list --kube-context "$CONTEXT" -A -o json 2>/dev/null \
    | jq -r '.[] | select(.chart | startswith("management-")) | "\(.namespace)/\(.name)"' \
    || true
)"
if [[ -n "$management_releases" && "$management_releases" != "agentgateway-system/management" ]]; then
  echo "Error: found a management chart outside solomog's singleton release:" >&2
  printf '       %s\n' "$management_releases" >&2
  echo "       Move/upgrade it to agentgateway-system/management before installing kagent;" >&2
  echo "       a second management release causes CRD ownership conflicts." >&2
  exit 1
fi

kubectl --context "$CONTEXT" create namespace kagent \
  --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f - >/dev/null

# The controller uses this key to sign credentials for agent actions. Preserve
# an existing key across repeat syncs; only generate on the first install.
if ! kubectl --context "$CONTEXT" get secret jwt -n kagent >/dev/null 2>&1; then
  jwt_file="$(mktemp "${TMPDIR:-/tmp}/solomog-kagent-jwt.XXXXXX")"
  trap 'rm -f "$jwt_file"' EXIT
  chmod 600 "$jwt_file"
  openssl genrsa -out "$jwt_file" 2048 >/dev/null 2>&1
  kubectl --context "$CONTEXT" create secret generic jwt \
    -n kagent \
    --from-file=jwt="$jwt_file" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f - >/dev/null
  echo "==> Created kagent JWT signing secret"
fi

oidc_secret_exists=false
kubectl --context "$CONTEXT" get secret "$OIDC_SECRET" -n kagent >/dev/null 2>&1 \
  && oidc_secret_exists=true

if [[ -n "$OIDC_ISSUER" ]]; then
  if [[ -z "$OIDC_CLIENT_SECRET" ]] && ! $oidc_secret_exists; then
    echo "Error: external kagent OIDC requires KAGENT_OIDC_CLIENT_SECRET" >&2
    echo "       or an existing secret kagent/$OIDC_SECRET." >&2
    exit 1
  fi
else
  # The management chart's bundled auto-IdP uses this fixed demo credential.
  OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-autoauth-default}"
fi

# Apply when a value was supplied (including the auto-IdP first-install value).
# Otherwise preserve an externally managed existing Secret.
if [[ -n "$OIDC_CLIENT_SECRET" ]]; then
  kubectl --context "$CONTEXT" create secret generic "$OIDC_SECRET" \
    -n kagent \
    --from-literal="clientSecret=$OIDC_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f - >/dev/null
  echo "==> Prepared kagent OIDC client secret"
fi
