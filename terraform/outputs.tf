##############################################################################
# outputs.tf — resumo do que foi provisionado.
#
# Consulte depois do apply com:
#   terraform output vms
#   terraform output -json vms | jq
##############################################################################

output "vms" {
  description = "Resumo de cada VM provisionada: id, status, discos, placas e IPs."
  value = {
    for name, vm in module.vm : name => {
      id       = vm.vm_id
      status   = vm.vm_status
      template = vm.template_id_used
      disks    = vm.disk_ids
      nics     = vm.nic_ids
      started  = vm.started
      ipv4     = vm.ipv4_addresses
      firmware = vm.firmware_intent
    }
  }
}

output "vm_ids" {
  description = "Mapa simples nome -> UUID, prático para scripts e para o Ansible."
  value       = { for name, vm in module.vm : name => vm.vm_id }
}

output "ansible_inventory_hint" {
  description = <<-EOT
    Lembrete: depois do apply, configure o sistema operacional das VMs com
    Ansible. Os IPs só aparecem em `ipv4` quando a VM foi criada com
    start = true, wait_for_ip = true e tem o qemu-guest-agent instalado.
  EOT
  value       = "terraform output -json vms | jq -r 'to_entries[] | \"\\(.key) \\(.value.ipv4 | join(\",\"))\"'"
}
