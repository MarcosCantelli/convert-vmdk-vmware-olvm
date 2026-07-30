##############################################################################
# modules/ovirt_vm/outputs.tf
##############################################################################

output "vm_id" {
  description = "UUID da VM criada."
  value       = ovirt_vm.this.id
}

output "vm_name" {
  description = "Nome da VM."
  value       = ovirt_vm.this.name
}

output "vm_status" {
  description = "Status da VM segundo o engine (down, up, image_locked...)."
  value       = ovirt_vm.this.status
}

output "template_id_used" {
  description = "Template efetivamente usado (o Blank, quando a VM é em branco)."
  value       = local.template_id
}

output "disk_ids" {
  description = "Mapa alias -> UUID de cada disco criado pelo módulo."
  value       = local.disk_ids
}

output "disk_attachment_ids" {
  description = "Mapa alias -> UUID de cada anexo disco/VM."
  value       = { for alias, a in ovirt_disk_attachment.this : alias => a.id }
}

output "nic_ids" {
  description = "Mapa nome da placa -> UUID da placa."
  value       = { for name, n in ovirt_nic.this : name => n.id }
}

output "started" {
  description = "true se o módulo gerencia o ligar/desligar desta VM."
  value       = var.start
}

output "ipv4_addresses" {
  description = <<-EOT
    Endereços IPv4 reportados pela VM. Só é preenchido com
    start = true e wait_for_ip = true (exige qemu-guest-agent na VM).
  EOT
  value       = try(flatten(data.ovirt_wait_for_ip.this[0].interfaces[*].ipv4_addresses), [])
}

output "firmware_intent" {
  description = <<-EOT
    Firmware pretendido e se ele foi realmente aplicado.
    O provider oVirt 2.2.0 não expõe bios_type: quando applied = false, o
    firmware é o que vier do template (ou o padrão do cluster).
  EOT
  value = {
    firmware  = var.firmware
    bios_type = local.bios_type
    applied   = var.firmware_apply_via_api && var.firmware != null
  }
}
