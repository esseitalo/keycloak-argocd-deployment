variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-aks-keycloak-poc"
}

variable "gitops_repo_url" {
  description = "URL of the GitHub repository containing the Keycloak GitOps manifests"
  type        = string
}
