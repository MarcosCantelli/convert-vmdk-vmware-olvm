##############################################################################
# modules/ovirt_vm/variables.tf — interface do módulo.
##############################################################################

# ---------------------------------------------------------------------------
# Identidade e posicionamento
# ---------------------------------------------------------------------------
variable "name" {
  description = "Nome da VM. O oVirt aceita apenas letras, números, '-', '_' e '.'."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.name))
    error_message = "O nome da VM só pode conter letras, números, ponto, hífen e underscore."
  }
}

variable "cluster_id" {
  description = "UUID do cluster oVirt."
  type        = string
}

variable "storage_domain_id" {
  description = "UUID do storage domain onde os discos deste módulo serão criados."
  type        = string
}

# ---------------------------------------------------------------------------
# Template x VM em branco
#
# O provider v2 EXIGE um template_id no recurso ovirt_vm — não existe "VM sem
# template". Para criar uma VM em branco, o próprio oVirt fornece o template
# "Blank", que o módulo busca sozinho quando template_id é null.
# ---------------------------------------------------------------------------
variable "template_id" {
  description = "UUID do template base. null = VM em branco (usa o template Blank)."
  type        = string
  default     = null
}

variable "clone" {
  description = <<-EOT
    Só faz sentido com template_id definido.
    false (padrão) = VM "linkada" ao template: mais rápida e econômica, mas o
                     template não pode ser removido enquanto a VM existir.
    true           = VM clonada: independente, ocupa espaço próprio.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Hardware
# ---------------------------------------------------------------------------
# O provider exige os TRÊS valores de CPU juntos: se um for definido, os
# outros dois também precisam ser. Por isso todos têm default.
variable "cpu_sockets" {
  description = "Quantidade de sockets."
  type        = number
  default     = 1
}

variable "cpu_cores" {
  description = "Cores por socket."
  type        = number
  default     = 2
}

variable "cpu_threads" {
  description = "Threads por core."
  type        = number
  default     = 1
}

variable "memory_gib" {
  description = "Memória em GiB. O módulo converte para bytes, que é o que o provider espera."
  type        = number
  default     = 4
}

variable "maximum_memory_gib" {
  description = "Memória máxima (hot-plug) em GiB. null = mesmo valor de memory_gib."
  type        = number
  default     = null
}

variable "vm_type" {
  description = "Tipo da VM no oVirt."
  type        = string
  default     = "server"

  validation {
    condition     = contains(["server", "desktop", "high_performance"], var.vm_type)
    error_message = "vm_type precisa ser server, desktop ou high_performance."
  }
}

variable "os_type" {
  description = <<-EOT
    ID do sistema operacional no oVirt (ex.: rhel_9x64, ubuntu_22_04, other_linux).
    ATENÇÃO: a lista de valores aceitos varia conforme a versão do engine —
    confirme no seu OLVM antes de confiar num nome. null = deixa o padrão.
  EOT
  type        = string
  default     = null
}

variable "comment" {
  description = "Comentário livre, aparece na interface do oVirt."
  type        = string
  default     = "Provisionada via Terraform"
}

# ---------------------------------------------------------------------------
# Firmware — leia com atenção
#
# O recurso ovirt_vm do provider 2.2.0 NÃO expõe firmware/bios_type. Ou seja:
# não há como escolher BIOS ou UEFI diretamente em Terraform.
#
# Caminhos possíveis:
#   1. (RECOMENDADO) o firmware vem do TEMPLATE. Mantenha um template BIOS e
#      um template UEFI, e escolha pelo template_id.
#   2. VM em branco: herda o padrão do cluster.
#   3. Ajustar depois da criação, via API REST (é o que
#      firmware_apply_via_api = true faz) ou via Ansible:
#        ansible localhost -m ovirt.ovirt.ovirt_vm \
#          -a "name=<vm> cluster=Default bios_type=q35_ovmf ..."
#
# O caminho 3 é útil, mas NÃO foi testado contra o engine — valide antes de
# usar em produção. Por isso vem desligado por padrão.
# ---------------------------------------------------------------------------
variable "firmware" {
  description = "bios | uefi. Documenta a intenção; só é APLICADO se firmware_apply_via_api = true."
  type        = string
  default     = null

  validation {
    condition     = var.firmware == null || contains(["bios", "uefi"], var.firmware)
    error_message = "firmware precisa ser \"bios\", \"uefi\" ou null."
  }
}

variable "firmware_apply_via_api" {
  description = <<-EOT
    true = depois de criar a VM, chama a API REST do engine para ajustar o
    bios_type (bios -> q35_sea_bios, uefi -> q35_ovmf), porque o provider não
    tem esse atributo. Requer `curl` na máquina que roda o Terraform e as
    variáveis engine_url / engine_username / engine_password.
    NÃO TESTADO contra o engine — desligado por padrão.
  EOT
  type        = bool
  default     = false
}

variable "engine_url" {
  description = "URL da API do engine, terminando em /ovirt-engine/api/. Usada só pelo ajuste de firmware."
  type        = string
  default     = null
}

variable "engine_username" {
  description = "Usuário da API. Usado só pelo ajuste de firmware."
  type        = string
  default     = null
}

variable "engine_password" {
  description = "Senha da API. Usada só pelo ajuste de firmware."
  type        = string
  default     = null
  sensitive   = true
}

variable "engine_tls_insecure" {
  description = "true = curl com -k (certificado sem FQDN no SAN). Usado só pelo ajuste de firmware."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Discos
# ---------------------------------------------------------------------------
variable "disks" {
  description = <<-EOT
    Discos a criar e anexar. Dois modos:

      * disco NOVO em branco  -> informe size_gib (usa o recurso ovirt_disk)
      * disco A PARTIR DE IMAGEM -> informe source_file com o caminho de um
        arquivo local (qcow2/raw); usa ovirt_disk_from_image e o tamanho vem
        da própria imagem.

    Campos:
      alias       (obrigatório) nome do disco no oVirt
      size_gib    obrigatório quando NÃO há source_file
      format      "cow" (qcow2/thin) ou "raw"
      sparse      thin provisioning
      bootable    marque true no disco de boot
      interface   virtio_scsi | virtio | ide | sata | spapr_vscsi
      source_file caminho local da imagem a enviar
  EOT

  type = list(object({
    alias       = string
    size_gib    = optional(number)
    format      = optional(string, "cow")
    sparse      = optional(bool, true)
    bootable    = optional(bool, false)
    interface   = optional(string, "virtio_scsi")
    source_file = optional(string)
  }))

  default = []

  validation {
    condition     = alltrue([for d in var.disks : contains(["cow", "raw"], d.format)])
    error_message = "format do disco precisa ser \"cow\" ou \"raw\"."
  }

  validation {
    condition = alltrue([
      for d in var.disks : contains(["ide", "sata", "spapr_vscsi", "virtio", "virtio_scsi"], d.interface)
    ])
    error_message = "interface do disco precisa ser ide, sata, spapr_vscsi, virtio ou virtio_scsi."
  }

  validation {
    condition     = alltrue([for d in var.disks : d.size_gib != null || d.source_file != null])
    error_message = "Cada disco precisa de size_gib (disco novo) OU source_file (disco a partir de imagem)."
  }

  validation {
    condition     = length(distinct([for d in var.disks : d.alias])) == length(var.disks)
    error_message = "Os aliases dos discos precisam ser únicos dentro da VM."
  }

  validation {
    condition     = length([for d in var.disks : d if d.bootable]) <= 1
    error_message = "Apenas um disco pode ser marcado como bootable."
  }
}

# ---------------------------------------------------------------------------
# Rede
# ---------------------------------------------------------------------------
variable "nics" {
  description = <<-EOT
    Placas de rede. O provider exige o UUID do PERFIL DE vNIC (não o nome da
    rede). Se vnic_profile_id for omitido em uma placa, usa-se
    default_vnic_profile_id.
      name            nome da placa dentro da VM (ex.: nic1, eth0)
      vnic_profile_id UUID do perfil

    MAC FIXO não está disponível: o recurso ovirt_nic do provider 2.2.0 não
    tem o atributo `mac` (só o branch de desenvolvimento tem). Para MAC fixo,
    use ovirt.ovirt.ovirt_nic (mac_address) via Ansible depois do apply.
  EOT

  type = list(object({
    name            = string
    vnic_profile_id = optional(string)
  }))

  default = []

  validation {
    condition     = length(distinct([for n in var.nics : n.name])) == length(var.nics)
    error_message = "Os nomes das placas de rede precisam ser únicos dentro da VM."
  }
}

variable "default_vnic_profile_id" {
  description = "UUID do perfil de vNIC usado pelas placas que não informam um."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Ciclo de vida e cloud-init
# ---------------------------------------------------------------------------
variable "start" {
  description = "true = liga a VM após criar discos e placas (recurso ovirt_vm_start)."
  type        = bool
  default     = false
}

variable "stop_behavior" {
  description = "Como desligar no destroy: \"shutdown\" (ACPI, padrão) ou \"stop\" (corta energia)."
  type        = string
  default     = "shutdown"

  validation {
    condition     = contains(["shutdown", "stop"], var.stop_behavior)
    error_message = "stop_behavior precisa ser \"shutdown\" ou \"stop\"."
  }
}

variable "wait_for_ip" {
  description = <<-EOT
    true = espera a VM reportar um IP antes de concluir o apply.
    Só funciona com start = true e com o guest agent (qemu-guest-agent)
    instalado na VM — sem ele o apply fica preso esperando.
  EOT
  type        = bool
  default     = false
}

variable "cloud_init_hostname" {
  description = "Hostname aplicado pelo cloud-init na primeira inicialização. null = não usar."
  type        = string
  default     = null
}

variable "cloud_init_script" {
  description = "Script/cloud-config executado na primeira inicialização. null = não usar."
  type        = string
  default     = null
}
