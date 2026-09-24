# DNS Zones Module - Provider Requirements
#
# azurerm is constrained to 5.x, and every module uses this same bound.
# Without an upper bound, a fresh init resolves the next major and validation fails.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }
}
