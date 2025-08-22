# VyOS Cloud-Init Image Builder and Router Deployment
# Copy this entire content into terraform/vyos/main.tf

terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.1"
    }
  }
}

# Provider configuration for Proxmox
provider "proxmox" {
  pm_api_url      = "https://100.113.120.55:8006/api2/json"
  pm_user         = var.proxmox_user
  pm_password     = var.proxmox_password
  pm_tls_insecure = true
}

# Variables
variable "proxmox_user" {
  description = "Proxmox username"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "Homelab"
}

variable "vyos_iso_file" {
  description = "VyOS ISO filename"
  type        = string
  default     = "vyos-2025.08.18-0022-rolling-generic-amd64.iso"
}

variable "vm_storage" {
  description = "Storage for VM disk"
  type        = string
  default     = "local"
}

# Network bridges
variable "wan_bridge" {
  description = "Bridge for WAN interface (physical)"
  type        = string
  default     = "vmbr0"
}

variable "lan_bridge" {
  description = "Bridge for LAN interface"
  type        = string
  default     = "vmbr1"
}

variable "internal_bridge" {
  description = "Bridge for Internal network"
  type        = string
  default     = "vmbr2"
}

variable "mirror_bridge" {
  description = "Bridge for Mirror port"
  type        = string
  default     = "vmbr3"
}

variable "ssh_public_key" {
  description = "SSH public key for vyos user"
  type        = string
  default     = ""
}

# Step 1: Create VyOS Installation Preseed File
resource "local_file" "vyos_preseed" {
  filename = "vyos-preseed.conf"
  content  = <<-EOT
    # VyOS Installation Preseed Configuration
    # This automates the VyOS installation process
    
    # Partitioning
    d-i partman-auto/method string regular
    d-i partman-auto/disk string /dev/vda
    d-i partman-auto/choose_recipe select atomic
    d-i partman-partitioning/confirm_write_new_label boolean true
    d-i partman/choose_partition select finish
    d-i partman/confirm boolean true
    d-i partman/confirm_nooverwrite boolean true
    
    # Root password (will be changed via cloud-init)
    d-i passwd/root-password password vyos123
    d-i passwd/root-password-again password vyos123
    
    # Packages
    d-i pkgsel/include string cloud-init qemu-guest-agent
    
    # Boot loader
    d-i grub-installer/only_debian boolean true
    d-i grub-installer/with_other_os boolean true
    d-i grub-installer/bootdev string /dev/vda
    
    # Finish installation
    d-i finish-install/reboot_in_progress note
  EOT
}

