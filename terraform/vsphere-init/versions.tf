# One-time homelab setup root (solomog vsphere:init): content library + Ubuntu
# cloud-image template. State is local in this directory (gitignored); the lock
# file IS committed. Spec: docs/specs/vsphere-provisioner.md.

terraform {
  required_version = ">= 1.6.0" # OpenTofu

  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.10"
    }
  }
}

# Connection comes from the VSPHERE_SERVER / VSPHERE_USER / VSPHERE_PASSWORD /
# VSPHERE_ALLOW_UNVERIFIED_SSL environment variables (exported from .env by
# scripts/vsphere-init.sh) — the provider reads them natively, so no credentials
# ever land in tfvars or state-adjacent files.
provider "vsphere" {}
