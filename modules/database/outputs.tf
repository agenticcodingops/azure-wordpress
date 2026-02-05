# Database Module Outputs
# These outputs are consumed by App Service and monitoring modules

output "server_id" {
  description = "ID of the MySQL Flexible Server"
  value       = azurerm_mysql_flexible_server.main.id
}

output "server_name" {
  description = "Name of the MySQL Flexible Server"
  value       = azurerm_mysql_flexible_server.main.name
}

output "server_fqdn" {
  description = "FQDN of the MySQL Flexible Server"
  value       = azurerm_mysql_flexible_server.main.fqdn
}

output "database_name" {
  description = "Name of the WordPress database"
  value       = azurerm_mysql_flexible_database.wordpress.name
}

output "admin_username" {
  description = "MySQL admin username"
  value       = azurerm_mysql_flexible_server.main.administrator_login
  sensitive   = true
}
