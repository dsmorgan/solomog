#!/usr/bin/env bash
# Toggle agentgateway proxy trace logging on/off by patching the RUST_LOG env on the
# `agentgateway-config` EnterpriseAgentgatewayParameters, preserving everything else in
# spec.env (STS_URI / STS_AUTH_TOKEN). The controller reconciles the params CR → regenerates
# the proxy deployment, so this triggers a short proxy rollout.
#
# ⚠️ `solomog apply BUNDLE=agw-okta-mcp` re-runs 88-snowflake-proxy-sts.sh, which REWRITES that
#    params CR and DROPS RUST_LOG. So re-run `trace.sh on` AFTER any apply.
#
# The proxy container is distroless (no shell); read logs from outside. The most useful line at
# `agentgateway=trace` is `client ... sending request` to the upstream — it shows the FULL outbound
# header set (that's how we check whether Authorization: Bearer is attached to an MCP upstream call).
#
# Usage:
#   bash bundles/agw-okta-mcp/helpers/trace.sh on  [CLUSTER] [LEVEL]
#   bash bundles/agw-okta-mcp/helpers/trace.sh off [CLUSTER]
#   bash bundles/agw-okta-mcp/helpers/trace.sh tail [CLUSTER] [GREP]   # follow proxy logs (optional grep filter)
# Defaults: CLUSTER=a8 (or $CLUSTER), LEVEL=info,agentgateway=trace,mcp=trace
set -euo pipefail

ACTION="${1:?usage: trace.sh on|off|tail [CLUSTER] [LEVEL|GREP]}"
CLUSTER="${2:-${CLUSTER:-a8}}"
CTX="vcluster-docker_${CLUSTER}"
NS="agentgateway-system"
PARAMS="agentgateway-config"
DEFAULT_LEVEL="info,agentgateway=trace,mcp=trace"

proxy_rust_log() {
  kubectl --context "$CTX" -n "$NS" get deploy agw -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((e.get('value') for c in d['spec']['template']['spec']['containers'] for e in c.get('env',[]) if e['name']=='RUST_LOG'),'__none__'))" 2>/dev/null || echo "?"
}

case "$ACTION" in
  tail)
    PROXY=$(kubectl --context "$CTX" -n "$NS" get pod -o name | grep -iE "agw-[a-z0-9]+-[a-z0-9]+$" | head -1)
    echo "==> tailing $PROXY ${3:+(grep: $3)}  — Ctrl-C to stop"
    if [ -n "${3:-}" ]; then
      kubectl --context "$CTX" -n "$NS" logs "$PROXY" -f | grep -i --line-buffered "$3"
    else
      kubectl --context "$CTX" -n "$NS" logs "$PROXY" -f
    fi
    exit 0 ;;
  on)  LEVEL="${3:-$DEFAULT_LEVEL}"; echo "==> trace ON  ($LEVEL) on $CTX" ;;
  off) LEVEL="";                     echo "==> trace OFF on $CTX" ;;
  *)   echo "usage: trace.sh on|off|tail [CLUSTER] [LEVEL|GREP]" >&2; exit 1 ;;
esac

# Build the new env list from the CURRENT params CR so STS_URI/STS_AUTH_TOKEN (and anything else)
# are preserved; only RUST_LOG is toggled.
NEWENV=$(kubectl --context "$CTX" -n "$NS" get enterpriseagentgatewayparameters "$PARAMS" -o json 2>/dev/null | \
  ACTION="$ACTION" LEVEL="$LEVEL" python3 -c "
import sys,json,os
try: d=json.load(sys.stdin)
except Exception: d={}
env=[e for e in ((d.get('spec') or {}).get('env') or []) if e.get('name')!='RUST_LOG']
if os.environ['ACTION']=='on': env.append({'name':'RUST_LOG','value':os.environ['LEVEL']})
if not any(e.get('name')=='STS_URI' for e in env):
    sys.stderr.write('WARN: STS_URI not in params env — has bundle 88 run? patching anyway.\n')
print(json.dumps(env))")

kubectl --context "$CTX" -n "$NS" patch enterpriseagentgatewayparameters "$PARAMS" \
  --type=merge -p="{\"spec\":{\"env\":$NEWENV}}" >/dev/null

echo "==> waiting for controller to reconcile params → proxy, then rollout..."
TARGET="$LEVEL"; [ "$ACTION" = off ] && TARGET="__none__"
for _ in $(seq 1 15); do
  cur=$(proxy_rust_log)
  [ "$cur" = "$TARGET" ] && { echo "   reconciled (RUST_LOG=$cur)"; break; }
  sleep 5
done
kubectl --context "$CTX" -n "$NS" rollout status deploy/agw --timeout=120s 2>&1 | tail -1
echo "✓ done."
[ "$ACTION" = on ] && echo "  tail with:  bash bundles/agw-okta-mcp/helpers/trace.sh tail $CLUSTER snowflake"
