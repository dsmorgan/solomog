#!/usr/bin/env bash
# Cheap control. Everything here is environment, not product behaviour: if this fails, a failure
# in tests 30-60 says nothing about rate limiting.
set -uo pipefail
. "$(dirname "$0")/../helpers/lib-mcp.sh"
mcp_require_host || exit 1
K="kubectl --context ${CONTEXT}"
fail=0

echo "== gateway version =="
ver=$($K get deploy -n agentgateway-system agw -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
echo "   agentgateway: ${ver:-<not found>}"
case "$ver" in
  2026.7.*) echo "   ✓ on the 2026.7.x LTS line (the line this bundle is written against)" ;;
  "")       echo "   ✗ no agw deployment in agentgateway-system"; fail=1 ;;
  *)        echo "   ! NOT the 2026.7.x LTS line. Denial shape may differ -- see docs/findings.md" ;;
esac

echo "== workloads =="
# WAIT rather than sample once. `solomog apply` returns as soon as the objects are accepted, so a
# test started straight afterwards races two slow starters: mcp-server pulls from npm, and the
# shipped rate limiter takes a while to report ready. Sampling once turns that race into a
# spurious failure -- which is exactly what a control test must not produce.
#
# The enterprise rate limiter is included because arm C FAILS CLOSED against it (see below), so
# an unready limiter takes the /mcp-ent route down with HTTP 500.
for d in mcp-rl/mcp-server \
         agentgateway-system/mcp-ratelimit \
         agentgateway-system/mcp-redis \
         agentgateway-system/rate-limiter-enterprise-agentgateway; do
  ns=${d%%/*}; name=${d##*/}
  if $K rollout status deploy/"$name" -n "$ns" --timeout=180s >/dev/null 2>&1; then
    echo "   ✓ ${d} ready"
  else
    echo "   ✗ ${d} never became ready within 180s"
    echo "     mcp-server runs npx at start; check: $K logs -n ${ns} deploy/${name}"
    fail=1
  fi
done

echo "== policies accepted and attached =="
# Accepted only means the CR parsed. It is a necessary condition, never a sufficient one --
# every enforcement claim in this bundle is made by sending traffic, not by reading status.
for p in mcp-local-ratelimit mcp-pertool-ratelimit mcp-ent-ratelimit; do
  st=$($K get enterpriseagentgatewaypolicy -n agentgateway-system "$p" \
        -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status} {end}{end}' 2>/dev/null)
  case "$st" in
    *"Accepted=True"*"Attached=True"*) echo "   ✓ ${p}: ${st}" ;;
    "") echo "   ✗ ${p}: no status (does the object exist?)"; fail=1 ;;
    *)  echo "   ✗ ${p}: ${st}"; fail=1 ;;
  esac
done

echo "== MCP reachable through each route =="
# Retry briefly. /mcp-ent answers HTTP 500 "rate limit failed" until the enterprise rate limiter
# is serving: entRateLimit has NO failureMode field on this line, so it is fail-closed and not
# configurable -- unlike arm B, which sets failureMode: FailOpen explicitly.
for path in /mcp-local /mcp-pertool /mcp-ent; do
  sid=""
  for attempt in 1 2 3 4 5 6; do
    sid=$(mcp_init "$path" 2>/dev/null)
    [ -n "$sid" ] && break
    sleep 5
  done
  if [ -n "$sid" ]; then
    echo "   ✓ ${path} handshake ok"
  else
    echo "   ✗ ${path} handshake failed after 6 attempts"
    [ "$path" = "/mcp-ent" ] && echo "     HTTP 500 'rate limit failed' here means the enterprise rate limiter is not serving."
    fail=1
  fi
done

[ $fail -eq 0 ] && echo "PASS preflight" || echo "FAIL preflight"
exit $fail
