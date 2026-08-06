# httpbin via the api sub-host (URLRewrite /httpbin → /). Soft-skip if unreachable.
API_HOST="api.${HOST}"
if curl -skS -o /dev/null --max-time 3 "https://${API_HOST}/httpbin/get" 2>/dev/null; then
  curl --fail-with-body -skS "https://${API_HOST}/httpbin/get"
else
  echo "  (skip) httpbin not reachable at https://${API_HOST}/httpbin/get"
  echo "         ensure: solomog expose PRODUCT=kgateway + /etc/hosts (70-hosts.sh)"
fi
