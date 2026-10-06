# Mirror of auto-code-scanning b993fed321e8a01b781abcfd894f02c8d3c2cffa configs/azure/.tflint.hcl. CI uses the canonical copy; update this when terraform-scan.yml's ref changes. The manual-run commands below are the only edit: they point at this root copy.
# ============================================================================
# TFLINT CONFIGURATION - AZURE
# auto-code-scanning
#
# tflint with Azure ruleset for Terraform
#
# Manual run (from the repository root; --recursive resolves a relative --config
# against each module, so pass an absolute path):
#   tflint --recursive --config="$(pwd)/.tflint.hcl"
#
# Initialize plugins:
#   tflint --init --config="$(pwd)/.tflint.hcl"
#
# Documentation:
#   https://github.com/terraform-linters/tflint
#   https://github.com/terraform-linters/tflint-ruleset-azurerm
# ============================================================================

config {
  call_module_type = "local"
  force = false
}

# ============================================================================
# TERRAFORM PLUGIN (shared across all providers)
# Provides general Terraform best practice rules
# ============================================================================
plugin "terraform" {
  enabled = true
  version = "0.15.0"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}

# ============================================================================
# AZURE PLUGIN
# Provides Azure-specific rules and best practices
# ============================================================================
plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# ============================================================================
# TERRAFORM RULES - Best Practices
# ============================================================================

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_standard_module_structure" {
  enabled = true
}

rule "terraform_workspace_remote" {
  enabled = true
}
