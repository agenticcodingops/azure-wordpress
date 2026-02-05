# DNS Zones Module - Layer 1 Foundation
# Creates Private DNS Zones for MySQL Flexible Server
# MUST complete before Layer 2 Database module can deploy

# Private DNS Zone for MySQL Flexible Server
# Zone name is fixed by Azure - privatelink.mysql.database.azure.com
resource "azurerm_private_dns_zone" "mysql" {
  name                = "privatelink.mysql.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Link Private DNS Zone to VNet
# This enables name resolution for MySQL within the VNet
resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "link-mysql-${var.site_name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false

  tags = merge(var.tags, {
    Site = var.site_name
  })
}
