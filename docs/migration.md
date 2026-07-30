# Migração de VMs: vCenter/ESXi → OLVM

Tutorial completo do processo automatizado neste repositório. Cada seção
explica **o que** roda e **por que** — várias das regras aqui vêm de uma
migração manual bem-sucedida e existem para você não repetir os mesmos erros.

## Índice

1. [Antes de começar](#1-antes-de-começar)
2. [As cinco lições que definem o processo](#2-as-cinco-lições-que-definem-o-processo)
3. [Preparar os segredos](#3-preparar-os-segredos)
4. [Precheck: descobrir o firmware](#4-precheck-descobrir-o-firmware)
5. [Declarar a VM](#5-declarar-a-vm)
6. [Migrar](#6-migrar)
7. [Depois da migração](#7-depois-da-migração)
8. [O caso especial do Jenkins](#8-o-caso-especial-do-jenkins)
9. [Problemas conhecidos](#9-problemas-conhecidos)
10. [Fazendo à mão](#10-fazendo-à-mão-quando-precisar-entender-ou-depurar)

---

## 1. Antes de começar

No host de virtualização (`192.168.31.11`):

```bash
# Ferramentas obrigatórias
dnf install -y qemu-img ovirt-imageio-client guestfs-tools python3-ovirt-engine-sdk4

# Confirme
command -v qemu-img ovirt-img virt-customize
python3 -c 'import ovirtsdk4; print("SDK OK")'

# O NFS de 2 TB precisa estar montado
mountpoint /mnt/sd1
```

Permissões, uma vez só (o pipeline conecta como `mvrc`, sem sudo):

```bash
sudo mkdir -p /mnt/sd1/migracao
sudo chown mvrc:mvrc /mnt/sd1/migracao   # escrever os qcow2 no NFS
sudo usermod -aG kvm mvrc                # virt-customize usar /dev/kvm
# saia e entre de novo na sessão para o grupo kvm valer
```

No runner do Jenkins (ou na sua estação):

```bash
# A zona mvrc.local roda num BIND9 que o roteador não encaminha.
# Sem esta linha, nada resolve o engine:
echo '192.168.31.9  olvm.mvrc.local olvm' | sudo tee -a /etc/hosts
```

### Duas cadeias de SSH diferentes (é aqui que todo mundo se confunde)

```
[runner Jenkins] --(1)--> [host OLVM 31.11] --(2)--> [ESXi 31.12]
```

1. **Runner → host OLVM**, como `mvrc`. É o Ansible conectando. Provavelmente
   já funciona: se `ssh mvrc@192.168.31.11` entra sem senha, está pronto.
2. **Host OLVM → ESXi**, como `root`. É o `scp` puxando os discos. **Esta é a
   que falta.**

O detalhe que importa: o `scp` roda **de dentro do 31.11**, como o usuário
`mvrc`. Logo, a chave que o ESXi precisa autorizar é a **do `mvrc` no 31.11** —
não a da sua estação. Chave de máquina diferente, par diferente.

### Instalando a chave no ESXi

**Passo 1 — habilite o SSH no ESXi.** No vSphere Client: *Host → Configure →
System → Services → TSM-SSH → Start*. (Ou no ESXi Shell/DCUI:
`Troubleshooting Options → Enable SSH`.)

**Passo 2 — gere o par de chaves para o `mvrc` no host OLVM**, se ainda não
existir:

```bash
ssh mvrc@192.168.31.11
ls ~/.ssh/id_rsa.pub || ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa -C 'mvrc@olvm-host-01 migracao'
cat ~/.ssh/id_rsa.pub    # copie esta linha inteira
```

> **RSA, e não ed25519 — isto não é preferência de estilo.** O ESXi 6.7 roda o
> sshd em **modo FIPS**, que só aceita algoritmos homologados. Uma chave
> ed25519 é instalada sem erro nenhum, o cliente a oferece normalmente e o
> servidor recusa em silêncio: você vê apenas
> `Permission denied (publickey,keyboard-interactive)` e passa horas conferindo
> permissão de arquivo à toa.
>
> O motivo real só aparece no `/var/log/auth.log` **do ESXi**:
> ```
> sshd: FIPS mode initialized
> sshd: userauth_pubkey: key type ssh-ed25519 not in PubkeyAcceptedKeyTypes
> ```
> Guarde este endereço: sempre que a chave parecer perfeita e ainda assim for
> recusada, o log do lado do servidor é o primeiro lugar para olhar.
>
> `-N ''` cria a chave sem passphrase, de propósito: o Jenkins não tem como
> digitar senha de chave.

**Passo 3 — autorize essa chave no ESXi.** O ESXi **não** usa
`~/.ssh/authorized_keys` como o Linux: o arquivo do root fica em
`/etc/ssh/keys-root/authorized_keys`. Ainda de dentro do 31.11:

```bash
# Vai pedir a senha do root do ESXi — esta é a única vez.
cat ~/.ssh/id_rsa.pub | ssh root@192.168.31.12 \
  "cat >> /etc/ssh/keys-root/authorized_keys && chmod 600 /etc/ssh/keys-root/authorized_keys"
```

Se o teste do Passo 5 falhar com `no mutual signature algorithm`, é o cliente
(Oracle Linux 8) recusando assinatura RSA com SHA-1. Libere só para este host,
no `~/.ssh/config` **do 31.11**:

```bash
cat >> ~/.ssh/config <<'EOF'

Host 192.168.31.12
    User root
    PubkeyAcceptedKeyTypes +ssh-rsa
EOF
chmod 600 ~/.ssh/config
```

Não use `ssh-copy-id`: ele escreve em `~/.ssh/authorized_keys`, que no ESXi é
ignorado — a autenticação continuaria pedindo senha e você acharia que a chave
não funcionou.

**Passo 4 — persista.** O ESXi mantém parte da configuração em ramdisk e só
grava no disco periodicamente. Se o host reiniciar antes disso, a chave se
perde. Force o salvamento:

```bash
ssh root@192.168.31.12 /sbin/auto-backup.sh
```

**Passo 5 — teste a cadeia inteira**, exatamente como o Ansible vai fazer
(`-o BatchMode=yes` falha em vez de pedir senha, então o teste é honesto):

```bash
ssh mvrc@192.168.31.11 \
  "ssh -o BatchMode=yes root@192.168.31.12 'ls /vmfs/volumes/VS2_HD2_1TB'"
```

Se listar as pastas das VMs, acabou — o `precheck.yml` e a role `extract` vão
funcionar.

### Alternativa: senha em vez de chave

Se não quiser mexer no ESXi, existe o caminho por senha. Em
`group_vars/all.yml` mude `esxi_use_ssh_password: true`, preencha
`vault_esxi_ssh_password` no vault, e instale `sshpass` no 31.11
(`sudo dnf install -y sshpass`).

Funciona, mas a senha do root do ESXi fica visível no `ps aux` do host durante
toda a cópia — que dura horas num disco grande. Prefira a chave.

## 2. As cinco lições que definem o processo

### 2.1 Cada disco são DOIS arquivos

```
srv-app-01.vmdk        <- descritor, alguns KB de texto
srv-app-01-flat.vmdk   <- os dados, o disco inteiro
```

O `qemu-img` recebe o **descritor**, mas precisa encontrar o arquivo de dados ao
lado. Copiar só um dos dois é o erro clássico, e o sintoma é
`Could not open backing file`. A role `extract` copia sempre o par, num único
`scp`.

Alguns layouts thin usam `-sparse` ou fragmentam em `-s001`, `-s002`. Ajuste
`extract_data_suffix` na role se for o seu caso.

### 2.2 A conversão tem uma forma certa

```bash
qemu-img convert -p -f vmdk -O qcow2 -o compat=1.1 disco.vmdk disco.qcow2
```

`compat=1.1` é o formato qcow2 moderno, que o QEMU/oVirt atual espera.

### 2.3 O certificado do engine não tem o FQDN no SAN

A verificação de hostname falha. Por isso o `ovirt-img` precisa de `--insecure`
(e o Terraform, de `tls_insecure`). É contorno de fase, não destino: quando o
certificado for corrigido, troque para `--cafile`/`tls_ca_files`.

### 2.4 O firmware decide se a VM boota

BIOS e UEFI não são intercambiáveis. Criar a VM com o firmware errado resulta em
VM que liga e não acha o disco de boot.

Descubra no `.vmx`:

```bash
grep -i firmware /vmfs/volumes/VS2_HD2_1TB/srv-app-01/srv-app-01.vmx
```

| Saída | Firmware | `bios_type` no oVirt |
|---|---|---|
| `firmware = "efi"` | UEFI | `q35_ovmf` |
| **vazia** | BIOS | `q35_sea_bios` |

Saída vazia **é resposta**: o VMware só escreve essa linha quando é EFI.

### 2.5 A rede muda de nome — corrija OFFLINE

`ens160` (VMware) vira `enp1s0` (KVM). A configuração antiga aponta para uma
interface que não existe: a VM sobe sem rede, e sem rede o Ansible não entra
para consertar. Impasse.

A role `fix_network` resolve com a VM desligada:

```bash
LIBGUESTFS_BACKEND=direct virt-customize -a disco.qcow2 \
  --upload 99-migracao-netcfg.yaml:/etc/netplan/99-migracao-netcfg.yaml \
  --run-command 'rm -f /etc/udev/rules.d/70-persistent-net.rules /etc/netplan/50-cloud-init.yaml'
```

O netplan injetado casa por **padrão**, não por nome:

```yaml
network:
  version: 2
  ethernets:
    migracao-dhcp:
      match:
        name: "en*"     # <- o truque: funciona com qualquer nome
      dhcp4: true
      optional: true
```

Dois detalhes que economizam tempo:

- `LIBGUESTFS_BACKEND=direct` é obrigatório — sem ele o libguestfs tenta usar
  libvirt e falha por permissão no host oVirt.
- Usamos `--run-command 'rm -f ...'` em vez de `--delete` porque `rm -f` não
  reclama quando o arquivo não existe: a mesma receita serve para VMs com e sem
  cloud-init.

### Bônus: trabalhe em pasta irmã

Toda a área de trabalho é `/mnt/sd1/migracao/<vm>/`. **Nunca** escreva dentro
dos diretórios com UUID que o oVirt gerencia — isso corrompe os metadados do
storage domain. A única porta de entrada para o storage domain é a API.

## 3. Preparar os segredos

O arquivo vai em `ansible/group_vars/vault.yml`, **ao lado** do `.example`. O
diretório `group_vars/` já existe no repositório: não crie pasta nova nem pasta
oculta — o `.gitignore` já bloqueia exatamente esse caminho.

```bash
cd ~/projetos/convert-vmdk-vmware-olvm/ansible     # o cd importa: os caminhos
                                                   # abaixo são relativos a ele
cp group_vars/vault.yml.example group_vars/vault.yml
$EDITOR group_vars/vault.yml          # preencha vault_ovirt_password

# crie PRIMEIRO o arquivo com a senha do vault...
echo 'senha-do-vault' > ~/.vault-pass && chmod 600 ~/.vault-pass

# ...e criptografe usando ELE, não o prompt interativo
ansible-vault encrypt --vault-password-file ~/.vault-pass group_vars/vault.yml

# confirme que abre, sem imprimir o segredo na tela
ansible-vault view --vault-password-file ~/.vault-pass group_vars/vault.yml > /dev/null && echo "vault OK"

# confirme que o git não vê o arquivo (deve imprimir o caminho e nada mais)
git check-ignore -v group_vars/vault.yml
```

> **Criptografe com o `--vault-password-file`, não com o prompt.** São duas
> senhas diferentes em jogo — a do *engine*, que vai **dentro** do arquivo, e a
> do *vault*, que **abre** o arquivo. Digitar a segunda num prompt e depois
> escrever outra coisa no `~/.vault-pass` gera:
> ```
> ERROR! Decryption failed (no vault secrets were found that could decrypt)
> ```
> Usando o mesmo arquivo nas duas pontas, não há como divergir.
>
> Se já aconteceu: `rm group_vars/vault.yml`, copie o `.example` de novo e
> refaça com o comando acima. Ou, se você lembra a senha original,
> `ansible-vault rekey --new-vault-password-file ~/.vault-pass group_vars/vault.yml`.

Guarde a senha do vault num arquivo fora do repositório:

```bash
echo 'senha-do-vault' > ~/.vault-pass && chmod 600 ~/.vault-pass
```

No Jenkins, a mesma coisa vira a credential `ansible-vault-password`
(tipo *Secret file*).

O `group_vars/vault.yml` está no `.gitignore`. Os playbooks o carregam
explicitamente via `vars_files`, porque um arquivo em `group_vars/` só é
carregado automaticamente se existir um grupo com aquele nome — e não existe
grupo `vault`.

## 4. Precheck: descobrir o firmware

Somente leitura, não altera nada no ESXi:

```bash
cd ansible
ansible-playbook precheck.yml -e vm_name=srv-app-01
```

O relatório traz firmware, `guestOS`, CPU, memória e a lista de `.vmdk`. Anote o
firmware — é o dado mais importante.

Sem `-e vm_name=`, o precheck roda em todas as VMs de `vars/vms.yml`.

## 5. Declarar a VM

Em `ansible/vars/vms.yml`:

```yaml
vms:
  - name: srv-app-01
    esxi_folder: srv-app-01       # pasta no datastore; default = name
    disks:
      - srv-app-01                # PRIMEIRO = disco de boot
      - srv-app-01-dados
    firmware: bios                # do precheck
    operating_system: other_linux # confirme os IDs válidos no seu engine
    cpu_sockets: 1
    cpu_cores: 2
    cpu_threads: 1
    memory_gib: 4
    fix_network: true
```

Sobre `disks`: escreva o nome **base**, sem extensão e sem `-flat`. Para
`srv-app-01.vmdk` + `srv-app-01-flat.vmdk`, escreva `srv-app-01`.

## 6. Migrar

Uma VM:

```bash
cd ansible
ansible-playbook migrate-single.yml -e vm_name=srv-app-01 \
  --vault-password-file ~/.vault-pass
```

Um lote:

```bash
# todas as de vars/vms.yml
ansible-playbook migrate-batch.yml --vault-password-file ~/.vault-pass

# apenas algumas
ansible-playbook migrate-batch.yml \
  -e '{"vms_filter": ["srv-app-01", "srv-app-02"]}' \
  --vault-password-file ~/.vault-pass
```

Pelo Jenkins: job com `jenkins/Jenkinsfile.migrate`, parametrizado por nome,
datastore, firmware, CPU e memória. Uma VM que não esteja em `vars/vms.yml` pode
ser migrada só pelos parâmetros do build — o pipeline monta a definição e passa
como `vm_override`.

O playbook é **idempotente**: se falhar no upload, reexecute. A cópia e a
conversão já feitas são reaproveitadas.

A VM é criada **desligada** (`vm_state_after_create: present`) de propósito:
você valida antes de ligar. Para ligar automaticamente, mude para `running` em
`group_vars/all.yml`.

## 7. Depois da migração

1. Ligue a VM no OLVM e abra o console.
2. Confirme que ela pegou IP por DHCP (`ip a`).
3. Instale o agente convidado, que melhora relatório de IP e desligamento
   ordenado:
   ```bash
   dnf install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent
   # Debian/Ubuntu: apt install -y qemu-guest-agent
   ```
4. Remova o que é resquício do VMware (`open-vm-tools`).
5. Aplique a configuração de rede **definitiva**. Veja
   [Recuperando o IP fixo](#recuperando-o-ip-fixo) logo abaixo — a VM sobe em
   DHCP de propósito, e isso não é o estado final.
6. Valide aplicação e dados.
7. **Só então** desligue a VM original no ESXi. Mantenha-a desligada alguns dias
   antes de remover — é o seu rollback.
8. Quando estiver seguro, libere espaço no NFS:
   ```bash
   rm -rf /mnt/sd1/migracao/srv-app-01
   ```
   (ou deixe `extract_remove_vmdk_after_convert: true` para apagar os `.vmdk`
   logo após a conversão — recomendo manter `false` até validar.)

### Recuperando o IP fixo

A VM migrada sobe em **DHCP**, e isso é intencional: o `99-migracao-netcfg.yaml`
existe para ela não subir isolada quando o nome da interface muda. Não é o
estado final.

A boa notícia é que a configuração antiga **continua dentro da VM**. A role
`fix_network` só remove `70-persistent-net.rules` e `50-cloud-init.yaml`; um
`00-installer-config.yaml`, por exemplo, permanece intacto. Ele é ignorado
porque nomeia `ens160`, que não existe mais no KVM — mas é ali que está o IP
que a VM usava.

Dentro da VM, com o console do OLVM:

```bash
# 1. descubra o endereço antigo e os dados da rede atual
ls -la /etc/netplan/
sudo cat /etc/netplan/*.yaml     # o arquivo antigo tem o IP fixo original
ip r                             # gateway
resolvectl status | grep -i 'dns servers'

# 2. escreva a configuração definitiva, agora com o nome NOVO da interface
sudo tee /etc/netplan/01-static.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: false
      addresses: [192.168.31.XXX/24]
      routes:
        - to: default
          via: 192.168.31.1
      nameservers:
        addresses: [192.168.31.9]
EOF
sudo chmod 600 /etc/netplan/01-static.yaml

# 3. remova a rede de segurança da migração e aplique
sudo rm -f /etc/netplan/99-migracao-netcfg.yaml
sudo netplan try                 # reverte sozinho em 120s se algo quebrar
```

Três detalhes:

- **`netplan try` antes de `apply`.** Ele desfaz a mudança sozinho se você não
  confirmar, o que salva a sessão quando a configuração está errada.
- **`routes: - to: default`**, e não `gateway4`, que está descontinuado e gera
  aviso nas versões atuais do netplan.
- **Confira o que mais aponta para esse IP** antes de trocar: registro no
  BIND9, entradas em `/etc/hosts` de outras máquinas, e a reserva de DHCP —
  se houver uma reserva para o MAC antigo, ela não vale mais, porque a VM
  ganhou MAC novo no oVirt.

## 8. O caso especial do Jenkins

A VM do Jenkins **não pode** ser migrada por este pipeline: ela o está
executando. O repositório tem três guardas que abortam se `jenkins` aparecer no
nome (pipeline, playbooks, e o `migrate_one.yml`).

Para migrá-la, faça à mão, com o pipeline parado:

1. Pare o Jenkins e coloque-o em quiet mode; espere terminar o que está rodando.
2. Faça backup de `JENKINS_HOME`.
3. Desligue a VM no ESXi.
4. Execute manualmente os passos da seção 10 **de outra máquina** (não de dentro
   do Jenkins).
5. Suba a VM no OLVM, valide, e só então aponte os jobs para o novo endereço.

## 9. Problemas conhecidos

| Sintoma | Causa | Solução |
|---|---|---|
| `Could not open backing file` na conversão | só o descritor foi copiado | copie o par `.vmdk` + `-flat.vmdk` |
| VM sobe sem rede | nome da interface mudou | rode `fix_network` (offline) antes do boot |
| VM liga e não acha o disco | firmware errado | confira com o precheck; `bios`→`q35_sea_bios`, `uefi`→`q35_ovmf` |
| `certificate verify failed` no upload | cert do engine sem FQDN no SAN | `ovirt_insecure: true` (ou corrija o certificado) |
| `virt-customize` falha com erro de libvirt/permissão | backend errado | `LIBGUESTFS_BACKEND=direct` (a role já define) |
| `no operating system was found on this disk` | `virt-customize` num disco de dados | `fix_network_disks` só deve conter o disco de boot |
| `ModuleNotFoundError: ovirtsdk4` | SDK ausente no host | `dnf install python3-ovirt-engine-sdk4` |
| Upload trava/expira | disco grande em NFS 1 GbE | aumente `upload_timeout` |
| Metadados do storage domain corrompidos | escreveu dentro da pasta com UUID | trabalhe em `/mnt/sd1/migracao` |
| `Permission denied` no scp do ESXi | sem chave SSH | `authorized_keys` em `/etc/ssh/keys-root/` no ESXi |
| `Permission denied` **mesmo com a chave instalada** | ESXi 6.7 em modo FIPS recusa ed25519 | use chave **RSA** (`ssh-keygen -t rsa -b 4096`); confirme em `/var/log/auth.log` do ESXi |
| `no mutual signature algorithm` | cliente OL8 recusa RSA com SHA-1 | `PubkeyAcceptedKeyTypes +ssh-rsa` no `~/.ssh/config` do host, só para o IP do ESXi |
| Chave some depois de reiniciar o ESXi | config do ESXi vive em ramdisk | rode `/sbin/auto-backup.sh` após instalar |

## 10. Fazendo à mão (quando precisar entender ou depurar)

É exatamente o que a automação faz, na mesma ordem:

```bash
# --- no host de virtualização (192.168.31.11) ---
VM=srv-app-01
DS=/vmfs/volumes/VS2_HD2_1TB
WORK=/mnt/sd1/migracao/$VM
mkdir -p $WORK && cd $WORK

# 1. copiar o PAR de arquivos
scp root@192.168.31.12:$DS/$VM/$VM.vmdk \
    root@192.168.31.12:$DS/$VM/$VM-flat.vmdk .

# 2. converter
qemu-img convert -p -f vmdk -O qcow2 -o compat=1.1 $VM.vmdk $VM.qcow2
qemu-img info $VM.qcow2

# 3. corrigir a rede OFFLINE
cat > 99-migracao-netcfg.yaml <<'EOF'
network:
  version: 2
  ethernets:
    migracao-dhcp:
      match:
        name: "en*"
      dhcp4: true
      optional: true
EOF

LIBGUESTFS_BACKEND=direct virt-customize -a $VM.qcow2 \
  --upload 99-migracao-netcfg.yaml:/etc/netplan/99-migracao-netcfg.yaml \
  --run-command 'chmod 0600 /etc/netplan/99-migracao-netcfg.yaml || true' \
  --run-command 'rm -f /etc/udev/rules.d/70-persistent-net.rules /etc/netplan/50-cloud-init.yaml' \
  --run-command 'netplan generate || true'

# 4. enviar ao storage domain
printf '%s' 'SENHA-DO-ENGINE' > .engine-pass && chmod 600 .engine-pass
ovirt-img upload-disk \
  --engine-url https://olvm.mvrc.local \
  --username 'admin@ovirt@internalsso' \
  --password-file .engine-pass \
  --insecure \
  --storage-domain hosted_storage \
  --format qcow2 \
  --name "$VM" \
  $VM.qcow2
rm -f .engine-pass

# 5. criar a VM, anexar o disco e a placa: pela interface do OLVM, ou com
#    os módulos ovirt.ovirt (é o que a role create_vm faz)
```
