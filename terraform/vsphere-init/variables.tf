variable "datacenter" {
  description = "vSphere datacenter name (VSPHERE_DATACENTER)"
  type        = string
}

variable "datastore" {
  description = "Datastore backing the content library (VSPHERE_DATASTORE)"
  type        = string
}

variable "ova_url" {
  description = "Ubuntu cloud-image OVA URL vCenter fetches (UBUNTU_OVA_URL, versions.env)"
  type        = string
}

variable "ova_local_path" {
  description = "Optional local OVA path uploaded instead, for vCenters without internet egress (VSPHERE_OVA_LOCAL_PATH)"
  type        = string
  default     = ""
}
