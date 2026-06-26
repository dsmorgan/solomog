#!/usr/bin/env bash
# Optional LOCAL pre-flight (not customer-portable): the gateway routes are programmed,
# without spending LLM tokens. Most tests are just portable curls (see 10-/20-); this one
# is kubectl, so it needs a little shell logic to assert — that's fine, the runner judges
# pass/fail by exit code either way.
set -euo pipefail

fail=0
for r in claude openai; do
  status="$(kubectl --context "$CONTEXT" get httproute "$r" -n agentgateway-system \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  echo "  httproute/$r  Accepted=${status:-<missing>}"
  [ "$status" = "True" ] || fail=1
done
exit $fail
