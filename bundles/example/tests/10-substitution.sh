# Variable-substitution showcase. The bundle's 10-config.yaml.tmpl rendered %%CLUSTER%% /
# %%GATEWAY%% / %%HOST%% into the demo-config ConfigMap at apply time; here we read them back
# and assert they match the SAME vars the runner exports to tests. This both demonstrates
# that tests get $CLUSTER/$GATEWAY/$HOST for substitution AND verifies the bundle templating.
set -e
get() { kubectl --context "$CONTEXT" get cm demo-config -n solomog-example -o jsonpath="{.data.$1}"; }

echo "  cluster=$(get cluster)        (expect ${CLUSTER})"
echo "  gateway=$(get gateway)        (expect ${GATEWAY})"
echo "  gateway-host=$(get gateway-host)  (expect ${HOST})"

[ "$(get cluster)" = "$CLUSTER" ]
[ "$(get gateway)" = "$GATEWAY" ]
[ "$(get gateway-host)" = "$HOST" ]
