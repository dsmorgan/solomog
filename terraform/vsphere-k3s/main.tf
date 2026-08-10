data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cc" {
  name          = var.compute_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_content_library" "solomog" {
  name = "solomog"
}

data "vsphere_content_library_item" "ubuntu" {
  name       = "ubuntu-24.04-cloudimg"
  type       = "ovf"
  library_id = data.vsphere_content_library.solomog.id
}

# Shared cluster join token, held only in this workspace's state.
resource "random_password" "k3s_token" {
  length  = 40
  special = false
}

locals {
  # cloud-init reaches the VMs via the VMware guestinfo datasource (metadata carries
  # the static network config). No vApp properties are set on the clone, so the OVF
  # datasource stays inactive and guestinfo wins — the spec's primary path; the
  # fallback (OVF vApp user-data) is a bring-up switch if precedence misbehaves.
  guestinfo = {
    server = {
      hostname = "solomog-${var.cluster}-server"
      ip       = var.server_ip
      userdata = templatefile("${path.module}/templates/userdata-server.yaml.tftpl", {
        hostname    = "solomog-${var.cluster}-server"
        ssh_pubkey  = var.ssh_pubkey
        k3s_version = var.k3s_version
        k3s_token   = random_password.k3s_token.result
        server_ip   = var.server_ip
      })
    }
  }
}

resource "vsphere_virtual_machine" "server" {
  name             = "solomog-${var.cluster}-server"
  resource_pool_id = data.vsphere_compute_cluster.cc.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = var.cpus
  memory   = var.memory_gb * 1024
  guest_id = "ubuntu64Guest"

  # Static IPs + our own SSH readiness polling — don't block on VMware Tools
  # reporting a routable address.
  wait_for_guest_net_timeout = 0

  network_interface {
    network_id = data.vsphere_network.net.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_gb
    thin_provisioned = true
  }

  clone {
    template_uuid = data.vsphere_content_library_item.ubuntu.id
  }

  extra_config = {
    "guestinfo.metadata" = base64gzip(templatefile("${path.module}/templates/metadata.yaml.tftpl", {
      hostname = local.guestinfo.server.hostname
      ip       = var.server_ip
      prefix   = var.net_prefix
      gateway  = var.net_gateway
      dns      = var.net_dns
    }))
    "guestinfo.metadata.encoding" = "gzip+base64"
    "guestinfo.userdata"          = base64gzip(local.guestinfo.server.userdata)
    "guestinfo.userdata.encoding" = "gzip+base64"
  }
}

resource "vsphere_virtual_machine" "agents" {
  count = length(var.agent_ips)

  name             = "solomog-${var.cluster}-agent-${count.index + 1}"
  resource_pool_id = data.vsphere_compute_cluster.cc.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = var.cpus
  memory   = var.memory_gb * 1024
  guest_id = "ubuntu64Guest"

  wait_for_guest_net_timeout = 0

  network_interface {
    network_id = data.vsphere_network.net.id
  }

  disk {
    label            = "disk0"
    size             = var.disk_gb
    thin_provisioned = true
  }

  clone {
    template_uuid = data.vsphere_content_library_item.ubuntu.id
  }

  extra_config = {
    "guestinfo.metadata" = base64gzip(templatefile("${path.module}/templates/metadata.yaml.tftpl", {
      hostname = "solomog-${var.cluster}-agent-${count.index + 1}"
      ip       = var.agent_ips[count.index]
      prefix   = var.net_prefix
      gateway  = var.net_gateway
      dns      = var.net_dns
    }))
    "guestinfo.metadata.encoding" = "gzip+base64"
    "guestinfo.userdata" = base64gzip(templatefile("${path.module}/templates/userdata-agent.yaml.tftpl", {
      hostname    = "solomog-${var.cluster}-agent-${count.index + 1}"
      ssh_pubkey  = var.ssh_pubkey
      k3s_version = var.k3s_version
      k3s_token   = random_password.k3s_token.result
      server_ip   = var.server_ip
    }))
    "guestinfo.userdata.encoding" = "gzip+base64"
  }

  # Agents join via the server's API — make sure it exists first.
  depends_on = [vsphere_virtual_machine.server]
}

output "server_ip" {
  value = var.server_ip
}

output "agent_ips" {
  value = var.agent_ips
}

output "node_names" {
  value = concat(
    [vsphere_virtual_machine.server.name],
    vsphere_virtual_machine.agents[*].name,
  )
}
