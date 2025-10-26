variable "esxi_password" {
  description = "ESXi root password"
  type        = string
  sensitive   = true
}

variable "esxi_ip" {
  description = "ESXi host IP address"
  type        = string
}
