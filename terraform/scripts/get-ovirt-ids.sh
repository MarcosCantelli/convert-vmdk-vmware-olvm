#!/usr/bin/env bash
##############################################################################
# get-ovirt-ids.sh — descobre os UUIDs que o Terraform precisa.
#
# POR QUE ESTE SCRIPT EXISTE: o provider oVirt 2.2.0 não tem data sources para
# procurar cluster, storage domain ou perfil de vNIC pelo NOME. Ele só aceita
# UUID. Este script consulta a API REST do engine e imprime os IDs prontos
# para colar no terraform.tfvars.
#
# Uso:
#   export OVIRT_PASSWORD='...'
#   ./scripts/get-ovirt-ids.sh
#
# Variáveis de ambiente aceitas:
#   OVIRT_URL       (default https://olvm.mvrc.local/ovirt-engine/api)
#   OVIRT_USERNAME  (default admin@ovirt@internalsso)
#   OVIRT_PASSWORD  (obrigatória)
#   OVIRT_INSECURE  (default true — certificado do engine sem FQDN no SAN)
#
# Somente leitura: faz apenas GET na API.
##############################################################################

set -euo pipefail

OVIRT_URL="${OVIRT_URL:-https://olvm.mvrc.local/ovirt-engine/api}"
OVIRT_USERNAME="${OVIRT_USERNAME:-admin@ovirt@internalsso}"
OVIRT_INSECURE="${OVIRT_INSECURE:-true}"

if [[ -z "${OVIRT_PASSWORD:-}" ]]; then
  echo "ERRO: exporte OVIRT_PASSWORD antes de rodar." >&2
  echo "  export OVIRT_PASSWORD='...'" >&2
  exit 1
fi

for tool in curl python3; do
  command -v "$tool" >/dev/null || { echo "ERRO: '$tool' não encontrado." >&2; exit 1; }
done

CURL_TLS_OPT=()
if [[ "$OVIRT_INSECURE" == "true" ]]; then
  CURL_TLS_OPT+=("-k")
fi

# GET na API pedindo JSON. A senha vai via --user, lida de variável de
# ambiente — não é escrita em arquivo nem fica no histórico do shell.
api_get() {
  local path="$1"
  # --fail (e não --fail-with-body) para funcionar também no curl 7.61 do
  # Oracle Linux 8, que não tem a opção mais nova.
  curl -sS --fail "${CURL_TLS_OPT[@]}" \
    --user "${OVIRT_USERNAME}:${OVIRT_PASSWORD}" \
    -H "Accept: application/json" \
    "${OVIRT_URL%/}/${path}"
}

# Extrai "nome -> id" de uma coleção do JSON da API.
print_collection() {
  local titulo="$1" path="$2" chave="$3" extra="${4:-}"
  echo
  echo "== ${titulo} =="
  api_get "$path" | python3 -c "
import json, sys
dados = json.load(sys.stdin)
itens = dados.get('$chave') or []
if isinstance(itens, dict):
    itens = [itens]
if not itens:
    print('  (nenhum encontrado)')
for i in itens:
    nome = i.get('name', '?')
    extra = '$extra'
    detalhe = ''
    if extra and extra in i:
        valor = i[extra]
        detalhe = f\"  [{extra}={valor}]\"
    print(f\"  {nome:<40} {i.get('id','?')}{detalhe}\")
"
}

echo "Engine:  $OVIRT_URL"
echo "Usuário: $OVIRT_USERNAME"

print_collection "DATACENTERS" "datacenters" "data_center"
print_collection "CLUSTERS  (-> cluster_id)" "clusters" "cluster"
print_collection "STORAGE DOMAINS  (-> storage_domain_id)" "storagedomains" "storage_domain" "type"
print_collection "PERFIS DE vNIC  (-> vnic_profile_id)" "vnicprofiles" "vnic_profile"
print_collection "TEMPLATES  (-> template_id)" "templates" "template"
print_collection "REDES" "networks" "network"

cat <<'EOF'

----------------------------------------------------------------------------
Copie os UUIDs para terraform/terraform.tfvars:

  cluster_id        = "<UUID do cluster Default>"
  storage_domain_id = "<UUID do hosted_storage>"
  vnic_profile_id   = "<UUID do perfil da rede ovirtmgmt>"

Dica: o template "Blank" aparece na lista de templates, mas você NÃO precisa
do ID dele — o módulo descobre sozinho quando template_id fica ausente.
----------------------------------------------------------------------------
EOF
