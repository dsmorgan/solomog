#!/usr/bin/env bash
set -euo pipefail
#
# Create a k3s cluster on the homelab vCenter (1 server + N agents, OpenTofu workspace
# per cluster), install MetalLB, and register the kube context so the rest of solomog
# works via CLUSTER=<name> — the vSphere analog of eks-create.sh.
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env:
#   CLUSTER     cluster name (required — no default; this provisions real VMs)
#   NODES       agent count                        default 2 (VMs = NODES + 1 server)
#   SNAPSHOT    "true" → snapshot VMs post-ready as "solomog-baseline" (opt-in; enables
#               vsphere:reset)                     default false
#   VSPHERE_*   connection/placement/network from .env (preflight lists any missing)
#   K3S_VERSION / METALLB_VERSION / UBUNTU_OVA_URL  pinned in versions.env
#
# Prereqs: OpenTofu (brew install opentofu), kubectl, ssh/scp. Lazy-checked — NOT
# setup.sh prerequisites. Requires `solomog vsphere:init` to have run once.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
: "${CLUSTER:?set CLUSTER=<name> — this provisions real VMs on vCenter, so no default}"
NODES="${NODES:-2}"

vsphere_preflight "vsphere:create" full
vsphere_require_init "vsphere:create"

# ── Phase 3 (spec) implements from here: alloc IPs → tofu apply → kubeconfig →
#    MetalLB → optional snapshot → solomog_register_context ─────────────────────
{
  echo "vsphere:create — preflight OK, but the implementation lands in spec phase 3."
  echo "  (docs/specs/vsphere-provisioner.md — terraform/vsphere-k3s workspace '${CLUSTER}',"
  echo "   ${NODES} agent(s) + 1 server)"
} >&2
exit 1
