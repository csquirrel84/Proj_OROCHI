# Alternative using BPG provider (more stable)
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.60"
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
  description = "Password for Proxmox user"
  type        = string
  sensitive   = true
}

variable "vm_name" {
  description = "Name of the VM"
  type        = string
  default     = "ubuntu-server"
}

resource "proxmox_virtual_environment_vm" "ubuntu_server" {
  name      = var.vm_name
  node_name = "Homelab"
  
  clone {
    vm_id = 9003  # Ubuntu 25.04 Template ID
  }
  
  cpu {
    cores = 2
  }
  
  memory {
    dedicated = 2048
  }
  
  disk {
    datastore_id = "vms"
    interface    = "scsi0"
    size         = 20
  }
  
  network_device {
    bridge = "vmbr0"
  }
  
  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    
    user_account {
      username = "root"
      password = "A1ohamora*"
    }
  }
}

output "vm_ipv4_address" {
  value = length(proxmox_virtual_environment_vm.ubuntu_server.ipv4_addresses) > 1 ? (
    length(proxmox_virtual_environment_vm.ubuntu_server.ipv4_addresses[1]) > 0 ? 
    proxmox_virtual_environment_vm.ubuntu_server.ipv4_addresses[1][0] : 
    "No IP assigned yet"
  ) : "No network interface found"
}