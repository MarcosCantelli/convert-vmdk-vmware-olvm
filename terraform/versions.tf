##############################################################################
# versions.tf — versões de Terraform e providers.
#
# ESCOLHA DO PROVIDER (pesquisado, não assumido):
#   Usamos `oVirt/ovirt`, mantido pela própria organização oVirt no GitHub
#   (github.com/oVirt/terraform-provider-ovirt). É a reescrita v2, baseada na
#   biblioteca go-ovirt-client. Última versão verificada: 2.2.0 (dez/2025).
#
#   Providers ANTIGOS que você vai encontrar em tutoriais e NÃO deve usar:
#     - imjoey/ovirt      -> fork histórico
#     - EMSL-MSC/ovirt    -> origem do projeto, arquivado para referência
#
# Pinamos com `~> 2.2`: aceita 2.2.x (correções), recusa 3.x (que poderia
# mudar nomes de atributos sem aviso).
##############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    ovirt = {
      source  = "oVirt/ovirt"
      version = "~> 2.2"
    }
  }
}
