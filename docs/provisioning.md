# Provisionamento de VMs novas (Terraform)

Como criar VMs no OLVM a partir de **template** ou **em branco**, com o módulo
reutilizável `terraform/modules/ovirt_vm`.

## Índice

1. [Provider e versões](#1-provider-e-versões)
2. [Descobrir os UUIDs](#2-descobrir-os-uuids)
3. [Configurar segredos](#3-configurar-segredos)
4. [VM em branco](#4-vm-em-branco-sem-template)
5. [VM a partir de template](#5-vm-a-partir-de-template)
6. [VM a partir de imagem local](#6-vm-a-partir-de-imagem-local)
7. [Firmware: leia antes de assumir](#7-firmware-leia-antes-de-assumir)
8. [Rodar](#8-rodar)
9. [Testar sem OLVM (modo mock)](#9-testar-sem-olvm-modo-mock)
10. [Estado do Terraform](#10-estado-do-terraform)
11. [Endurecer o TLS](#11-endurecer-o-tls)
12. [Referência do módulo](#12-referência-do-módulo)

---

## 1. Provider e versões

| Item | Valor |
|---|---|
| Provider | `oVirt/ovirt` (mantido pela organização oVirt) |
| Versão fixada | `~> 2.2` (2.2.0 é a última publicada) |
| Terraform | `>= 1.3.0` (usamos `optional()` em tipos de objeto) |

Providers antigos que aparecem em tutoriais e **não** devem ser usados:
`imjoey/ovirt`, `EMSL-MSC/ovirt`.

## 2. Descobrir os UUIDs

O provider v2 não tem data source para procurar cluster, storage domain ou
perfil de vNIC pelo nome — só aceita UUID. O script faz a consulta na API:

```bash
cd terraform
export OVIRT_PASSWORD='senha-do-admin@ovirt@internalsso'
./scripts/get-ovirt-ids.sh
```

Ele lista datacenters, clusters, storage domains, perfis de vNIC, templates e
redes com os respectivos IDs. Copie para o `terraform.tfvars`:

```hcl
cluster_id        = "..."   # cluster Default
storage_domain_id = "..."   # hosted_storage
vnic_profile_id   = "..."   # perfil da rede ovirtmgmt
```

O template `Blank` aparece na lista, mas você **não** precisa do ID dele: o
módulo o descobre sozinho quando `template_id` fica ausente.

## 3. Configurar segredos

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # ignorado pelo git
$EDITOR terraform.tfvars                       # UUIDs e VMs — SEM senha

export TF_VAR_ovirt_password='senha-do-admin@ovirt@internalsso'
```

A senha **nunca** entra em arquivo. No Jenkins ela vem da credential
`olvm-api-password` (*Secret text*), exposta ao Terraform como
`TF_VAR_ovirt_password`.

## 4. VM em branco (sem template)

Cria a VM, um disco vazio e a placa de rede. Serve para instalar o sistema
depois pelo console/ISO.

```hcl
vms = {
  "app-teste-01" = {
    cpu_sockets = 1
    cpu_cores   = 2
    cpu_threads = 1
    memory_gib  = 4

    disks = [{
      alias     = "app-teste-01-boot"
      size_gib  = 40
      format    = "cow"        # cow = qcow2/thin; raw = pré-alocado
      bootable  = true
      interface = "virtio_scsi"
    }]

    nics  = [{ name = "nic1" }]
    start = false              # crie desligada e valide antes de ligar
  }
}
```

Como o provider exige `template_id` no recurso `ovirt_vm`, "VM em branco"
significa usar o template `Blank` do oVirt — o módulo faz isso via o data source
`ovirt_blank_template`.

## 5. VM a partir de template

O template já traz o disco de sistema, então não declare disco de boot: declare
só os discos adicionais.

```hcl
vms = {
  "web-teste-01" = {
    template_id = "uuid-do-template"
    clone       = true       # true = VM independente do template

    cpu_sockets = 2
    cpu_cores   = 2
    memory_gib  = 8
    os_type     = "other_linux"

    disks = [{
      alias    = "web-teste-01-dados"
      size_gib = 100
    }]

    nics = [{ name = "nic1" }]

    cloud_init_hostname = "web-teste-01"
    cloud_init_script   = "packages:\n  - qemu-guest-agent\n"

    start = true
  }
}
```

`clone`:

- `false` (padrão) — VM "linkada" ao template: criação rápida, ocupa menos
  espaço, mas o template não pode ser removido enquanto a VM existir.
- `true` — VM clonada: independente, ocupa espaço próprio.

`cloud_init_*` só tem efeito se o template tiver cloud-init instalado.

## 6. VM a partir de imagem local

O módulo aceita `source_file` num disco, usando `ovirt_disk_from_image`:

```hcl
disks = [{
  alias       = "app-boot"
  format      = "cow"
  bootable    = true
  source_file = "/var/lib/images/oracle-linux-9.qcow2"
}]
```

**Para migração, prefira o caminho do Ansible.** O `source_file` precisa estar na
máquina que executa o Terraform, então centenas de GB atravessariam o runner do
Jenkins. A role `upload` faz o envio de dentro do host de virtualização, vizinho
do NFS. Use `source_file` apenas para imagens pequenas (imagens cloud de
distribuição, por exemplo).

## 7. Firmware: leia antes de assumir

**O recurso `ovirt_vm` do provider 2.2.0 não expõe `bios_type`.** Verificado no
schema do provider instalado, não é suposição. Consequências:

| Cenário | Firmware resultante |
|---|---|
| VM a partir de template | o firmware **do template** |
| VM em branco | o padrão **do cluster** |

Se você precisa de BIOS e UEFI, a forma recomendada é manter **dois templates** e
escolher pelo `template_id`.

Há um caminho opcional no módulo que ajusta o firmware via API REST depois de
criar a VM (antes de ligar):

```hcl
firmware               = "uefi"   # bios -> q35_sea_bios | uefi -> q35_ovmf
firmware_apply_via_api = true
```

Ele exige `curl` na máquina do Terraform e vem **desligado por padrão**. Não foi
testado contra o engine — valide antes de confiar. A alternativa, já testada
neste repositório pela via do Ansible, é:

```bash
ansible localhost -m ovirt.ovirt.ovirt_vm \
  -a "name=minha-vm cluster=Default bios_type=q35_ovmf state=present"
```

O output `firmware` de cada VM (`terraform output vms`) informa se o ajuste foi
aplicado (`applied: true`) ou se o firmware veio do template
(`applied: false`).

**MAC fixo** também não existe no provider 2.2.0 (`ovirt_nic` não tem `mac`).
Use `ovirt.ovirt.ovirt_nic` com `mac_address` via Ansible se precisar.

## 8. Rodar

```bash
cd terraform
terraform init
terraform validate
terraform plan            # revise SEMPRE antes
terraform apply
terraform output vms
```

Pelo Jenkins: job com `jenkins/Jenkinsfile.provision`. O fluxo é
`init → validate → plan → aprovação manual → apply`, e o apply executa o plano
**salvo** (`-out=tfplan`) — exatamente o que foi aprovado, sem recalcular.

Para remover:

```bash
terraform destroy                                  # tudo
terraform destroy -target='module.vm["app-teste-01"]'   # uma VM
```

## 9. Testar sem OLVM (modo mock)

O provider tem modo simulação embutido, que roda tudo em memória:

```bash
terraform plan -var ovirt_mock=true -var ovirt_password=fake
```

Serve para validar a configuração em CI ou na sua máquina, sem engine à mão.
Nunca use em produção: o estado simulado é descartado.

## 10. Estado do Terraform

O `Jenkinsfile.provision` usa **backend local**: o `terraform.tfstate` fica no
workspace do job e **não sobrevive à limpeza dele**. Perder o state significa que
o Terraform esquece o que criou.

Antes de usar para valer, configure um backend remoto. Opções no seu ambiente:
S3-compatible no TrueNAS (MinIO), um `http` backend, ou no mínimo um diretório
persistente fora do workspace:

```hcl
# terraform/backend.tf (crie conforme sua escolha)
terraform {
  backend "local" {
    path = "/var/lib/jenkins/tfstate/olvm/terraform.tfstate"
  }
}
```

E adicione o backup desse caminho à sua rotina.

## 11. Endurecer o TLS

Enquanto o certificado do engine não tiver o FQDN no SAN, use
`ovirt_tls_insecure = true`. Para corrigir depois:

```bash
curl -k -o ovirt-ca.pem \
  'https://olvm.mvrc.local/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA'
```

Em `terraform.tfvars`:

```hcl
ovirt_tls_insecure = false
ovirt_tls_ca_files = ["/caminho/ovirt-ca.pem"]
```

E em `providers.tf`, comente `tls_insecure` e descomente `tls_ca_files` — as
opções são **mutuamente exclusivas** no provider.

Atenção: mesmo com o CA correto, a verificação **de hostname** continua falhando
enquanto o certificado não trouxer `olvm.mvrc.local` no SAN. Regerar o
certificado do engine com o SAN certo é o conserto de verdade.

## 12. Referência do módulo

| Variável | Padrão | Descrição |
|---|---|---|
| `name` | — | Nome da VM (obrigatório) |
| `cluster_id` | — | UUID do cluster (obrigatório) |
| `storage_domain_id` | — | UUID do storage domain (obrigatório) |
| `template_id` | `null` | UUID do template; `null` = VM em branco |
| `clone` | `false` | Clonar o template |
| `cpu_sockets` / `cpu_cores` / `cpu_threads` | `1` / `2` / `1` | O provider exige os três juntos |
| `memory_gib` | `4` | Memória em GiB (o módulo converte para bytes) |
| `maximum_memory_gib` | `null` | Memória máxima para hot-plug |
| `vm_type` | `server` | `server`, `desktop`, `high_performance` |
| `os_type` | `null` | ID do SO no oVirt — confirme os válidos no seu engine |
| `disks` | `[]` | Lista; `size_gib` (novo) ou `source_file` (imagem) |
| `nics` | `[]` | Lista com `name` e `vnic_profile_id` opcional |
| `default_vnic_profile_id` | `null` | Perfil usado pelas placas que não informam um |
| `firmware` | `null` | `bios` / `uefi` — só aplicado com a flag abaixo |
| `firmware_apply_via_api` | `false` | Ajuste via API REST (não testado) |
| `start` | `false` | Ligar após criar discos e placas |
| `stop_behavior` | `shutdown` | `shutdown` (ACPI) ou `stop` (corta energia) |
| `wait_for_ip` | `false` | Esperar IP — **exige `qemu-guest-agent`** |
| `cloud_init_hostname` / `cloud_init_script` | `null` | cloud-init na primeira inicialização |

Outputs: `vm_id`, `vm_name`, `vm_status`, `template_id_used`, `disk_ids`,
`disk_attachment_ids`, `nic_ids`, `started`, `ipv4_addresses`,
`firmware_intent`.

### Valores válidos (conferidos no schema do provider 2.2.0)

- `format` do disco: `cow`, `raw`
- `interface` do disco: `ide`, `sata`, `spapr_vscsi`, `virtio`, `virtio_scsi`
- `vm_type`: `server`, `desktop`, `high_performance`
- `stop_behavior`: `shutdown`, `stop`
