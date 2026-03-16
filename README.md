# AKS Keycloak ArgoCD PoC (GitHub Migration)

This project contains the code for a Proof of Concept (PoC) deployment of Keycloak on Azure Kubernetes Service (AKS) using ArgoCD and GitHub Actions.

## Repository Structure

The project is structured as a monorepo containing:

1.  `infra-terraform/`: Infrastructure as Code (Terraform) to provision AKS, ACR, and ArgoCD.
2.  `keycloak-custom-image/`: Dockerfile to build a custom Keycloak image.
3.  `keycloak-gitops/`: Helm chart/Kubernetes manifests for Keycloak, managed by ArgoCD.

## Prerequisites

1.  **Azure Subscription**: You need an active subscription.
2.  **Azure Service Principal**: Create a Service Principal for GitHub Actions to authenticate with Azure.
    ```bash
    az ad sp create-for-rbac --name "github-actions-sp" --role "Owner" --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID> --sdk-auth
    ```
    **Important**: The `--role "Owner"` or `"User Access Administrator"` is required for Terraform to assign the `AcrPull` role automatically. If you use `Contributor`, the pipeline will succeed but the role assignment step will be skipped (you must run the command outputted by Terraform manually).
    
    Save the JSON output. This will be used as the `AZURE_CREDENTIALS` secret.

3.  **Terraform Backend (Azure Storage)**: Create a Storage Account to store the Terraform state.
    ```bash
    # Create Resource Group for State
    az group create --name rg-terraform-state --location eastus

    # Create Storage Account (name must be unique)
    az storage account create --name tfstate<unique_suffix> --resource-group rg-terraform-state --sku Standard_LRS

    # Create Container
    az storage container create --name tfstate --account-name tfstate<unique_suffix>
    ```

## GitHub Repository Setup

1.  **Secrets**: Go to your GitHub Repository > Settings > Secrets and variables > Actions > New repository secret. Add the following:

    | Secret Name | Value | Description |
    | :--- | :--- | :--- |
    | `AZURE_CREDENTIALS` | JSON output from step 2 | Full Service Principal JSON |
    | `AZURE_CLIENT_ID` | `clientId` from JSON | SP Client ID |
    | `AZURE_CLIENT_SECRET` | `clientSecret` from JSON | SP Client Secret |
    | `AZURE_SUBSCRIPTION_ID` | `subscriptionId` from JSON | Azure Subscription ID |
    | `AZURE_TENANT_ID` | `tenantId` from JSON | Azure Tenant ID |
    | `TF_BACKEND_RG` | `rg-terraform-state` | Resource Group for TF State |
    | `TF_BACKEND_SA` | `tfstate<unique_suffix>` | Storage Account Name for TF State |
    | `TF_BACKEND_CONTAINER` | `tfstate` | Container Name for TF State |

2.  **ACR Secrets (After First Run)**:
    - Run the **Infrastructure - Terraform** workflow first. It will create the ACR.
    - Retrieve the ACR credentials from the Terraform output or Azure Portal.
    - Add these additional secrets:
        - `ACR_LOGIN_SERVER`: e.g., `acr<random>.azurecr.io`
        - `ACR_USERNAME`: e.g., `acr<random>`
        - `ACR_PASSWORD`: ACR Admin Password

## Workflows

### 1. Infrastructure (infra-terraform)
- Triggers on changes to `infra-terraform/`.
- Provisions AKS, ACR, and ArgoCD.
- **First Run**: Manually trigger this workflow or push a change to `infra-terraform/`.
- **Note**: After the first successful run, get the ACR credentials and add them to GitHub Secrets (see above).
- **Terraform Output**: To see sensitive outputs like ACR password, run:
  ```bash
  terraform output -raw acr_admin_password
  ```

### 2. Keycloak Custom Image (keycloak-image)
- Triggers on changes to `keycloak-custom-image/`.
- Builds the Docker image and pushes it to the ACR created by Terraform.
- Automatically updates `keycloak-gitops/values.yaml` with the new image tag and repository.
- Commits and pushes the change back to the repository.
- ArgoCD (running in the cluster) detects the change and syncs Keycloak.

## Accessing the Environment

1.  **ArgoCD UI**:
    - Get the IP: `kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
    - Get Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
    - User: `admin`

2.  **Keycloak**:
    - Once synced, get the Keycloak IP: `kubectl get svc keycloak-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
    - Login with `admin` / `password123` (from values.yaml).
