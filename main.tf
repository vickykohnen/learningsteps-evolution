# 1. PROVIDERS & DATA
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Fetches your current Azure login details (Tenant, Subscription, etc.)
data "azurerm_client_config" "current" {}

# 2. SHARED INFRASTRUCTURE

resource "azurerm_resource_group" "aks_rg" {
  name     = "learningstepsRG"
  location = "northeurope"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "learningsteps-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
}

# 3. NETWORKING (Subnets)
resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.aks_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "db_subnet" {
  name                 = "db-subnet"
  resource_group_name  = azurerm_resource_group.aks_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
  delegation {
    name = "fs"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# 4. COMPUTE (AKS Cluster)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "learningsteps-aks"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  dns_prefix          = "learningstepsaks"

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = "Standard_D2s_v3"
    vnet_subnet_id = azurerm_subnet.aks_subnet.id
  }

  network_profile {
    network_plugin     = "azure"
    service_cidr       = "10.100.0.0/16" # Non-overlapping range
    dns_service_ip     = "10.100.0.10"   # Must be within the service_cidr range
  }

  identity {
    type = "SystemAssigned"
  }
}

# 5. SECURITY (Key Vault & Permissions)
resource "azurerm_key_vault" "kv" {
  name                = "kv-learningsteps-1769" # Must be globally unique
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Access Policy: Allows YOU (the person running Terraform) to add secrets
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
  }
}

resource "azurerm_key_vault_access_policy" "aks_policy" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id

  secret_permissions = ["Get", "List"]
}

resource "random_password" "db_pass" {
  length  = 20
  special = true
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "pg-admin-password"
  value        = random_password.db_pass.result
  key_vault_id = azurerm_key_vault.kv.id
}

# 6. DATABASE NETWORKING (Private DNS)
resource "azurerm_private_dns_zone" "dns" {
  name                = "learningsteps.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.aks_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "db-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.aks_rg.name
}

# 7. DATA (PostgreSQL Flexible Server)
resource "azurerm_postgresql_flexible_server" "db" {
  name                   = "learningsteps-db-server"
  resource_group_name    = azurerm_resource_group.aks_rg.name
  location               = azurerm_resource_group.aks_rg.location
  zone                   = "1"
  version                = "13"
  delegated_subnet_id    = azurerm_subnet.db_subnet.id
  private_dns_zone_id    = azurerm_private_dns_zone.dns.id
  administrator_login    = "psqladmin"
  administrator_password = azurerm_key_vault_secret.db_password.value
  storage_mb             = 32768
  sku_name               = "GP_Standard_D2ds_v4"
  public_network_access_enabled = false
  
  # Ensure DNS link is ready BEFORE creating the DB
  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]
}