# vmbr0 was created by the Proxmox installer — import it so Terraform
# takes ownership rather than trying to create a duplicate.
# Run once: terraform apply will import then manage it going forward.

import {
  id = "${var.proxmox_node}:vmbr0"
  to = proxmox_network_linux_bridge.vmbr0
}
