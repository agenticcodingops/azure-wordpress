# Basic Site Example Variables

variable "project_name" {
  description = "Project name for resource naming (2-12 lowercase chars)"
  type        = string
  default     = "myproject"
}

variable "site_name" {
  description = "Site name for resource naming"
  type        = string
  default     = "blog"
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

variable "custom_domain" {
  description = "Custom domain for the site"
  type        = string
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

variable "cloudflare_subdomain" {
  description = "Subdomain for the site (empty for apex domain)"
  type        = string
  default     = ""
}
