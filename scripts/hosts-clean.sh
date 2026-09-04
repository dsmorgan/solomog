#!/usr/bin/env bash
set -euo pipefail
#
# Remove solomog-stamped /etc/hosts lines for named cluster(s). Does not default
# to all clusters. Unmarked leftovers (including other *.test names) are printed,
# not deleted. Same function vind:delete / vsphere:delete call after destroy.
#
# Env:
#   CLUSTER / CLUSTERS  space-separated names (required — no default)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"
# shellcheck source=lib/hosts.sh
source "$REPO_DIR/scripts/lib/hosts.sh"

CLUSTER="${CLUSTER:-${CLUSTERS:-}}"
solomog_require_cluster_list "$CLUSTER" "hosts:clean"

RC=0
for n in $CLUSTER; do
  [ -n "$n" ] || continue
  solomog_hosts_unset_cluster "$n" || RC=1
done
exit "$RC"
