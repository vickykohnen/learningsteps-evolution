# 1. PROVIDERS & DATA
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
}

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

# 3. NETWORKING
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

resource "azurerm_network_security_group" "aks_nsg" {
  name                = "aks-nsg"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
}

resource "azurerm_network_security_rule" "allow_azure_health_probe" {
  name                   = "AllowAzureHealthProbe"
  priority               = 100 # Highest priority
  direction              = "Inbound"
  access                 = "Allow"
  protocol               = "Tcp"
  source_port_range      = "*"
  destination_port_range = "*"
  # This is the magic Azure Infrastructure IP
  source_address_prefix       = "168.63.129.16"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.aks_rg.name
  network_security_group_name = azurerm_network_security_group.aks_nsg.name
}

# --- PORT 80 FIX START ---
resource "azurerm_network_security_rule" "allow_http" {
  name                        = "AllowHTTPInbound"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.aks_rg.name
  network_security_group_name = azurerm_network_security_group.aks_nsg.name
}
# --- PORT 80 FIX END ---

# ... after the allow_http rule ...

resource "azurerm_network_security_rule" "allow_lb" {
  name                        = "AllowAzureLoadBalancerInbound"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.aks_rg.name
  network_security_group_name = azurerm_network_security_group.aks_nsg.name
}



resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks_subnet.id
  network_security_group_id = azurerm_network_security_group.aks_nsg.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db_subnet.id
  network_security_group_id = azurerm_network_security_group.aks_nsg.id
}

resource "azurerm_user_assigned_identity" "kv_identity" {
  name                = "kv-identity"
  resource_group_name = azurerm_resource_group.aks_rg.name
  location            = azurerm_resource_group.aks_rg.location
}

# 4. COMPUTE (AKS Cluster)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "learningsteps-aks"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  dns_prefix          = "learningstepsaks"

  default_node_pool {
    name                         = "system"
    node_count                   = 1
    vm_size                      = "Standard_D4s_v3"
    vnet_subnet_id               = azurerm_subnet.aks_subnet.id
    only_critical_addons_enabled = false
    max_pods                     = 40
    os_disk_type                 = "Managed"
    temporary_name_for_rotation  = "tempnodepool"

    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }
  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.100.0.0/16"
    dns_service_ip = "10.100.0.10"
  }

  identity {
    type = "SystemAssigned"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  # This is for Prometheus 
  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }
}

# 5. SECURITY & MONITORING
resource "azurerm_log_analytics_workspace" "law" {
  name                = "aks-law"
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  sku                 = "PerGB2018"
}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-learningsteps-1769"
  location                   = azurerm_resource_group.aks_rg.location
  resource_group_name        = azurerm_resource_group.aks_rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
}

resource "azurerm_key_vault_access_policy" "user_policy" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = data.azurerm_client_config.current.object_id
  key_permissions    = ["Get", "List", "Create", "Delete", "Update"]
  secret_permissions = ["Get", "List", "Set", "Delete"]
}

resource "azurerm_key_vault_access_policy" "aks_policy" {
  key_vault_id       = azurerm_key_vault.kv.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  secret_permissions = ["Get", "List"]
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "pg-admin-password"
  value        = "P@ssw0rd123!" # Using a placeholder for clarity
  key_vault_id = azurerm_key_vault.kv.id
}

# 6. DATABASE
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

resource "azurerm_postgresql_flexible_server" "db" {
  name                          = "learningsteps-db-server"
  zone                          = 1
  resource_group_name           = azurerm_resource_group.aks_rg.name
  location                      = azurerm_resource_group.aks_rg.location
  version                       = "13"
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.db_subnet.id
  private_dns_zone_id           = azurerm_private_dns_zone.dns.id
  administrator_login           = "psqladmin"
  administrator_password        = azurerm_key_vault_secret.db_password.value
  sku_name                      = "GP_Standard_D2ds_v4"

  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]
}

resource "azurerm_postgresql_flexible_server_database" "app_db" {
  name      = "fastapidb"
  server_id = azurerm_postgresql_flexible_server.db.id
}

# 7. KUBERNETES APP
resource "kubernetes_namespace" "app" {
  metadata { name = "app" }
}

# 1. THE MISSING CONFIGMAP
resource "kubernetes_config_map" "learningsteps_config" {
  metadata {
    name      = "learningsteps-config"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    APP_ENV = "production"
    DB_USER = "fastapiuser"
    DB_NAME = "fastapidb"
    DB_PORT = "5432"
    # METRICS_PORT = "8001"
    # Note: DB_HOST is handled directly in the deployment env block below
  }
}

resource "kubernetes_deployment" "api" {
  metadata {
    name      = "learningsteps-api"
    namespace = "app"
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "learningsteps" } }
    template {
      metadata {
        labels = { app = "learningsteps"
        }
        # This is for Grafana/Prometheus
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8000"
          "prometheus.io/path"   = "/metrics"
        }
      }
      spec {
        container {
          name              = "api"
          image             = "learningstepsregistry20260126.azurecr.io/learningsteps-api:v1"
          image_pull_policy = "Always"
          port { container_port = 8000 }
          # 1. MOUNT THE SECRETS FOLDER
          volume_mount {
            name       = "secrets-store-inline"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }

          env {
            name  = "DB_HOST"
            value = azurerm_postgresql_flexible_server.db.fqdn
          }

          # 2. PULL OTHER CONFIG FROM CONFIGMAP
          env_from {
            config_map_ref {
              name = kubernetes_config_map.learningsteps_config.metadata[0].name
            }
          }
        }

        # 3. DEFINE THE CSI VOLUME SOURCE
        volume {
          name = "secrets-store-inline"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = "azure-keyvault"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_manifest" "azure_keyvault" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "azure-keyvault"
      namespace = "app"
    }
    spec = {
      provider = "azure"
      parameters = {
        useVMManagedIdentity   = "true"
        userAssignedIdentityID = azurerm_kubernetes_cluster.aks.kubelet_identity[0].client_id
        keyvaultName           = azurerm_key_vault.kv.name
        tenantId               = data.azurerm_client_config.current.tenant_id
        objects                = "array:\n  - |\n    objectName: pg-admin-password\n    objectType: secret\n"
      }
    }
  }
}