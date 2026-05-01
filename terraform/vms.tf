# ─── Ubuntu 24.04 cloud image ─────────────────────────────────────────────────
#
# OFFLINE NOTE: This resource pulls the image from the internet. During the
# on-site deployment phase, skip this resource and set ubuntu_cloud_image_id
# in your tfvars to an image that was pre-uploaded during the office prep phase
# (e.g. local:iso/ubuntu-24.04-cloud-amd64.img).

resource "proxmox_download_file" "ubuntu_2404" {
  node_name    = var.proxmox_node
  content_type = "iso"
  datastore_id = var.iso_datastore
  file_name    = "ubuntu-24.04-cloud-amd64.img"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  overwrite    = false
}

locals {
  ubuntu_image_id = proxmox_download_file.ubuntu_2404.id
  vm_tags         = compact([var.case_reference, "orochi"])
  vm_user         = "orochi"
}

# ─── VM1 — Orochi-Dockerized ──────────────────────────────────────────────────
# Hosts: Elasticsearch, Kibana, Fleet Server, TheHive4, Velociraptor,
#        CyberChef, Mattermost, Nginx portal
# Network: vmbr99 (internal only — analysts reach it via PfSense LAN routing)

resource "proxmox_virtual_environment_vm" "vm1_dockerized" {
  node_name = var.proxmox_node
  name      = "orochi-dockerized"
  vm_id     = 101
  tags      = local.vm_tags
  on_boot   = true

  cpu {
    cores = var.vm1_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.vm1_memory_mb
  }

  disk {
    datastore_id = var.vm_datastore
    file_id      = local.ubuntu_image_id
    interface    = "virtio0"
    size         = var.vm1_disk_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr99.name
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = var.vm1_ip
        gateway = var.internal_gateway_ip
      }
    }

    user_account {
      username = local.vm_user
      password = var.common_password
      keys     = [var.ssh_public_key]
    }
  }

  boot_order = ["virtio0"]
}

# ─── VM2 — Orochi-BareMetal ───────────────────────────────────────────────────
# Hosts: Arkime (capture + viewer), Zeek, Suricata, RITA
# Network: vmbr99 (management) + vmbr2 (capture — promiscuous, no IP)
#
# The vmbr2 NIC intentionally has no IP — it receives mirrored/TAP traffic
# in promiscuous mode for passive capture. Only attached when USB NIC exists.

resource "proxmox_virtual_environment_vm" "vm2_baremetal" {
  node_name = var.proxmox_node
  name      = "orochi-baremetal"
  vm_id     = 102
  tags      = local.vm_tags
  on_boot   = true

  cpu {
    cores = var.vm2_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.vm2_memory_mb
  }

  disk {
    datastore_id = var.vm_datastore
    file_id      = local.ubuntu_image_id
    interface    = "virtio0"
    size         = var.vm2_disk_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr99.name
    model  = "virtio"
  }

  dynamic "network_device" {
    for_each = var.has_capture_nic ? [1] : []
    content {
      bridge    = proxmox_network_linux_bridge.vmbr2[0].name
      model     = "virtio"
      firewall  = false
    }
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = var.vm2_ip
        gateway = var.internal_gateway_ip
      }
    }

    user_account {
      username = local.vm_user
      password = var.common_password
      keys     = [var.ssh_public_key]
    }
  }

  boot_order = ["virtio0"]
}

# ─── VM3 — Orochi-Logstash ────────────────────────────────────────────────────
# Hosts: Logstash — receives Elastic Agent callbacks from PfSense ETH1 (vmbr1),
#        processes and forwards to Elasticsearch on VM1 (vmbr99).
# Network: vmbr99 only — PfSense NATs/routes ETH1 Elastic Agent traffic to VM3.

resource "proxmox_virtual_environment_vm" "vm3_logstash" {
  node_name = var.proxmox_node
  name      = "orochi-logstash"
  vm_id     = 103
  tags      = local.vm_tags
  on_boot   = true

  cpu {
    cores = var.vm3_cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.vm3_memory_mb
  }

  disk {
    datastore_id = var.vm_datastore
    file_id      = local.ubuntu_image_id
    interface    = "virtio0"
    size         = var.vm3_disk_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr99.name
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = var.vm3_ip
        gateway = var.internal_gateway_ip
      }
    }

    user_account {
      username = local.vm_user
      password = var.common_password
      keys     = [var.ssh_public_key]
    }
  }

  boot_order = ["virtio0"]
}

# ─── VM4 — PfSense ────────────────────────────────────────────────────────────
# Central gatekeeper: firewall, routing, WireGuard VPN.
# 5 NICs — one per bridge:
#   virtio0 → vmbr0   LAN          (analyst access)
#   virtio1 → vmbr1   ETH1         (target network — Elastic Agent callbacks in only)
#   virtio2 → vmbr2   ETH2         (capture — passive, conditional on USB NIC)
#   virtio3 → vmbr3   ETH3 BOO     (WireGuard — NAT'd to WiFi by Proxmox host)
#   virtio4 → vmbr99  SERVERS      (internal — gateway for VM1/VM2/VM3)
#
# PfSense does NOT use cloud-init — it boots from ISO and is configured
# via the PfSense REST API by the Ansible pfsense collection post-boot.
# The internal (vmbr99) interface gets IP var.internal_gateway_ip/24.

resource "proxmox_virtual_environment_vm" "vm4_pfsense" {
  node_name = var.proxmox_node
  name      = "orochi-pfsense"
  vm_id     = 104
  tags      = local.vm_tags
  on_boot   = true

  cpu {
    cores = var.pfsense_cpu_cores
    type  = "host" # PfSense benefits from host CPU passthrough for crypto
  }

  memory {
    dedicated = var.pfsense_memory_mb
  }

  cdrom {
    file_id   = var.pfsense_iso_file_id != "" ? var.pfsense_iso_file_id : "none"
    interface = "ide2"
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    size         = var.pfsense_disk_gb
    file_format  = "raw"
    discard      = "on"
  }

  # NIC order matters — PfSense assigns em0/vtnet0 in slot order.
  # Assign interfaces in the PfSense wizard in the same order as listed here.

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr0.name
    model  = "virtio"
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr1.name
    model  = "virtio"
  }

  dynamic "network_device" {
    for_each = var.has_capture_nic ? [1] : []
    content {
      bridge = proxmox_network_linux_bridge.vmbr2[0].name
      model  = "virtio"
    }
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr3.name
    model  = "virtio"
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr99.name
    model  = "virtio"
  }

  operating_system {
    type = "other"
  }

  boot_order = ["virtio0", "ide2"]
}
