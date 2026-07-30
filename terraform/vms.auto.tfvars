##############################################################################
# vms.auto.tfvars — inventário das VMs NOVAS a provisionar no OLVM.
#
# Este arquivo É VERSIONADO, e isso é intencional: a lista de VMs desejadas é
# infraestrutura como código. Quem lê o repositório precisa saber o que existe.
#
# O que NÃO entra aqui: senha e UUIDs do ambiente (cluster, storage domain,
# vNIC profile). Esses chegam por variável de ambiente TF_VAR_*, vindas de
# credentials do Jenkins:
#   TF_VAR_ovirt_password
#   TF_VAR_cluster_id
#   TF_VAR_storage_domain_id
#   TF_VAR_vnic_profile_id
#
# O sufixo `.auto.tfvars` faz o Terraform carregar o arquivo automaticamente —
# não precisa de -var-file na linha de comando.
#
# Comece vazio: `terraform plan` não cria nada até você declarar uma VM.
# Exemplos completos (com e sem template, cloud-init, disco de imagem) estão
# em terraform.tfvars.example e em docs/provisioning.md.
##############################################################################

vms = {

  # Descomente e ajuste para provisionar. Exemplo mínimo de VM em branco:
  #
  # "app-teste-01" = {
  #   cpu_sockets = 1
  #   cpu_cores   = 2
  #   cpu_threads = 1
  #   memory_gib  = 4
  #
  #   disks = [{
  #     alias     = "app-teste-01-boot"
  #     size_gib  = 40
  #     format    = "cow"
  #     bootable  = true
  #     interface = "virtio_scsi"
  #   }]
  #
  #   nics  = [{ name = "nic1" }]
  #   start = false
  # }

}
