##############################################################################
# variables.tf — entradas da raiz do Terraform.
#
# Onde colocar valores:
#   * segredos            -> TF_VAR_ovirt_password (variável de ambiente)
#   * IDs do ambiente     -> terraform.tfvars (copiado do .example, gitignored)
#
# Os IDs (cluster, storage domain, vNIC profile) são UUIDs. O provider v2 NÃO
# oferece data sources para descobri-los por nome, então precisam ser
# informados. Use o script terraform/scripts/get-ovirt-ids.sh para listar.
##############################################################################

# ---------------------------------------------------------------------------
# Conexão com o engine
# ---------------------------------------------------------------------------
variable "ovirt_url" {
  description = "URL da API do engine OLVM (precisa terminar em /ovirt-engine/api/)."
  type        = string
  default     = "https://olvm.mvrc.local/ovirt-engine/api/"

  validation {
    condition     = can(regex("/ovirt-engine/api/?$", var.ovirt_url))
    error_message = "A URL precisa terminar em /ovirt-engine/api/ — não use a URL da interface web."
  }
}

variable "ovirt_username" {
  description = "Usuário da API. Com Keycloak, o formato tem dois @ (admin@ovirt@internalsso)."
  type        = string
  default     = "admin@ovirt@internalsso"
}

variable "ovirt_password" {
  description = "Senha da API. Informe via TF_VAR_ovirt_password — nunca em arquivo versionado."
  type        = string
  sensitive   = true
}

variable "ovirt_tls_insecure" {
  description = <<-EOT
    true = não verifica o certificado do engine.
    Necessário enquanto o certificado não tiver o FQDN no SAN.
    Mutuamente exclusivo com ovirt_tls_ca_files.
  EOT
  type        = bool
  default     = true
}

variable "ovirt_tls_ca_files" {
  description = "Arquivos PEM do CA do engine. Só use quando ovirt_tls_insecure = false."
  type        = list(string)
  default     = []
}

variable "ovirt_mock" {
  description = <<-EOT
    true = provider em modo simulação (tudo em memória, sem tocar no engine).
    Útil para validar a configuração sem acesso ao OLVM:
      terraform plan -var ovirt_mock=true -var ovirt_password=fake
    Nunca use em produção: o estado simulado é descartado ao fim da execução.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# IDs do ambiente (UUIDs) — descubra com scripts/get-ovirt-ids.sh
# ---------------------------------------------------------------------------
variable "cluster_id" {
  description = "UUID do cluster oVirt onde as VMs serão criadas (cluster 'Default')."
  type        = string
}

variable "storage_domain_id" {
  description = "UUID do storage domain dos discos (na fase de migração: 'hosted_storage')."
  type        = string
}

variable "vnic_profile_id" {
  description = "UUID do perfil de vNIC da rede lógica (normalmente o perfil de 'ovirtmgmt')."
  type        = string
}

# ---------------------------------------------------------------------------
# VMs a provisionar
# ---------------------------------------------------------------------------
variable "vms" {
  description = <<-EOT
    Mapa de VMs a criar. A chave é o nome da VM.

    Atributos (todos opcionais exceto onde indicado):
      template_id   UUID do template. Ausente/null = VM em branco (blank).
      clone         true = clona o template (a VM sobrevive à remoção dele)
      cpu_sockets / cpu_cores / cpu_threads
      memory_gib    memória em GiB
      vm_type       server | desktop | high_performance
      os_type       ID do SO no oVirt (VERIFIQUE os válidos no seu engine)
      comment
      disks         lista de discos a criar:
                      alias, size_gib, format ("cow"|"raw"), sparse,
                      bootable, interface, source_file (upload de imagem local)
      nics          lista de placas: name, vnic_profile_id
                    (MAC fixo não é suportado pelo provider 2.2.0)
      start         true = liga a VM depois de criar
      wait_for_ip   true = espera a VM reportar IP (exige guest agent)
      cloud_init_hostname / cloud_init_script
  EOT

  type = map(object({
    template_id = optional(string)
    clone       = optional(bool, false)

    cpu_sockets = optional(number, 1)
    cpu_cores   = optional(number, 2)
    cpu_threads = optional(number, 1)
    memory_gib  = optional(number, 4)

    vm_type = optional(string, "server")
    os_type = optional(string)
    comment = optional(string, "Provisionada via Terraform")

    disks = optional(list(object({
      alias       = string
      size_gib    = optional(number)
      format      = optional(string, "cow")
      sparse      = optional(bool, true)
      bootable    = optional(bool, false)
      interface   = optional(string, "virtio_scsi")
      source_file = optional(string)
    })), [])

    nics = optional(list(object({
      name            = string
      vnic_profile_id = optional(string)
    })), [])

    start       = optional(bool, false)
    wait_for_ip = optional(bool, false)

    cloud_init_hostname = optional(string)
    cloud_init_script   = optional(string)
  }))

  default = {}
}
