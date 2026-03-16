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

  values = [
    yamlencode({
      server = {
        service = {
          type = "LoadBalancer"
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.argocd, azurerm_kubernetes_cluster.aks]
}

# Apply ArgoCD Application for Keycloak using kubectl
resource "null_resource" "keycloak_app" {
  triggers = {
    repo_url = var.gitops_repo_url
  }

  provisioner "local-exec" {
    command = <<EOT
      az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing
      
      cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${var.gitops_repo_url}
    targetRevision: HEAD
    path: keycloak-gitops
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
    EOT
  }

  depends_on = [helm_release.argocd]
}
