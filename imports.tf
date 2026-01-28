# Import the Resource Group (You likely have this already)
import {
  to = azurerm_resource_group.aks_rg
  id = "/subscriptions/a2c41e5d-454d-4c0b-9f7a-2260d54011e7/resourceGroups/learningstepsRG"
  # id = "/subscriptions/${var.subscription_id}/resourceGroups/learningstepsRG"
}

import {
  to = azurerm_key_vault_secret.db_password
  id = "https://kv-learningsteps-1769.vault.azure.net/secrets/pg-admin-password/9b307dbf14b74ff6a0378c74c57d2c7d"
}

import {
  to = azurerm_postgresql_flexible_server.db
  id = "/subscriptions/a2c41e5d-454d-4c0b-9f7a-2260d54011e7/resourceGroups/learningstepsRG/providers/Microsoft.DBforPostgreSQL/flexibleServers/learningsteps-db-server"
  # id = "/subscriptions/${var.subscription_id}/resourceGroups/learningstepsRG/providers/Microsoft.DBforPostgreSQL/flexibleServers/learningsteps-db-server" 
}

# import {
#  to = azurerm_container_registry.acr
#  id = "/subscriptions/a2c41e5d-454d-4c0b-9f7a-2260d54011e7/resourceGroups/aks_rg/providers/Microsoft.ContainerRegistry/registries/learningstepsregistry20260126"
#  # id = "/subscriptions/${var.subscription_id}/resourceGroups/aks_rg/providers/Microsoft.ContainerRegistry/registries/learningstepsregistry20260126"
# }