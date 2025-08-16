provider "proxmox" {
    pm_api_url = "https://192.168.0.171:8006/api2/json"
    pm_user    = "root@pam"
    pm_password = "Mhall1fwwas*"
}   

resource "proxmox_vm_qemu" "ubuntu_25_04" {
  name        = "ubuntu-25-04"
  target_node = "your_proxmox_node"
  os_type     = "linux"
  os_variant  = "ubuntu25_04"
  memory      = 4096
  vcpus       = 2
  scsihw      = "virtio-scsi-pci"
  bootdisk    = "scsi0"

  disk {
    slot = 0
    size = "200G"
    type = "scsi"
    storage = "local-lvm"
    iothread = true
  }

  network {
    model = "virtio"
    bridge = "vmbr0"
  }

  cloudinit = true
  cloudinit_config = <<EOF
#cloud-config
hostname: ubuntu-25-04
fqdn: ubuntu-25-04.your_domain.com
users:
  - name: your_username
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... your_email@example.com
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
package_upgrade: true
packages:
  - git
  - ansible
  - terraform
  - docker.io
  - docker-compose
  - python3-pip
  - curl
  - wget
  - unzip
  - zip
  - vim
  - tmux
  - htop
  - net-tools
  - iputils-ping
  - dnsutils
  - ufw
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release
  - software-properties-common
  - hashicorp-archive-keyring
  - hashicorp-archive-keyring.gpg
  - hashicorp.list
  - hashicorp.list.d
  - hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
  - hashicorp.list.d/hashicorp.list.d/hashicorp.list
EOF
}