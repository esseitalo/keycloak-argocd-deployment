terraform {
  required_version = ">= 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  }
}

# Random suffix for resource names
resource "random_string" "acr_suffix" {
  length  = 6
  special = false
  lower   = true
}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Container Registry (ACR)
resource "azurerm_container_registry" "acr" {
  name                = "acr${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true

  depends_on = [azurerm_resource_group.rg]
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-aks-keycloak-poc"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Subnet for AKS
resource "azurerm_subnet" "aks_subnet" {
  name                 = "subnet-aks"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Subnet for Jumpbox
resource "azurerm_subnet" "jumpbox_subnet" {
  name                 = "subnet-jumpbox"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Public IP for Jumpbox
resource "azurerm_public_ip" "jumpbox_pip" {
  name                = "pip-jumpbox"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Dynamic"
  sku                 = "Basic"
}

# Network Security Group for Jumpbox
resource "azurerm_network_security_group" "jumpbox_nsg" {
  name                = "nsg-jumpbox"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Network Interface for Jumpbox
resource "azurerm_network_interface" "jumpbox_nic" {
  name                = "nic-jumpbox"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jumpbox_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox_pip.id
  }
}

# Associate NSG to NIC
resource "azurerm_network_interface_security_group_association" "jumpbox_nic_nsg" {
  network_interface_id      = azurerm_network_interface.jumpbox_nic.id
  network_security_group_id = azurerm_network_security_group.jumpbox_nsg.id
}

# Random Password for Jumpbox User
resource "random_password" "jumpbox_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Jumpbox VM
resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "vm-jumpbox"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = "Standard_B1s"
  admin_username                  = "adminuser"
  admin_password                  = random_password.jumpbox_password.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.jumpbox_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
              #!/bin/bash
              # Update and install dependencies
              apt-get update
              apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg

              # Install Azure CLI
              mkdir -p /etc/apt/keyrings
              curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
              chmod go+r /etc/apt/keyrings/microsoft.gpg
              echo "deb [arch=`dpkg --print-architecture` signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azure-cli.list
              apt-get update
              apt-get install -y azure-cli

              # Install Kubectl
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

              # Install Helm
              curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
              echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | tee /etc/apt/sources.list.d/helm-stable-debian.list
              apt-get update
              apt-get install -y helm

              # Install Docker
              apt-get install -y docker.io
              usermod -aG docker adminuser
              EOF
  )
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {

  name                = "aks-keycloak-poc"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "aks-keycloak-poc"
  kubernetes_version  = "1.32"
  sku_tier            = "Free"

  default_node_pool {
    name            = "systempool"
    node_count      = 2
    vm_size         = "Standard_DC2ads_v5"
    os_disk_size_gb = 30
    vnet_subnet_id  = azurerm_subnet.aks_subnet.id
  }

  network_profile {
    network_plugin     = "azure"
    network_policy     = "azure"
    dns_service_ip     = "10.1.0.10"
    service_cidr       = "10.1.0.0/16"
  }

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_resource_group.rg, azurerm_subnet.aks_subnet]
}

# Role Assignment: AKS to pull images from ACR
# NOTE: This resource requires the Service Principal to have 'User Access Administrator' or 'Owner' role.
# If using 'Contributor', this will fail. We are commenting it out to allow the pipeline to succeed.
# You must run the command outputted by 'acr_pull_role_assignment_command' manually.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope              = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id       = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

# Kubernetes Namespace for ArgoCD
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [azurerm_kubernetes_cluster.aks]
}

# Helm Release: ArgoCD
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "5.46.8"
  timeout    = 900 # Increase timeout to 15m to avoid context deadline exceeded

  values = [
    yamlencode({
      server = {
        service = {
          type = "LoadBalancer"
        }
      }
      # Define the Application as an extra object managed by Helm
      extraObjects = [
        {
          apiVersion = "argoproj.io/v1alpha1"
          kind       = "Application"
          metadata = {
            name      = "keycloak"
            namespace = "argocd"
          }
          spec = {
            project = "default"
            source = {
              repoURL        = var.gitops_repo_url
              targetRevision = "HEAD"
              path           = "keycloak-gitops"
            }
            destination = {
              server    = "https://kubernetes.default.svc"
              namespace = "default"
            }
            syncPolicy = {
              automated = {
                prune    = true
                selfHeal = true
              }
            }
          }
        }
      ]
    })
  ]

  depends_on = [kubernetes_namespace.argocd, azurerm_kubernetes_cluster.aks]
}

# Apply ArgoCD Application for Keycloak using kubectl
# resource "null_resource" "keycloak_app" {
#   triggers = {
#     repo_url = var.gitops_repo_url
#   }
# 
#   provisioner "local-exec" {
#     command = <<EOT
#       az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing
#       
#       cat <<EOF | kubectl apply -f -
# apiVersion: argoproj.io/v1alpha1
# kind: Application
# metadata:
#   name: keycloak
#   namespace: argocd
# spec:
#   project: default
#   source:
#     repoURL: ${var.gitops_repo_url}
#     targetRevision: HEAD
#     path: keycloak-gitops
#   destination:
#     server: https://kubernetes.default.svc
#     namespace: default
#   syncPolicy:
#     automated:
#       prune: true
#       selfHeal: true
# EOF
#     EOT
#   }
# 
#   depends_on = [helm_release.argocd]
# }
