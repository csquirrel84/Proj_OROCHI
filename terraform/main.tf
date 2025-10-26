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

resource "proxmox_virtual_environment_vm" "ubuntu_router" {
  name      = "ubuntu-router"
  node_name = "Homelab"
  
  clone {
    vm_id = 9000
  }
  
  cpu {
    cores = 2
  }
  
  memory {
    dedicated = 2048
  }
  
  initialization {
    ip_config {
      ipv4 {
        address = "192.168.0.200/24"
        gateway = "192.168.0.1"
      }
    }
    
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
  
  on_boot = true
  started = true
}

variable "ssh_public_key" {
  description = "SSH public key"
  type        = string
}

output "vm_id" {
  value = proxmox_virtual_environment_vm.ubuntu_router.vm_id
}