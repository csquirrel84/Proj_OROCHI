# ─── Proxmox connection ───────────────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. Dev: Tailscale IP. Prod: https://10.16.255.254:8006"
  type        = string
  default     = "https://100.70.2.104:8006"
}

variable "proxmox_api_token" {
  description = "Proxmox API token — format: terraform@pve!terraform=<uuid>"
  type        = string
  sensitive   = true
}

variable "proxmox_ssh_user" {
  description = "SSH user on Proxmox host (bpg provider needs SSH for some operations)"
  type        = string
  default     = "root"
}

variable "proxmox_ssh_password" {
  description = "SSH password for Proxmox host"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name (shown in the web UI top-left)"
  type        = string
  default     = "pve"
}

# ─── Storage ──────────────────────────────────────────────────────────────────

variable "vm_datastore" {
  description = "Datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore" {
  description = "Datastore for ISOs and cloud images"
  type        = string
  default     = "local"
}

# ─── Engagement inputs ────────────────────────────────────────────────────────

variable "case_reference" {
  description = "Engagement case reference — used as a VM tag"
  type        = string
}

variable "common_password" {
  description = "Common password used across all services (Elasticsearch, Kibana, etc.)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key injected into all Ubuntu VMs via cloud-init"
  type        = string
}

variable "target_network_cidr" {
  description = "Target network CIDR (e.g. 192.168.1.0/24) — used to configure PfSense ETH1"
  type        = string
}

variable "wireguard_peer_pubkey" {
  description = "WireGuard public key for the remote analyst — configured on PfSense ETH3 BOO"
  type        = string
  default     = ""
}

# ─── Internal network (vmbr99) ────────────────────────────────────────────────

variable "internal_network_cidr" {
  description = "CIDR for the internal VM-to-VM network on vmbr99"
  type        = string
  default     = "10.16.254.0/24"
}

variable "internal_gateway_ip" {
  description = "PfSense IP on vmbr99 — acts as gateway for all internal VMs"
  type        = string
  default     = "10.16.254.1"
}

variable "vm1_ip" {
  description = "Static IP for VM1 (Dockerized) on vmbr99"
  type        = string
  default     = "10.16.254.10/24"
}

variable "vm2_ip" {
  description = "Static IP for VM2 (BareMetal) on vmbr99"
  type        = string
  default     = "10.16.254.20/24"
}

variable "vm3_ip" {
  description = "Static IP for VM3 (Logstash) on vmbr99"
  type        = string
  default     = "10.16.254.30/24"
}

# ─── Hardware availability ────────────────────────────────────────────────────

variable "has_capture_nic" {
  description = "Set true once the USB ethernet adapter for vmbr2 (capture network) is procured"
  type        = bool
  default     = false
}

# ─── VM1 — Orochi-Dockerized ──────────────────────────────────────────────────

variable "vm1_cpu_cores" {
  type    = number
  default = 8
}

variable "vm1_memory_mb" {
  description = "MB of RAM. Elasticsearch alone wants 8GB+ heap — don't go below 16384."
  type        = number
  default     = 24576
}

variable "vm1_disk_gb" {
  description = "GB for the OS/Docker volume (Elastic indices live here)"
  type        = number
  default     = 200
}

# ─── VM2 — Orochi-BareMetal ───────────────────────────────────────────────────

variable "vm2_cpu_cores" {
  type    = number
  default = 4
}

variable "vm2_memory_mb" {
  type    = number
  default = 8192
}

variable "vm2_disk_gb" {
  description = "GB for OS + PCAP storage (Arkime). Size generously."
  type        = number
  default     = 500
}

# ─── VM3 — Orochi-Logstash ────────────────────────────────────────────────────

variable "vm3_cpu_cores" {
  type    = number
  default = 2
}

variable "vm3_memory_mb" {
  type    = number
  default = 4096
}

variable "vm3_disk_gb" {
  type    = number
  default = 50
}

# ─── VM4 — PfSense ────────────────────────────────────────────────────────────

variable "pfsense_cpu_cores" {
  type    = number
  default = 2
}

variable "pfsense_memory_mb" {
  type    = number
  default = 2048
}

variable "pfsense_disk_gb" {
  type    = number
  default = 20
}

variable "pfsense_iso_file_id" {
  description = "File ID of the PfSense ISO on Proxmox (e.g. local:iso/pfSense-CE-2.7.2-RELEASE-amd64.iso). Must be uploaded manually — Netgate requires a form download."
  type        = string
  default     = ""
}
