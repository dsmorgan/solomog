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
for h in "$PORTAL_HOST" "$API_HOST"; do
  # macOS sed -i ''; Linux falls through || true then we still append (dedupe best-effort).
  sudo sed -i '' "/[[:space:]]${h}\$/d;/[[:space:]]${h}[[:space:]]/d" /etc/hosts 2>/dev/null || \
    sudo sed -i "/[[:space:]]${h}\$/d;/[[:space:]]${h}[[:space:]]/d" /etc/hosts 2>/dev/null || true
  echo "${LB_IP} ${h}" | sudo tee -a /etc/hosts >/dev/null
done

echo "    https://${PORTAL_HOST}/"
echo "    https://${API_HOST}/httpbin/get"
