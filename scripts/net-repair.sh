#!/usr/bin/env bash
set -euo pipefail
#
# Re-apply the ephemeral Docker Desktop VM routing that a reboot wipes. The mesh itself — clusters,
# Istio, east-west gateways, cacerts, and the expose/link config — all survive a restart (they live
# inside the vclusters); only this host-level routing is lost, silently disconnecting the mesh.
#
# No stored state: the Docker bridges derive from the cluster names you pass, and the topology is
# auto-detected from the live clusters (an istio-eastwest gateway ⇒ gateway/multi-network, else
# flat). So recovery is just `solomog net:repair CLUSTERS="..."`, not a full task re-run.
#
# Usage: net-repair.sh <cluster> <cluster> [<cluster> ...]

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTERS=("$@")
[[ ${#CLUSTERS[@]} -ge 2 ]] || { echo "Usage: net-repair.sh <cluster> <cluster> [...]  (set CLUSTERS=)" >&2; exit 1; }

mode="flat"
if kubectl --context "vcluster-docker_${CLUSTERS[0]}" -n istio-gateways \
     get gateway istio-eastwest >/dev/null 2>&1; then
  mode="gateway"
fi
echo "==> Detected ${mode} topology from live clusters — re-applying inter-bridge routing"
exec bash "$REPO_DIR/scripts/networking.sh" "$mode" "${CLUSTERS[@]}"
