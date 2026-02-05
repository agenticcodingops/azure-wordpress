# Monitoring Module Outputs
# These outputs are consumed by App Service and Key Vault modules

output "app_insights_id" {
  description = "ID of the Application Insights instance"
  value       = azurerm_application_insights.main.id
}

output "app_insights_name" {
  description = "Name of the Application Insights instance"
  value       = azurerm_application_insights.main.name
}

output "instrumentation_key" {
  description = "Instrumentation key for Application Insights"
  value       = azurerm_application_insights.main.instrumentation_key
  sensitive   = true
}

output "connection_string" {
  description = "Connection string for Application Insights"
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "log_analytics_workspace_id" {
  description = "ID of the Log Analytics Workspace"
  value       = local.workspace_id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace"
  value       = local.create_workspace ? azurerm_log_analytics_workspace.main[0].name : null
}

output "action_group_id" {
  description = "ID of the alert action group"
  value       = length(var.alert_recipients) > 0 ? azurerm_monitor_action_group.main[0].id : null
}
