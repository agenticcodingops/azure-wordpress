# Multi-Site Example Variables

variable "project_name" {
  description = "Project name for resource naming (2-12 lowercase chars)"
  type        = string
}

variable "environment" {
  description = "Environment (nonprod or production)"
  type        = string
  default     = "nonprod"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "app_service_sku" {
  description = "App Service Plan SKU (shared across all sites)"
  type        = string
  default     = "B1"
}

# Azure
variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

# Cloudflare
variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "cloudflare_domain" {
  description = "Root domain registered in Cloudflare"
  type        = string
}

# Sites configuration
variable "sites" {
  description = "Map of WordPress sites to deploy"
  type = map(object({
    custom_domain       = string
    subdomain           = string
    database_sku        = optional(string, "B_Standard_B2s")
    database_storage_gb = optional(number, 100)
  }))
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
