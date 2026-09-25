# Ship the workload sources (src/) into the cluster as ConfigMaps, so the Python stays in real,
# lintable files. apply-bundle.sh globs files only, so src/ is never applied as manifests.
#
# The pods read their code at start, so a source edit needs a restart; harmless on first apply.
# CONTEXT is exported by apply-bundle.sh; cwd is the bundle directory.
set -euo pipefail

NS=agent-evidence
echo "==> workload source ConfigMaps in namespace ${NS}"

for pair in evidence-resource-as-src:resource_as.py claims-mcp-src:claims_mcp.py evidence-agent-src:agent.py; do
  cm=${pair%%:*}; file=${pair#*:}
  kubectl --context "$CONTEXT" create configmap "$cm" -n "$NS" \
    --from-file="${file}=src/${file}" \
    --dry-run=client -o yaml | kubectl --context "$CONTEXT" apply -f -
done

# evidence-resource-as is restarted by 16-resource-as-config.sh instead, AFTER its config is rebuilt:
# restarting it here would pick up the previous apply's config (envFrom is read at pod start).
kubectl --context "$CONTEXT" -n "$NS" rollout restart \
  deploy/claims-mcp deploy/priorauth-agent deploy/intake-agent 2>/dev/null || true

echo "✓ applied evidence-resource-as-src + claims-mcp-src + evidence-agent-src"
