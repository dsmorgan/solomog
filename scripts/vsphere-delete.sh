#!/usr/bin/env bash
set -euo pipefail
#
# Tear down a solomog-created vSphere k3s cluster: prompt, tofu destroy the cluster's
# workspace, free its IP-pool allocations, remove the kube context, deregister from
# .solomog/contexts — the complement to vsphere-create.sh. Only state-tracked
# resources are ever destroyed (never VMs enumerated by name from vCenter).
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env:
#   CLUSTER     registered vsphere cluster name (required — no default; destructive)
#   VSPHERE_*   vCenter connection from .env (preflight lists any missing)
#
# Prereqs: OpenTofu (brew install opentofu) — lazy-checked, NOT a setup.sh prerequisite.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<name> — destructive, so no default}"

vsphere_preflight "vsphere:delete" conn

# ── Phase 3 (spec) implements from here: confirm → tofu destroy → release IPs →
#    kubectl config cleanup → solomog_deregister_context ────────────────────────
{
  echo "vsphere:delete — preflight OK, but the implementation lands in spec phase 3."
  echo "  (docs/specs/vsphere-provisioner.md — would destroy workspace '${CLUSTER}')"
} >&2
exit 1
