#!/usr/bin/env bash
# Control: the objects exist and attached. Run first -- everything below reads as a product
# finding only if this passes, otherwise it is an environment problem.
set -euo pipefail
NS=agentgateway-system
fail=0

for r in exchange-http-route exchange-mcp-route; do
  if kubectl --context "$CONTEXT" get httproute "$r" -n "$NS" >/dev/null 2>&1; then
    echo "  ✓ route $r"
  else
    echo "  ✗ route $r missing — apply the bundle to this cluster" >&2; fail=1
  fi
done

for p in exchange-http-policy exchange-mcp-policy exchange-access-log; do
  st="$(kubectl --context "$CONTEXT" get enterpriseagentgatewaypolicy "$p" -n "$NS" \
        -o jsonpath='{.status.ancestors[*].conditions[*].status}' 2>/dev/null || true)"
  case "$st" in
    *True*) echo "  ✓ policy $p attached" ;;
    "")     echo "  ✗ policy $p missing" >&2; fail=1 ;;
    *)      echo "  ✗ policy $p not attached (conditions: $st)" >&2
            echo "    A rejected policy usually means a schema mismatch: backend.auth.oauthTokenExchange" >&2
            echo "    exists from 2026.7.x; older builds want backend.tokenExchange.oauth." >&2; fail=1 ;;
  esac
done

if kubectl --context "$CONTEXT" get secret exchange-client-secret -n "$NS" >/dev/null 2>&1; then
  echo "  ✓ exchange client secret present"
else
  echo "  ✗ secret exchange-client-secret missing — the Keycloak hook did not complete" >&2; fail=1
fi

command -v agctl >/dev/null && echo "  ✓ agctl present" \
  || echo "  ! agctl not installed — tests 40/50 will self-skip"

[ "$fail" = 0 ] || exit 1
echo "✓ preflight"
