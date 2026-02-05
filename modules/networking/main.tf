# Networking Module - Layer 1 Foundation
# Creates VNet, Subnets, and NSGs for WordPress site isolation
# MUST complete before Layer 2 modules can deploy

locals {
  # Short environment suffix for naming
  env_suffix = var.environment == "nonprod" ? "np" : "prod"

  # Resource naming following convention: {type}-{project}-{site}-{env}
  name_prefix = "${var.project_name}-${var.site_name}-${local.env_suffix}"
}

# Virtual Network - isolated per site
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_address_space]

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# App Service Integration Subnet
# Delegated to Microsoft.Web/serverFarms for VNet integration
resource "azurerm_subnet" "app" {
  name                 = "snet-app-${var.site_name}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.app_subnet_cidr]

  delegation {
    name = "appservice-delegation"

    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }

  # Required for App Service VNet integration
  service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

# Database Subnet
# Delegated to MySQL Flexible Server
resource "azurerm_subnet" "db" {
  name                 = "snet-db-${var.site_name}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.db_subnet_cidr]

  delegation {
    name = "mysql-delegation"

    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# Private Endpoint Subnet
# For Storage and Key Vault private endpoints
resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-pe-${var.site_name}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_endpoint_subnet_cidr]

  # Private endpoint network policies must be disabled
  private_endpoint_network_policies = "Disabled"
}

# Network Security Group for App Service Subnet
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Allow HTTPS inbound (from Front Door)
  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = "*"
  }

  # Allow App Service management
  security_rule {
    name                       = "AllowAppServiceManagement"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AppServiceManagement"
    destination_address_prefix = "*"
  }

  # Deny all other inbound
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Network Security Group for Database Subnet
resource "azurerm_network_security_group" "db" {
  name                = "nsg-db-${local.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # Allow MySQL from App subnet only
  security_rule {
    name                       = "AllowMySQLFromApp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = var.app_subnet_cidr
    destination_address_prefix = "*"
  }

  # Deny all other inbound
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = merge(var.tags, {
    Site = var.site_name
  })
}

# Associate NSG with App subnet
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

# Associate NSG with Database subnet
resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}
