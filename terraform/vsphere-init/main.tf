data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_content_library" "solomog" {
  name            = "solomog"
  description     = "solomog vsphere:* provisioner templates (managed by vsphere:init)"
  storage_backing = [data.vsphere_datastore.ds.id]
}

# The clone source for every vsphere:create node VM. file_url accepts either a URL
# (vCenter downloads it — needs egress from vCenter) or a local path (the provider
# uploads it), which is what VSPHERE_OVA_LOCAL_PATH switches to.
resource "vsphere_content_library_item" "ubuntu" {
  name        = "ubuntu-24.04-cloudimg"
  description = "Ubuntu 24.04 server cloud image (pinned by UBUNTU_OVA_URL in versions.env)"
  library_id  = vsphere_content_library.solomog.id
  file_url    = var.ova_local_path != "" ? var.ova_local_path : var.ova_url
  type        = "ovf"
}

output "library_name" {
  value = vsphere_content_library.solomog.name
}

output "template_item" {
  description = "Content-library item name terraform/vsphere-k3s clones from"
  value       = vsphere_content_library_item.ubuntu.name
}
