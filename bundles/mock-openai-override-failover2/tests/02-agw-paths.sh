# Diagnostic (no traffic): list the URL paths the agw gateway actually serves — every
# HTTPRoute attached to the gateway, each path match, and the backend behind it. Useful as a
# "what's reachable on this cluster" map, and to confirm this bundle's /llmfailover2 is wired.
# Scans ALL namespaces, so it shows routes from other bundles too. Informational: fails only
# if the gateway has no routes at all. Uses $CONTEXT / $HOST / $GATEWAY + jq.
NS="${GATEWAY_NS:-agentgateway-system}"
GW="${GATEWAY:-agw}"

# Each row is host \t path \t route \t backends. A route may set its own .spec.hostnames
# (e.g. the UI at ui.<gw>.<cluster>.test, added by route-host.sh); a route with none is served
# on the gateway's base host ($HOST), so we fall back to it INSIDE jq. Every column is kept
# non-empty (placeholders below) — tab is an IFS-whitespace char, so an empty field would be
# collapsed by `read` and shift the columns.
rows="$(kubectl --context "$CONTEXT" get httproute -A -o json | jq -r --arg gw "$GW" --arg basehost "$HOST" '
  .items[]
  | select(any(.spec.parentRefs[]?; .name == $gw))
  | . as $r
  | .spec.rules[]?
  | (((.matches // []) | map(.path.value // "/")) as $p
     | (if ($p | length) == 0 then ["(catch-all)"] else $p end)[]) as $path
  | ((.backendRefs // []) | if length == 0 then "(no backend)" else (map(.name) | join(",")) end) as $backends
  | (($r.spec.hostnames // []) | if length == 0 then [$basehost] else . end)[] as $host
  | [ $host, $path, ($r.metadata.namespace + "/" + $r.metadata.name), $backends ]
  | @tsv' | LC_ALL=C sort)"

if [ -z "$rows" ]; then
  echo "  ✗ no HTTPRoutes attached to gateway '$GW' (namespace scan across all namespaces)"; exit 1
fi

echo "  URL paths served by gateway '$GW':"
printf '%s\n' "$rows" | while IFS=$(printf '\t') read -r host path route backends; do
  echo "    https://${host}${path}   ← ${route}  →  ${backends}"
done
echo "  ✓ listed agw routes"