# Step 2: Create Cloud-Init User Data for VyOS
resource "local_file" "vyos_cloud_init_user_data" {
  filename = "user-data"
  content  = <<-EOT
#cloud-config
vyos_config_commands:
  # System configuration
  - set system host-name 'vyos-router'
  - set system time-zone 'UTC'
  - set system ntp server 'time.nist.gov'
  
  # Interface configuration
  # ETH0 - WAN (DHCP)
  - set interfaces ethernet eth0 description 'WAN'
  - set interfaces ethernet eth0 address dhcp
  
  # ETH1 - LAN (Monitored Network)
  - set interfaces ethernet eth1 description 'LAN-Monitored'
  - set interfaces ethernet eth1 address '172.168.58.254/24'
  
  # ETH2 - Internal Network
  - set interfaces ethernet eth2 description 'Internal-Network'
  - set interfaces ethernet eth2 address '172.168.0.254/24'
  
  # ETH3 - Mirror Port
  - set interfaces ethernet eth3 description 'Mirror-Port'
  # Mirror port typically doesn't need an IP for packet capture
  
  # DHCP Server for LAN Network
  - set service dhcp-server shared-network-name LAN subnet 172.168.58.0/24 default-router '172.168.58.254'
  - set service dhcp-server shared-network-name LAN subnet 172.168.58.0/24 dns-server '8.8.8.8'
  - set service dhcp-server shared-network-name LAN subnet 172.168.58.0/24 dns-server '8.8.4.4'
  - set service dhcp-server shared-network-name LAN subnet 172.168.58.0/24 range 0 start '172.168.58.100'
  - set service dhcp-server shared-network-name LAN subnet 172.168.58.0/24 range 0 stop '172.168.58.200'
  
  # DHCP Server for Internal Network
  - set service dhcp-server shared-network-name INTERNAL subnet 172.168.0.0/24 default-router '172.168.0.254'
  - set service dhcp-server shared-network-name INTERNAL subnet 172.168.0.0/24 dns-server '8.8.8.8'
  - set service dhcp-server shared-network-name INTERNAL subnet 172.168.0.0/24 dns-server '8.8.4.4'
  - set service dhcp-server shared-network-name INTERNAL subnet 172.168.0.0/24 range 0 start '172.168.0.100'
  - set service dhcp-server shared-network-name INTERNAL subnet 172.168.0.0/24 range 0 stop '172.168.0.200'
  
  # NAT Configuration
  - set nat source rule 10 outbound-interface 'eth0'
  - set nat source rule 10 source address '172.168.58.0/24'
  - set nat source rule 10 translation address masquerade
  
  - set nat source rule 20 outbound-interface 'eth0'
  - set nat source rule 20 source address '172.168.0.0/24'
  - set nat source rule 20 translation address masquerade
  
  # Firewall rules
  - set firewall name WAN_TO_LAN default-action drop
  - set firewall name WAN_TO_LAN rule 10 action accept
  - set firewall name WAN_TO_LAN rule 10 state established enable
  - set firewall name WAN_TO_LAN rule 10 state related enable
  
  - set firewall name WAN_TO_INTERNAL default-action drop
  - set firewall name WAN_TO_INTERNAL rule 10 action accept
  - set firewall name WAN_TO_INTERNAL rule 10 state established enable
  - set firewall name WAN_TO_INTERNAL rule 10 state related enable
  
  # DNS forwarding
  - set service dns forwarding listen-address '172.168.58.254'
  - set service dns forwarding listen-address '172.168.0.254'
  - set service dns forwarding name-server '8.8.8.8'
  - set service dns forwarding name-server '8.8.4.4'
  
  # SSH Service
  - set service ssh port '22'
  - set service ssh listen-address '0.0.0.0'
  
  # Traffic mirroring for monitoring (Zeek/Arkime)
  # Mirror LAN traffic to eth3
  - set interfaces ethernet eth3 mirror eth1

users:
  - name: vyos
    gecos: VyOS Admin
    primary_group: vyos
    groups: [sudo, adm]
    shell: /bin/vbash
    lock_passwd: false
    passwd: '$6$rounds=4096$salt$3FooH7NjiWIDBSG1kxdTrjvOqjKWMrHyf6XBxiC/uDT8QzDh/8K8J6LO7YTmxC7D1ixJIlr9QJ8ufcSlFCYhD0'
    ssh_authorized_keys:
      - ${var.ssh_public_key}

package_update: true
package_upgrade: false

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  EOT
}

# Step 3: Create Cloud-Init Meta Data
resource "local_file" "vyos_cloud_init_meta_data" {
  filename = "meta-data"
  content  = <<-EOT
instance-id: vyos-router-001
local-hostname: vyos-router
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
    eth1:
      addresses:
        - 172.168.58.254/24
    eth2:
      addresses:
        - 172.168.0.254/24
  EOT
}

