#!/usr/bin/env bash
# Cluster-target resolution — lets solomog operate on either a local vind cluster or an
# existing EXTERNAL kube context (e.g. EKS), without the vcluster-docker_ assumption.
#
# Model (the minimal override): the CONTEXT env var.
#   - CONTEXT set   → used VERBATIM as the kube context; the target is EXTERNAL. solomog
#                     only installs onto it — it never creates/tears down/networks it, and
#                     teardown can't touch it (vind-teardown only targets clusters that
#                     vind-create recorded in .solomog/clusters, which an external one isn't).
#   - CONTEXT unset → vind default context "vcluster-docker_<cluster>" (unchanged behavior).
#
# Usage:
#   source "$REPO_DIR/scripts/lib/target.sh"
#   CTX="$(solomog_context "$CLUSTER")"
#   if solomog_is_external; then ...skip vind-only steps... fi

# Echo the kube context for a cluster name (honors the CONTEXT override).
solomog_context() {   # args: <cluster>
  if [ -n "${CONTEXT:-}" ]; then
    printf '%s' "$CONTEXT"
  else
    printf 'vcluster-docker_%s' "$1"
  fi
}

# Return 0 (true) when the target is an external (non-vind) context.
solomog_is_external() {
  [ -n "${CONTEXT:-}" ]
}
