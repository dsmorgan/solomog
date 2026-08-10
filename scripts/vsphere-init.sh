#!/usr/bin/env bash
set -euo pipefail
#
# One-time vSphere setup: content library + Ubuntu cloud-image template in vCenter,
# via the terraform/vsphere-init OpenTofu root (idempotent — re-running is a no-op
# apply). vsphere:create refuses to run until this has succeeded.
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env (from the .env vSphere section; preflight fails fast with guidance if missing):
#   VSPHERE_SERVER/USER/PASSWORD/DATACENTER/DATASTORE   vCenter connection + placement
#   VSPHERE_OVA_LOCAL_PATH   optional — local OVA fallback when vCenter can't fetch
#                            UBUNTU_OVA_URL (versions.env) from the internet
#
# Prereqs: OpenTofu (brew install opentofu) — lazy-checked here, NOT by setup.sh.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

vsphere_preflight "vsphere:init" conn

# ── Phase 2 (spec) implements from here: tofu -chdir=terraform/vsphere-init apply ──
{
  echo "vsphere:init — preflight OK, but the implementation lands in spec phase 2."
  echo "  (docs/specs/vsphere-provisioner.md — terraform/vsphere-init: content library + template)"
} >&2
exit 1
