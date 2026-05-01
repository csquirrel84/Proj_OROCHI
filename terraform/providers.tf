terraform {
  required_version = ">= 1.7"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.73"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # Proxmox uses a self-signed cert by default

  ssh {
    agent    = false
    username = var.proxmox_ssh_user
    password = var.proxmox_ssh_password
  }
}
