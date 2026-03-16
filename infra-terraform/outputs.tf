output "acr_login_server" {
  description = "The login server URL for the Azure Container Registry"
  value       = azurerm_container_registry.acr.login_server
}

output "aks_cluster_name" {
  description = "The name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "argocd_server_ip" {
  description = "The external IP address of ArgoCD server (LoadBalancer)"
  value       = "Run: kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' to get the LoadBalancer IP"
}

output "argocd_initial_password_instruction" {
  description = "Instructions to retrieve the initial ArgoCD admin password"
  value       = "Run: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode && echo to get the initial admin password"
}

output "aks_kube_config" {
  description = "Configure kubectl to access the AKS cluster"
  value       = "Run: az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} to configure kubectl"
  sensitive   = false
}

output "acr_admin_username" {
  description = "The admin username for ACR"
  value       = azurerm_container_registry.acr.admin_username
  sensitive   = true
}

output "acr_admin_password" {
  description = "The admin password for ACR"
  value       = azurerm_container_registry.acr.admin_password
  sensitive   = true
}

output "acr_pull_role_assignment_command" {
  description = "Command to manually assign AcrPull role if SP lacks permissions"
  value       = "az role assignment create --assignee ${azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id} --scope ${azurerm_container_registry.acr.id} --role AcrPull"
}
