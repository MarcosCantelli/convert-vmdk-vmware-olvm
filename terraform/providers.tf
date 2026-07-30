##############################################################################
# providers.tf — conexão com o engine OLVM.
#
# SEGREDOS: a senha NUNCA é escrita aqui. Ela chega por variável de ambiente:
#   export TF_VAR_ovirt_password='...'
# ou por um arquivo .tfvars local (que está no .gitignore).
#
# TLS: o provider EXIGE exatamente uma estratégia de verificação de
# certificado. Como o certificado do engine não traz o FQDN no SAN, a
# verificação de hostname falha e usamos tls_insecure = true nesta fase.
# Quando o certificado for corrigido, troque para tls_ca_files apontando para
# o CA do engine — as duas opções são MUTUAMENTE EXCLUSIVAS no provider.
#
# Como baixar o CA do engine (para o dia em que endurecer isto):
#   curl -k -o ovirt-ca.pem \
#     'https://olvm.mvrc.local/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA'
##############################################################################

provider "ovirt" {
  # Precisa terminar em /ovirt-engine/api/ — não é a URL da interface web.
  url = var.ovirt_url

  # Com Keycloak (OLVM/oVirt 4.5+) o usuário tem dois "@":
  #   admin@ovirt@internalsso
  username = var.ovirt_username
  password = var.ovirt_password

  # --- Estratégia TLS: escolha UMA ---------------------------------------
  # Fase atual: certificado sem FQDN no SAN.
  tls_insecure = var.ovirt_tls_insecure

  # Depois de corrigir o certificado, comente a linha acima e descomente:
  # tls_ca_files = var.ovirt_tls_ca_files

  # Modo simulação do próprio provider: executa tudo em memória, sem tocar no
  # engine. Serve para validar o código (terraform plan) em CI ou na sua
  # máquina, sem OLVM à mão. NUNCA use em produção — o estado é descartado.
  #   terraform plan -var ovirt_mock=true
  mock = var.ovirt_mock
}
