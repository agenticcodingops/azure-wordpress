# Key Vault Module - Provider Requirements
#
# azurerm is constrained to 4.x: this module uses arguments that azurerm 5.x
# renamed or removed. Without a constraint, a fresh 'terraform init' resolves
# the latest major and validation fails.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.2"
    }
  }
}
