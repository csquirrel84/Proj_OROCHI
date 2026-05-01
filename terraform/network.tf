# ─── Virtual bridges ──────────────────────────────────────────────────────────
#
# Physical NIC mapping (from OROCHI_CONTEXT):
#   nic0  88:ae:dd:0f:d9:0e  → vmbr0  Analyst LAN / PfSense LAN
#   nic1  98:e7:43:22:5b:91  → vmbr1  Target network / PfSense ETH1
#   USB NIC (TBD)            → vmbr2  Capture network / PfSense ETH2
#   wlo1  (WiFi)             → vmbr3  BOO/WireGuard — see note below
#   (none)                   → vmbr99 Internal VM-to-VM only
#
# vmbr3 note: WiFi cannot be bridged in standard 802.11 infrastructure mode.
# vmbr3 is defined as a portless bridge. The Proxmox host must apply an
# iptables MASQUERADE rule (handled by Ansible) to NAT traffic from vmbr3
# out via wlo1. PfSense treats vmbr3 as its WAN-side BOO interface with a
# static RFC1918 address; the Proxmox host at .254 acts as the default route.

resource "proxmox_network_linux_bridge" "vmbr0" {
  node_name = var.proxmox_node
  name      = "vmbr0"
  ports     = ["nic0"] # MAC 88:ae:dd:0f:d9:0e — already bridged by Proxmox installer
  comment   = "Analyst LAN — physical switch → PfSense LAN"
}

resource "proxmox_network_linux_bridge" "vmbr1" {
  node_name = var.proxmox_node
  name      = "vmbr1"
  ports     = ["nic1"] # MAC 98:e7:43:22:5b:91
  comment   = "Target network — PfSense ETH1 (Elastic Agent callbacks only)"
}

resource "proxmox_network_linux_bridge" "vmbr2" {
  count     = var.has_capture_nic ? 1 : 0
  node_name = var.proxmox_node
  name      = "vmbr2"
  ports     = ["enx000000000000"] # Replace with actual USB NIC interface name once procured
  comment   = "Capture network — TAP feeds → VM2 passive capture"
}

resource "proxmox_network_linux_bridge" "vmbr3" {
  node_name = var.proxmox_node
  name      = "vmbr3"
  comment   = "BOO/WireGuard — portless bridge, NAT'd to wlo1 by Proxmox host (see Ansible)"
}

resource "proxmox_network_linux_bridge" "vmbr99" {
  node_name = var.proxmox_node
  name      = "vmbr99"
  comment   = "Internal VM-to-VM only — no physical NIC"
}
