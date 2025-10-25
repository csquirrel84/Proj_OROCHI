terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.69"
    }
  }
}

provider "proxmox" {
  endpoint = "https://100.113.120.55:8006/"
  username = "root@pam"
  password = var.proxmox_password
  insecure = true
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

resource "proxmox_virtual_environment_vm" "vyos_router" {
  name        = "vyos-router"
  node_name   = "Homelab"
  
  cpu {
    cores = 2
  }
  
  memory {
    dedicated = 2048
  }
  
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi0"
    size         = 10
  }
  
  cdrom {
    enabled   = true
    file_id   = "local:iso/vyos-1.5-rolling-202510251612-generic-amd64.iso"
  }
  
  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }
  
network_device {
  bridge = "vmbr2"
  model  = "virtio"
}

  on_boot = true
  started = true
}

output "vm_id" {
  value = proxmox_virtual_environment_vm.vyos_router.vm_id
}