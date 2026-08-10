# All values are injected as TF_VARs by scripts/vsphere-create.sh (from .env /
# versions.env / the IP allocator). Benign defaults exist only so `tofu destroy`
# (vsphere-delete.sh) can run without reconstructing every create-time input.

variable "cluster" {
  description = "solomog cluster name (also the workspace name)"
  type        = string
}

variable "server_ip" {
  description = "Static IP of the k3s server node (from the solomog IP allocator)"
  type        = string
  default     = ""
}

variable "agent_ips" {
  description = "Static IPs of the k3s agent nodes, in order (agent count = list length)"
  type        = list(string)
  default     = []
}

variable "cpus" {
  description = "vCPUs per node (VSPHERE_NODE_CPUS)"
  type        = number
  default     = 4
}

variable "memory_gb" {
  description = "Memory GB per node (VSPHERE_NODE_MEM_GB)"
  type        = number
  default     = 8
}

variable "disk_gb" {
  description = "Disk GB per node (VSPHERE_NODE_DISK_GB); must be >= the OVA disk"
  type        = number
  default     = 40
}

variable "datacenter" {
  type    = string
  default = ""
}

variable "compute_cluster" {
  type    = string
  default = ""
}

variable "datastore" {
  type    = string
  default = ""
}

variable "network" {
  description = "Portgroup the node VMs attach to (VSPHERE_NETWORK)"
  type        = string
  default     = ""
}

variable "net_gateway" {
  type    = string
  default = ""
}

variable "net_dns" {
  type    = string
  default = ""
}

variable "net_prefix" {
  description = "Subnet prefix length, e.g. 24"
  type        = number
  default     = 24
}

variable "ssh_pubkey" {
  description = "SSH public key CONTENT for the 'solomog' user (kubeconfig retrieval)"
  type        = string
  default     = ""
}

variable "k3s_version" {
  description = "Exact k3s tag (INSTALL_K3S_VERSION); empty = installer 'stable' channel"
  type        = string
  default     = ""
}
