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
    network_plugin = "azure"
    service_cidr   = "10.100.0.0/16" # Non-overlapping range
    dns_service_ip = "10.100.0.10"   # Must be within the service_cidr range
  }

  identity {
    type = "SystemAssigned"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }
}

# 5. SECURITY (Key Vault & Permissions)
# Key Vault
resource "azurerm_key_vault" "kv" {
  name                = "kv-learningsteps-1769" # Must be globally unique
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

# Personal Access Policy - Allows YOU (the person running Terraform) to add secrets
resource "azurerm_key_vault_access_policy" "user_policy" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = ["Get", "List", "Set", "Delete", "Purge"]
}

# The AKS Kubelet Access Policy
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
  name                          = "learningsteps-db-server"
  resource_group_name           = azurerm_resource_group.aks_rg.name
  location                      = azurerm_resource_group.aks_rg.location
  zone                          = "1"
  version                       = "13"
  delegated_subnet_id           = azurerm_subnet.db_subnet.id
  private_dns_zone_id           = azurerm_private_dns_zone.dns.id
  administrator_login           = "psqladmin"
  administrator_password        = azurerm_key_vault_secret.db_password.value
  storage_mb                    = 32768
  sku_name                      = "GP_Standard_D2ds_v4"
  public_network_access_enabled = false

  # Ensure DNS link is ready BEFORE creating the DB
  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]
}

# 8. Create the database in the Flexible Server
resource "azurerm_postgresql_flexible_server_database" "app_db" {
  name      = "fastapidb"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  # Optional: collation
  # collation = "English_United States.1252"

  depends_on = [
    azurerm_postgresql_flexible_server.db
  ]
}

# 9. Kubernetes Deployment
resource "kubernetes_deployment" "api" {
  metadata {
    name = "learningsteps-api"
  }
  spec {
    replicas = 2
    selector {
      match_labels = {
        app = "learningsteps"
      }
    }
    template {
      metadata {
        labels = {
          app = "learningsteps"
        }
      }
      spec {
        # INIT Container: ensure the app user exists
        init_container {
          name  = "init-db-user"
          image = "postgres:13"

          # This command runs the script mounted from the ConfigMap
          command = ["/bin/bash", "-c"]
          args = [
            <<-EOT
            PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
            DO \$\$ 
            BEGIN 
              -- 1. Create the application user if it doesn't exist
              IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'fastapiuser') THEN
                CREATE USER fastapiuser WITH PASSWORD 'pass123';
              END IF;
              
              -- 2. Grant Permissions
              GRANT ALL PRIVILEGES ON DATABASE fastapidb TO fastapiuser;
              GRANT USAGE ON SCHEMA public TO fastapiuser;
              GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO fastapiuser;
              GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO fastapiuser;
            END \$\$;
            "
            # 3. Run your table creation script from the ConfigMap
            PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f /scripts/init.sql
            EOT
          ]

          env {
            name  = "DB_HOST"
            value = azurerm_postgresql_flexible_server.db.fqdn
          }
          env {
            name  = "DB_USER"
            value = "psqladmin"
          }
          env {
            name  = "DB_NAME"
            value = "fastapidb"
          }
          env {
            name  = "DB_PASSWORD"
            value = azurerm_key_vault_secret.db_password.value
          }

          volume_mount {
            name       = "db-init-volume"
            mount_path = "/scripts"
          }
        }

        # MAIN FastAPI Container
        container {
          name  = "api"
          image = "learningstepsregistry20260126.azurecr.io/learningsteps-api:v1"

          env {
            name  = "PYTHONUNBUFFERED"
            value = "1"
          }

          env {
            name  = "DB_HOST"
            value = azurerm_postgresql_flexible_server.db.fqdn
          }
          env {
            name  = "DB_USER"
            value = "psqladmin" # Flexible server doesn't use the @server suffix!
          }
          env {
            name  = "DB_NAME"
            value = "postgres"
          }

          port {
            container_port = 8000
          }

          volume_mount {
            name       = "secrets-store-inline"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }
        }

        # Volume for the SQL Script ConfigMap
        volume {
          name = "db-init-volume"
          config_map {
            name = kubernetes_config_map.db_init_script.metadata[0].name
          }
        }

        # Volumne for Key Vault Secrets
        volume {
          name = "secrets-store-inline"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              "secretProviderClass" = "azure-kv-secrets"
            }
          }
        }
      }
    }
  }
}

# 11 DB Init Script
resource "kubernetes_config_map" "db_init_script" {
  metadata {
    name = "db-init-script"
  }

  data = {
    "init.sql" = <<EOF
      CREATE TABLE IF NOT EXISTS entries (
          id SERIAL PRIMARY KEY,
          title TEXT NOT NULL,
          content TEXT,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    EOF
  }
}