# Step 4: Build Cloud-Init Image Builder Script
resource "local_file" "build_vyos_image" {
  filename = "build-vyos-cloud-init.sh"
  content  = <<-EOT
#!/bin/bash
set -e

# Variables
ISO_FILE="${var.vyos_iso_file}"
OUTPUT_IMAGE="vyos-cloud-init.qcow2"
TEMP_DIR="/tmp/vyos-build-$$"
VM_NAME="vyos-builder-$$"

echo "Building VyOS Cloud-Init Image..."

# Create temporary directory
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# Copy cloud-init files
cp ../user-data .
cp ../meta-data .

# Create cloud-init ISO
echo "Creating cloud-init configuration disk..."
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data

# Create base disk image
echo "Creating base disk image..."
qemu-img create -f qcow2 "$OUTPUT_IMAGE" 20G

# Install VyOS with automation
echo "Installing VyOS (this may take 10-15 minutes)..."
qemu-system-x86_64 \
  -name "$VM_NAME" \
  -machine type=pc,accel=kvm \
  -cpu host \
  -smp 2 \
  -m 2048 \
  -drive file="$OUTPUT_IMAGE",if=virtio,cache=writeback,discard=ignore,format=qcow2 \
  -drive file="../$ISO_FILE",media=cdrom,readonly=on \
  -drive file=seed.iso,if=virtio,format=raw \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -nographic \
  -serial mon:stdio \
  -boot order=dc \
  -enable-kvm

echo "VyOS Cloud-Init image built successfully: $OUTPUT_IMAGE"

# Move image to final location
mv "$OUTPUT_IMAGE" "../$OUTPUT_IMAGE"

# Cleanup
cd ..
rm -rf "$TEMP_DIR"

echo "Image ready for upload to Proxmox!"
  EOT
  
  file_permission = "0755"
}

# Step 5: Build the Cloud-Init Image (runs locally)
resource "null_resource" "build_vyos_cloud_init_image" {
  depends_on = [
    local_file.vyos_cloud_init_user_data,
    local_file.vyos_cloud_init_meta_data,
    local_file.build_vyos_image
  ]

  provisioner "local-exec" {
    command = "./build-vyos-cloud-init.sh"
  }

  triggers = {
    user_data_content = local_file.vyos_cloud_init_user_data.content
    meta_data_content = local_file.vyos_cloud_init_meta_data.content
    build_script      = local_file.build_vyos_image.content
  }
}

# Step 6: Upload Cloud-Init Image to Proxmox
resource "null_resource" "upload_vyos_image" {
  depends_on = [null_resource.build_vyos_cloud_init_image]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Uploading VyOS cloud-init image to Proxmox..."
      scp vyos-cloud-init.qcow2 root@100.113.120.55:/var/lib/vz/images/
      
      # Create VM template on Proxmox
      ssh root@100.113.120.55 << 'SSH_EOF'
        # Create VM
        qm create 9000 --name vyos-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
        
        # Import disk
        qm importdisk 9000 /var/lib/vz/images/vyos-cloud-init.qcow2 ${var.vm_storage}
        
        # Attach disk
        qm set 9000 --scsihw virtio-scsi-pci --scsi0 ${var.vm_storage}:9000/vm-9000-disk-0.qcow2
        
        # Configure cloud-init
        qm set 9000 --ide2 ${var.vm_storage}:cloudinit
        qm set 9000 --boot c --bootdisk scsi0
        qm set 9000 --serial0 socket --vga serial0
        qm set 9000 --agent enabled=1
        
        # Convert to template
        qm template 9000
        
        echo "VyOS template created with ID 9000"
SSH_EOF
    EOT
  }

  triggers = {
    image_built = null_resource.build_vyos_cloud_init_image.id
  }
}

# Step 7: Deploy VyOS Router from Template
resource "proxmox_vm_qemu" "vyos_router" {
  depends_on = [null_resource.upload_vyos_image]
  
  name        = "vyos-router"
  target_node = var.proxmox_node
  vmid        = 101
  
  # Clone from template
  clone = "vyos-template"
  
  # VM Configuration
  memory    = 2048
  cores     = 2
  sockets   = 1
  cpu       = "host"
  
  # Main disk
  disk {
    slot     = 0
    size     = "20G"
    type     = "scsi"
    storage  = var.vm_storage
    iothread = 1
  }
  
  # Network Interfaces
  # ETH0 - WAN Interface (DHCP)
  network {
    model   = "virtio"
    bridge  = var.wan_bridge
    tag     = -1
  }
  
  # ETH1 - LAN Interface (Monitored Network)
  network {
    model   = "virtio"
    bridge  = var.lan_bridge
    tag     = -1
  }
  
  # ETH2 - Internal Network
  network {
    model   = "virtio"
    bridge  = var.internal_bridge
    tag     = -1
  }
  
  # ETH3 - Mirror Port
  network {
    model   = "virtio"
    bridge  = var.mirror_bridge
    tag     = -1
  }
  
  # Cloud-init configuration
  cloudinit_cdrom_storage = var.vm_storage
  ciuser     = "vyos"
  cipassword = "vyos123"
  sshkeys    = var.ssh_public_key
  ipconfig0  = "dhcp"
  ipconfig1  = "ip=172.168.58.254/24"
  ipconfig2  = "ip=172.168.0.254/24"
  
  # VM options
  agent    = 1
  onboot   = true
  startup  = "order=1"
  
  tags = "vyos,router,security"
}

