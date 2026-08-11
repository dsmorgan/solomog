# Cluster root (solomog vsphere:create): 1 k3s server + N agent VMs cloned from the
# vsphere:init template. One OpenTofu WORKSPACE per cluster (state under
# terraform.tfstate.d/, gitignored); the lock file IS committed.
# Spec: docs/specs/vsphere-provisioner.md.

terraform {
  required_version = ">= 1.6.0" # OpenTofu

  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Connection via the provider-native VSPHERE_SERVER/USER/PASSWORD/ALLOW_UNVERIFIED_SSL
# env vars (exported by scripts/vsphere-create.sh) — no credentials on disk.
provider "vsphere" {}
