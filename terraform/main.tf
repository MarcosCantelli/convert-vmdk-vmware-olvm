##############################################################################
# main.tf — provisionamento das VMs novas no OLVM.
#
# Toda VM declarada em var.vms (terraform.tfvars) passa pelo mesmo módulo.
# Adicionar uma VM = adicionar uma entrada no mapa; nada de copiar recurso.
#
# `for_each` (e não `count`) de propósito: a chave é o NOME da VM, então
# remover uma VM do meio do mapa não faz o Terraform recriar as outras.
##############################################################################

module "vm" {
  source = "./modules/ovirt_vm"

  for_each = var.vms

  # A chave do mapa é o nome da VM.
  name = each.key

  cluster_id        = var.cluster_id
  storage_domain_id = var.storage_domain_id

  # Template: presente = VM a partir de template; ausente = VM em branco.
  template_id = each.value.template_id
  clone       = each.value.clone

  cpu_sockets = each.value.cpu_sockets
  cpu_cores   = each.value.cpu_cores
  cpu_threads = each.value.cpu_threads
  memory_gib  = each.value.memory_gib

  vm_type = each.value.vm_type
  os_type = each.value.os_type
  comment = each.value.comment

  disks = each.value.disks
  nics  = each.value.nics

  # Perfil de vNIC padrão para as placas que não informarem um.
  default_vnic_profile_id = var.vnic_profile_id

  start       = each.value.start
  wait_for_ip = each.value.wait_for_ip

  cloud_init_hostname = each.value.cloud_init_hostname
  cloud_init_script   = each.value.cloud_init_script

  # ---------------------------------------------------------------------
  # Firmware: o provider não expõe bios_type, então o padrão é NÃO tentar
  # aplicar (o firmware vem do template). Para habilitar o ajuste via API
  # REST, passe firmware/firmware_apply_via_api aqui e credenciais do engine.
  # Veja a explicação completa em modules/ovirt_vm/variables.tf.
  # ---------------------------------------------------------------------
  # firmware               = "uefi"
  # firmware_apply_via_api = true
  engine_url          = var.ovirt_url
  engine_username     = var.ovirt_username
  engine_password     = var.ovirt_password
  engine_tls_insecure = var.ovirt_tls_insecure
}
