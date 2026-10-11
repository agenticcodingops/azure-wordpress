# Database Module - Provider Requirements
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
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0, < 4.0"
    }
    # The same bound as modules/wordpress-site: Terraform intersects the two, so they must agree.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0, < 1.0"
    }
  }
}