# Outputs
output "vyos_vm_id" {
  value = proxmox_vm_qemu.vyos_router.vmid
}

output "vyos_vm_name" {
  value = proxmox_vm_qemu.vyos_router.name
}

output "vyos_lan_ip" {
  value = "172.168.58.254"
}

output "vyos_internal_ip" {
  value = "172.168.0.254"
}

output "ssh_command" {
  value = "ssh vyos@172.168.58.254"
}

# Terraform variables template
resource "local_file" "terraform_tfvars_template" {
  filename = "terraform.tfvars.example"
  content  = <<-EOT
    # Proxmox Configuration
    proxmox_user     = "root@pam"
    proxmox_password = "your_proxmox_password_here"
    proxmox_node     = "Homelab"
    
    # VyOS Configuration
    vyos_iso_file   = "vyos-2025.08.18-0022-rolling-generic-amd64.iso"
    vm_storage      = "local"
    
    # Network Bridges
    wan_bridge      = "vmbr0"
    lan_bridge      = "vmbr1" 
    internal_bridge = "vmbr2"
    mirror_bridge   = "vmbr3"
    
    # SSH Configuration (REQUIRED)
    ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ... your-key-here"
  EOT
}

# Instructions
resource "local_file" "build_instructions" {
  filename = "BUILD_INSTRUCTIONS.md"
  content  = <<-EOT
# VyOS Cloud-Init Image Build and Deployment

This Terraform configuration will:
1. Build a cloud-init enabled VyOS image from your ISO
2. Upload it to Proxmox and create a template
3. Deploy your VyOS router with full automation

## Prerequisites

1. **Required tools on your local machine**:
   ```bash
   sudo apt-get install qemu-system-x86 genisoimage
   # or on macOS:
   brew install qemu cdrtools
   ```

2. **SSH access to Proxmox**:
   - Ensure you can SSH to root@100.113.120.55
   - Set up SSH key authentication (recommended)

3. **VyOS ISO**: Make sure `${var.vyos_iso_file}` is in the current directory

## Deployment Steps

1. **Configure SSH key** (REQUIRED):
   ```bash
   # Generate SSH key if you don't have one
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/vyos_key
   
   # Copy your public key
   cat ~/.ssh/vyos_key.pub
   ```

2. **Configure variables**:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your SSH key and credentials
   ```

3. **Deploy everything**:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## What Happens During Build

1. **Image Creation**: Creates a 20GB qcow2 disk image
2. **Automated Install**: Installs VyOS with cloud-init support
3. **Template Creation**: Uploads to Proxmox and creates template (ID: 9000)
4. **Router Deployment**: Clones template and deploys configured router (ID: 101)

## Post-Deployment

1. **Access the router**:
   ```bash
   ssh vyos@172.168.58.254
   ```

2. **Verify configuration**:
   ```bash
   show interfaces
   show ip route
   show nat source rules
   ```

## Network Layout

- **WAN (eth0)**: DHCP from upstream
- **LAN (eth1)**: 172.168.58.254/24 - Monitored network
- **Internal (eth2)**: 172.168.0.254/24 - Internal devices  
- **Mirror (eth3)**: Ready for Zeek/Arkime VMs

## Troubleshooting

- Build process takes 10-15 minutes
- Ensure adequate disk space (5GB+ free)
- Check SSH connectivity to Proxmox
- Verify KVM acceleration is available

The entire process is fully automated - just run `terraform apply`!
  EOT
}