# Public catalog API on the portal sub-host. Soft-skip when the gateway isn't reachable
# (no expose / no /etc/hosts yet) — resource checks live in 01-resources.sh.
PORTAL_HOST="portal.${HOST}"
if curl -skS -o /dev/null --max-time 3 "https://${PORTAL_HOST}/v1/api-products" 2>/dev/null; then
  curl --fail-with-body -skS "https://${PORTAL_HOST}/v1/api-products"
else
  echo "  (skip) portal catalog not reachable at https://${PORTAL_HOST}/v1/api-products"
  echo "         ensure: solomog expose PRODUCT=kgateway + /etc/hosts (70-hosts.sh)"
fi
