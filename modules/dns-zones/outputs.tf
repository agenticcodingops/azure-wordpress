# DNS Zones Module Outputs
# These outputs are consumed by Layer 2 Database module

output "mysql_dns_zone_id" {
  description = "ID of the MySQL private DNS zone"
  value       = azurerm_private_dns_zone.mysql.id
}

output "mysql_dns_zone_name" {
  description = "Name of the MySQL private DNS zone"
  value       = azurerm_private_dns_zone.mysql.name
}

output "mysql_dns_zone_link_id" {
  description = "ID of the VNet link to MySQL DNS zone"
  value       = azurerm_private_dns_zone_virtual_network_link.mysql.id
}
