#!/usr/bin/env bash
# Cheap control: environment only. If this fails, a failure in test 10 says nothing about
# WebSocket proxying.
set -uo pipefail
K="kubectl --context ${CONTEXT}"
fail=0

echo "== mock server =="
if $K rollout status deploy/mock-realtime -n realtime-mock --timeout=120s >/dev/null 2>&1; then
  echo "   ✓ mock-realtime ready"
else
  echo "   ✗ mock-realtime not ready: $K logs -n realtime-mock deploy/mock-realtime"; fail=1
fi

echo "== gateway =="
# Read the version from what is RUNNING, not from one Deployment template. After a helm upgrade
# the controller moves first and the proxy Deployment rolls afterwards, so a template read
# straight after `solomog agentgateway` can still show the old tag, and the old tag looks like
# the install did not take. Wait for the rollout, then report controller and proxy separately.
if ! $K rollout status deploy/"${GATEWAY}" -n agentgateway-system --timeout=120s >/dev/null 2>&1; then
  echo "   ✗ deploy/${GATEWAY} not rolled out in agentgateway-system (still mid-upgrade?)"; fail=1
fi
img_tag() { sed 's/.*://; s/@.*//'; }
for d in $($K get deploy -n agentgateway-system -o name 2>/dev/null); do
  img=$($K get "$d" -n agentgateway-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  case "$img" in
    *agentgateway*) [ "${d#*/}" = "${GATEWAY}" ] || echo "   controller/other  ${d#*/}: $(printf '%s' "$img" | img_tag)" ;;
  esac
done
tmpl=$($K get deploy -n agentgateway-system "${GATEWAY}" \
       -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | img_tag)
run=$($K get pods -n agentgateway-system -l "gateway.networking.k8s.io/gateway-name=${GATEWAY}" \
       -o jsonpath='{range .items[*]}{.status.containerStatuses[0].image}{"\n"}{end}' 2>/dev/null | img_tag | sort -u | tr '\n' ' ')
echo "   proxy ${GATEWAY}: deployment template=${tmpl:-<not found>}  running pods=${run:-<none>}"
[ -n "$tmpl" ] || { echo "   ✗ no ${GATEWAY} deployment in agentgateway-system"; fail=1; }
case " $run" in
  *" $tmpl "*) [ "$(printf '%s' "$run" | wc -w)" -le 1 ] || echo "   ! more than one proxy version is running (mid-rollout)" ;;
  *) echo "   ! running pods differ from the template tag: the proxy is not on the version you pinned yet" ;;
esac

echo "== route + backend policy =="
st=$($K get httproute openai-realtime -n agentgateway-system \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$st" = "True" ] && echo "   ✓ httproute Accepted=True" || { echo "   ✗ httproute Accepted=${st:-<missing>}"; fail=1; }
st=$($K get enterpriseagentgatewaypolicy openai-realtime-auth -n agentgateway-system \
      -o jsonpath='{range .status.ancestors[*]}{range .conditions[*]}{.type}={.status} {end}{end}' 2>/dev/null)
case "$st" in
  *Accepted=True*) echo "   ✓ policy: $st" ;;
  *) echo "   ✗ policy: ${st:-<no status>}"; fail=1 ;;
esac
echo "   (Accepted=True validates nothing about the route type — test 10 does that.)"
exit $fail
