#!/usr/bin/env bash
set -euo pipefail
# Pin portal.<HOST> and api.<HOST> in /etc/hosts to the kgateway Gateway LB IP.
# expose's wildcard cert already covers *.HOST; /etc/hosts has no wildcards, so each
# sub-host needs its own line. Soft-skip when the Gateway is missing / has no address
# (re-run after `solomog expose PRODUCT=kgateway`, or let expose backfill on re-run).

GW_NS=kgateway-system
PORTAL_HOST="portal.${HOST}"
API_HOST="api.${HOST}"

if ! kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$GW_NS" >/dev/null 2>&1; then
  echo "    NOTE: Gateway '${GATEWAY}' not found in ${GW_NS} — skip /etc/hosts."
  echo "          Run: solomog expose PRODUCT=kgateway CLUSTER=${CLUSTER}"
  exit 0
fi

LB_IP="$(kubectl --context "$CONTEXT" get gateway "$GATEWAY" -n "$GW_NS" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
if [[ -z "$LB_IP" ]]; then
  echo "    NOTE: Gateway '${GATEWAY}' has no address yet — skip /etc/hosts."
  echo "          Re-run this bundle (or solomog expose) after the LB is ready."
  exit 0
fi

echo "==> Updating /etc/hosts (sudo): ${PORTAL_HOST} + ${API_HOST} → ${LB_IP}"
# Via the shared lib (SOLOMOG_LIB is exported to hooks by apply-bundle.sh), NOT a local
# sed+tee -a pair: solomog's ONE privileged command is `tee /etc/hosts`, which is what
# `solomog setup:sudo` grants passwordless — a hook-local variant would prompt. It also
# replaces stale lines instead of stacking them (first match wins in the resolver).
# shellcheck source=../../scripts/lib/hosts.sh
source "${SOLOMOG_LIB:?SOLOMOG_LIB not set - run this hook via solomog apply BUNDLE=portal-httpbin}/hosts.sh"
for h in "$PORTAL_HOST" "$API_HOST"; do
  solomog_hosts_set "$h" "$LB_IP"
done

echo "    https://${PORTAL_HOST}/"
echo "    https://${API_HOST}/httpbin/get"
