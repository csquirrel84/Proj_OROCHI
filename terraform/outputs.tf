output "vm1_dockerized_id" {
  value = proxmox_virtual_environment_vm.vm1_dockerized.vm_id
}

output "vm1_ip" {
  value = var.vm1_ip
}

output "vm2_baremetal_id" {
  value = proxmox_virtual_environment_vm.vm2_baremetal.vm_id
}

output "vm2_ip" {
  value = var.vm2_ip
}

output "vm3_logstash_id" {
  value = proxmox_virtual_environment_vm.vm3_logstash.vm_id
}

output "vm3_ip" {
  value = var.vm3_ip
}

output "vm4_pfsense_id" {
  value = proxmox_virtual_environment_vm.vm4_pfsense.vm_id
}

output "internal_gateway" {
  value = var.internal_gateway_ip
}

output "kibana_url" {
  value = "https://${split("/", var.vm1_ip)[0]}:5601"
}

output "elasticsearch_url" {
  value = "https://${split("/", var.vm1_ip)[0]}:9200"
}

output "velociraptor_url" {
  value = "https://${split("/", var.vm1_ip)[0]}:8889"
}

output "thehive_url" {
  value = "http://${split("/", var.vm1_ip)[0]}:9000"
}
