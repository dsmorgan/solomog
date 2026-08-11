#!/usr/bin/env bash
set -euo pipefail
#
# One-time vSphere setup: content library ("solomog") + Ubuntu cloud-image template
# in vCenter, via the terraform/vsphere-init OpenTofu root. Idempotent — re-running
# is a no-op apply; bumping UBUNTU_OVA_URL in versions.env and re-running replaces
# the template. vsphere:create refuses to run until this has succeeded (it checks
# this root's state for a managed resource — see vsphere_require_init).
# Spec: docs/specs/vsphere-provisioner.md.
#
# Env (preflight fails fast with guidance if missing):
#   VSPHERE_SERVER/USER/PASSWORD          vCenter connection — read natively by the
#                                         provider from these exact env var names
#   VSPHERE_ALLOW_UNVERIFIED_SSL          "true" for self-signed vCenter certs
#   VSPHERE_DATACENTER/DATASTORE          library placement (TF_VARs)
#   UBUNTU_OVA_URL                        pinned in versions.env
#   VSPHERE_OVA_LOCAL_PATH                optional local-OVA fallback (uploaded by the
#                                         provider) when vCenter has no internet egress
#
# Prereqs: OpenTofu (brew install opentofu) — lazy-checked, NOT a setup.sh prerequisite.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/vsphere.sh
source "$REPO_DIR/scripts/lib/vsphere.sh"

vsphere_preflight "vsphere:init" conn

TOFU="${VSPHERE_TOFU_BIN:-tofu}"
ROOT="$REPO_DIR/terraform/vsphere-init"

: "${UBUNTU_OVA_URL:?UBUNTU_OVA_URL missing — pinned in versions.env}"

# Provider connection: the vsphere provider reads VSPHERE_SERVER/USER/PASSWORD/
# ALLOW_UNVERIFIED_SSL straight from the environment (already exported via dotenv).
# Everything else goes in as TF_VARs — no tfvars files, nothing credential-shaped on disk.
export VSPHERE_SERVER VSPHERE_USER VSPHERE_PASSWORD
export VSPHERE_ALLOW_UNVERIFIED_SSL="${VSPHERE_ALLOW_UNVERIFIED_SSL:-false}"
export TF_VAR_datacenter="$VSPHERE_DATACENTER"
export TF_VAR_datastore="$VSPHERE_DATASTORE"
export TF_VAR_ova_url="$UBUNTU_OVA_URL"
export TF_VAR_ova_local_path="${VSPHERE_OVA_LOCAL_PATH:-}"

echo "==> vsphere:init — content library + Ubuntu template on ${VSPHERE_SERVER}"
if [ -n "${VSPHERE_OVA_LOCAL_PATH:-}" ]; then
  echo "    template source: local OVA ${VSPHERE_OVA_LOCAL_PATH} (uploaded)"
else
  echo "    template source: ${UBUNTU_OVA_URL} (vCenter fetches it — needs egress;"
  echo "    no egress? set VSPHERE_OVA_LOCAL_PATH to a downloaded OVA instead)"
fi

"$TOFU" -chdir="$ROOT" init -input=false >/dev/null
"$TOFU" -chdir="$ROOT" apply -input=false -auto-approve

echo ""
echo "✓ vSphere one-time init complete — template '$("$TOFU" -chdir="$ROOT" output -raw template_item)'"
echo "  Next:  solomog vsphere:create CLUSTER=<name>"
