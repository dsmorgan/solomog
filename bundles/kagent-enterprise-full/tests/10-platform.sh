#!/usr/bin/env bash
# Every workload this bundle installs is Ready, and Substrate is in native certificate mode.
# The cheap control: a failure here is an install problem, not a product one.
. "$(dirname "$0")/../helpers/checks.sh"

for ns in "$PODCERT_NS" "$SUBSTRATE_NS" "$PG_NS" "$MOCK_NS" "$KAGENT_NS"; do
  bad="$(k get deploy,statefulset -n "$ns" -o json 2>/dev/null | jq -r '.items[]
    | select((.status.readyReplicas // 0) < (.spec.replicas // 1)) | "\(.kind)/\(.metadata.name)"')"
  n="$(k get deploy,statefulset -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then no "${ns}: no workloads"
  elif [ -z "$bad" ]; then ok "${ns}: ${n} workloads Ready"
  else no "${ns}: not Ready: $(echo $bad)"; fi
done

for w in deploy/kagent-controller deploy/kagent-ui deploy/kmcp-enterprise-controller-manager \
         deploy/solo-enterprise-k8sobjects statefulset/solo-enterprise-telemetry-collector \
         statefulset/kagent-clickhouse-shard0; do
  k -n "$KAGENT_NS" get "$w" >/dev/null 2>&1 && ok "${KAGENT_NS}/${w} present" || no "${KAGENT_NS}/${w} missing"
done

# The controller's bundled IdP is a sidecar named idp; it renders only with no external issuer.
k -n "$KAGENT_NS" get deploy kagent-controller -o json | jq -e '.spec.template.spec.containers[] | select(.name == "idp")' >/dev/null \
  && ok "controller runs the bundled IdP sidecar" || no "no idp sidecar on the controller (is enterprise.oidc.issuer set?)"

# Native mode: no ate-ca-agent sidecar anywhere, and the controller mounts a projected podCertificate.
if k get pods -A -o json | jq -e '[.items[].spec.containers[].name] | index("ate-ca-agent")' >/dev/null; then
  no "an ate-ca-agent sidecar is running: something is in ate-ca compatibility mode"
else
  ok "no ate-ca-agent sidecars (native certificate mode)"
fi
k -n "$KAGENT_NS" get deploy kagent-controller -o json \
  | jq -e '[.spec.template.spec.volumes[]?.projected.sources[]? | select(.podCertificate)] | length > 0' >/dev/null \
  && ok "controller mounts a projected podCertificate" || no "controller has no podCertificate projection"

wp="$(k get workerpool.ate.dev "$POOL" -n "$KAGENT_NS" -o json 2>/dev/null)"
if [ -n "$wp" ]; then
  ok "WorkerPool ${POOL}: class $(jq -r '.spec.sandboxClass // .spec.template.sandboxClass // "?"' <<<"$wp"), $(k get pods -n "$KAGENT_NS" --no-headers 2>/dev/null | grep -c "^${POOL}") worker pod(s)"
else
  no "WorkerPool ${POOL} missing"
fi
exit "$fail"
