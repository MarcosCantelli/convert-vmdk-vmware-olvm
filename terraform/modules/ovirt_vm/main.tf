##############################################################################
# modules/ovirt_vm/main.tf — módulo reutilizável de VM no OLVM/oVirt.
#
# Cobre os dois cenários pedidos:
#   A) VM A PARTIR DE TEMPLATE  -> passe template_id
#   B) VM EM BRANCO (blank)     -> não passe template_id; o módulo usa o
#                                  template "Blank" do próprio oVirt e cria os
#                                  discos que você declarar
#
# Ordem de criação (o Terraform deduz pelas referências):
#   ovirt_vm -> ovirt_disk / ovirt_disk_from_image -> ovirt_disk_attachment
#            -> ovirt_nic -> (ajuste de firmware) -> ovirt_vm_start
##############################################################################

# ---------------------------------------------------------------------------
# Template "Blank": data source oficial do provider. Ele resolve o ID mesmo
# se o template Blank tiver sido recriado no engine.
# ---------------------------------------------------------------------------
data "ovirt_blank_template" "blank" {}

locals {
  # Se não veio template, usamos o Blank -> VM em branco.
  template_id = var.template_id != null ? var.template_id : data.ovirt_blank_template.blank.id

  # O provider espera memória em BYTES; a interface do módulo é em GiB porque
  # é assim que a gente pensa no dia a dia.
  memory_bytes         = var.memory_gib * 1024 * 1024 * 1024
  maximum_memory_bytes = var.maximum_memory_gib != null ? var.maximum_memory_gib * 1024 * 1024 * 1024 : null

  # Separamos os discos por RECURSO, porque são dois recursos diferentes:
  #   sem source_file -> ovirt_disk            (disco novo, vazio)
  #   com source_file -> ovirt_disk_from_image (envia uma imagem local)
  disks_blank = { for d in var.disks : d.alias => d if d.source_file == null }
  disks_image = { for d in var.disks : d.alias => d if d.source_file != null }

  # Todos os discos indexados por alias, para criar os anexos.
  disks_all = { for d in var.disks : d.alias => d }

  # alias -> UUID do disco, unindo os dois tipos.
  disk_ids = merge(
    { for alias, d in ovirt_disk.blank : alias => d.id },
    { for alias, d in ovirt_disk_from_image.image : alias => d.id },
  )

  nics = { for n in var.nics : n.name => n }

  # Tradução firmware -> bios_type do oVirt, usada apenas pelo ajuste via API.
  bios_type = var.firmware == null ? null : (var.firmware == "uefi" ? "q35_ovmf" : "q35_sea_bios")
}

# ---------------------------------------------------------------------------
# A VM
# ---------------------------------------------------------------------------
resource "ovirt_vm" "this" {
  name        = var.name
  cluster_id  = var.cluster_id
  template_id = local.template_id
  clone       = var.clone
  comment     = var.comment

  # CPU: o provider exige os três atributos juntos.
  cpu_sockets = var.cpu_sockets
  cpu_cores   = var.cpu_cores
  cpu_threads = var.cpu_threads

  memory         = local.memory_bytes
  maximum_memory = local.maximum_memory_bytes

  vm_type = var.vm_type
  os_type = var.os_type

  # cloud-init (só aplicado se o template/imagem tiver cloud-init instalado).
  initialization_hostname      = var.cloud_init_hostname
  initialization_custom_script = var.cloud_init_script
}

# ---------------------------------------------------------------------------
# Discos NOVOS (vazios)
# ---------------------------------------------------------------------------
resource "ovirt_disk" "blank" {
  for_each = local.disks_blank

  alias             = each.value.alias
  storage_domain_id = var.storage_domain_id
  format            = each.value.format
  sparse            = each.value.sparse
  # O provider recebe o tamanho em BYTES.
  size = each.value.size_gib * 1024 * 1024 * 1024
}

# ---------------------------------------------------------------------------
# Discos A PARTIR DE IMAGEM LOCAL
#
# O arquivo precisa estar acessível na máquina que roda o Terraform (no nosso
# caso, o runner do Jenkins). Para imagens grandes de migração, prefira o
# caminho do Ansible (ovirt-img upload-disk, na role `upload`): ele roda no
# host de virtualização, junto do NFS, sem trafegar os dados pelo runner.
# ---------------------------------------------------------------------------
resource "ovirt_disk_from_image" "image" {
  for_each = local.disks_image

  alias             = each.value.alias
  storage_domain_id = var.storage_domain_id
  format            = each.value.format
  sparse            = each.value.sparse
  source_file       = each.value.source_file
}

