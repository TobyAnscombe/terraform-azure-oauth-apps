#!/usr/bin/env bash
# bootstrap-ci-runner.sh
#
# One-time setup: creates the GitHub Actions service principal that Terraform
# CI uses to authenticate to Azure via OIDC. Run this once from a machine with
# az CLI access and Owner/Application Administrator rights on the tenant.
#
# After this runs, add the three AZURE_* values as GitHub Actions variables
# (not secrets) in your repository settings.

set -euo pipefail

DISPLAY_NAME="${1:-svc-terraform-ci-runner}"
REPO="${2:-TobyAnscombe/terraform-azure-oauth-apps}"  # format: org/repo
SUBSCRIPTION_ID="${3:-$(az account show --query id -o tsv)}"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo "Creating app registration: ${DISPLAY_NAME}"
APP_ID=$(az ad app create --display-name "${DISPLAY_NAME}" --query appId -o tsv)
echo "  application_id = ${APP_ID}"

echo "Creating service principal"
SP_OBJECT_ID=$(az ad sp create --id "${APP_ID}" --query id -o tsv)
echo "  service_principal_object_id = ${SP_OBJECT_ID}"

echo "Assigning Contributor role on subscription ${SUBSCRIPTION_ID}"
az role assignment create \
  --assignee "${APP_ID}" \
  --role "Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" \
  --output none

echo "Granting Application.ReadWrite.OwnedBy permission (allows managing owned app registrations)"
# Application.ReadWrite.OwnedBy: 18a4783c-866b-4cc7-a460-3d5e5662c884
az ad app permission add \
  --id "${APP_ID}" \
  --api "00000003-0000-0000-c000-000000000002" \
  --api-permissions "18a4783c-866b-4cc7-a460-3d5e5662c884=Role" \
  --output none

echo "Granting admin consent"
az ad app permission admin-consent --id "${APP_ID}" --output none

echo "Adding federated credential for main branch"
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"github-actions-main\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" \
  --output none

echo "Adding federated credential for sandpit branch"
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"github-actions-sandpit\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:ref:refs/heads/sandpit\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" \
  --output none

echo "Adding federated credential for pull requests"
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"github-actions-pr\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:pull_request\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" \
  --output none

echo ""
echo "Bootstrap complete. Add the following as GitHub Actions repository variables:"
echo "  AZURE_CLIENT_ID       = ${APP_ID}"
echo "  AZURE_TENANT_ID       = ${TENANT_ID}"
echo "  AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "NOTE: Application.ReadWrite.OwnedBy means this CI runner can only manage"
echo "app registrations it owns. The app_owners variable in tfvars must include"
echo "the object ID of this service principal (${SP_OBJECT_ID}) or use"
echo "Application.ReadWrite.All if broader access is required."
