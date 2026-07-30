##############################################################################
# modules/ovirt_vm/versions.tf
#
# Um módulo declara os providers que usa. O `null` só é exercitado quando
# firmware_apply_via_api = true (veja o comentário em main.tf) — mas precisa
# estar declarado para o Terraform resolver as dependências.
##############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    ovirt = {
      source  = "oVirt/ovirt"
      version = "~> 2.2"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