# ---------------------------------------------------------------------------
# Anexo dos discos à VM
# Usamos ovirt_disk_attachment (singular). NÃO misture com
# ovirt_disk_attachments (plural) na mesma VM: os dois recursos brigam entre
# si e ficam criando/removendo anexos em cada apply.
# ---------------------------------------------------------------------------
resource "ovirt_disk_attachment" "this" {
  for_each = local.disks_all

  vm_id          = ovirt_vm.this.id
  disk_id        = local.disk_ids[each.key]
  disk_interface = each.value.interface
  bootable       = each.value.bootable
  active         = true
}

# ---------------------------------------------------------------------------
# Placas de rede
# ---------------------------------------------------------------------------
resource "ovirt_nic" "this" {
  for_each = local.nics

  name  = each.value.name
  vm_id = ovirt_vm.this.id
  # A placa usa o perfil dela; se não informou, cai no padrão do módulo.
  vnic_profile_id = coalesce(each.value.vnic_profile_id, var.default_vnic_profile_id)

  # MAC FIXO: o recurso ovirt_nic do provider 2.2.0 NÃO aceita `mac` — o
  # atributo existe apenas no branch de desenvolvimento do provider, ainda
  # não publicado. Se precisar de MAC fixo hoje, use o módulo Ansible
  # ovirt.ovirt.ovirt_nic (parâmetro mac_address) após o apply.

  lifecycle {
    precondition {
      condition     = coalesce(each.value.vnic_profile_id, var.default_vnic_profile_id, "") != ""
      error_message = "A placa '${each.value.name}' precisa de vnic_profile_id (nela ou em default_vnic_profile_id)."
    }
  }
}

# ---------------------------------------------------------------------------
# Ajuste de FIRMWARE via API REST — opcional e DESLIGADO por padrão.
#
# Existe porque o provider 2.2.0 não expõe bios_type. A alternativa
# recomendada é ter templates separados (um BIOS, um UEFI).
#
# O ajuste roda com a VM ainda desligada, e o ovirt_vm_start depende dele,
# garantindo a ordem: criar -> ajustar firmware -> ligar.
#
# A senha vai por VARIÁVEL DE AMBIENTE do processo curl, não na linha de
# comando, para não aparecer no `ps` da máquina.
#
# NÃO TESTADO contra o engine — valide antes de habilitar.
# ---------------------------------------------------------------------------
resource "null_resource" "firmware" {
  count = var.firmware_apply_via_api && var.firmware != null ? 1 : 0

  # Reaplica se a VM ou o firmware desejado mudarem.
  triggers = {
    vm_id     = ovirt_vm.this.id
    bios_type = local.bios_type
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    quiet       = true

    environment = {
      OVIRT_USER = var.engine_username
      OVIRT_PASS = var.engine_password
    }

    command = <<-EOT
      set -euo pipefail
      http_code=$(curl -sS -o /dev/null -w '%%{http_code}' \
        -X PUT ${var.engine_tls_insecure ? "-k" : ""} \
        -u "$OVIRT_USER:$OVIRT_PASS" \
        -H 'Content-Type: application/xml' \
        -H 'Accept: application/xml' \
        '${var.engine_url}vms/${ovirt_vm.this.id}' \
        -d '<vm><bios><type>${local.bios_type}</type></bios></vm>')
      if [ "$http_code" != "200" ]; then
        echo "Falha ao ajustar firmware da VM ${var.name}: HTTP $http_code" >&2
        exit 1
      fi
      echo "Firmware da VM ${var.name} ajustado para ${local.bios_type}."
    EOT
  }

  lifecycle {
    precondition {
      condition = !var.firmware_apply_via_api || (
        var.engine_url != null && var.engine_username != null && var.engine_password != null
      )
      error_message = "firmware_apply_via_api = true exige engine_url, engine_username e engine_password."
    }
  }
}

# ---------------------------------------------------------------------------
# Ligar a VM
# O depends_on é explícito porque queremos que discos, placas e firmware
# estejam prontos ANTES do primeiro boot.
# ---------------------------------------------------------------------------
resource "ovirt_vm_start" "this" {
  count = var.start ? 1 : 0

  vm_id         = ovirt_vm.this.id
  stop_behavior = var.stop_behavior

  depends_on = [
    ovirt_disk_attachment.this,
    ovirt_nic.this,
    null_resource.firmware,
  ]
}

# ---------------------------------------------------------------------------
# Esperar o IP (exige qemu-guest-agent dentro da VM)
# ---------------------------------------------------------------------------
data "ovirt_wait_for_ip" "this" {
  count = var.start && var.wait_for_ip ? 1 : 0

  vm_id = ovirt_vm_start.this[0].vm_id
}
