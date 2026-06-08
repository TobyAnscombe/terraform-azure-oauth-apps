#!/usr/bin/env bash
# create-state-backend.sh
#
# Creates the Azure Storage Account used as the Terraform state backend.
# Run once before the first terraform init. Idempotent — safe to re-run.
#
# Usage:
#   ./create-state-backend.sh \
#     --resource-group rg-terraform-state \
#     --storage-account stterraformstate \
#     --location "UK South" \
#     [--subscription 00000000-0000-0000-0000-000000000000] \
#     [--containers oauth-apps-sandpit,oauth-apps-prod] \
#     [--ci-runner-app-id 00000000-0000-0000-0000-000000000000]
#
# --ci-runner-app-id is optional. If supplied, grants the CI runner service
# principal Storage Blob Data Contributor on each container. Run this after
# bootstrap-ci-runner.sh to assign access in one pass.

set -euo pipefail

RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
LOCATION=""
SUBSCRIPTION_ID=""
CONTAINERS="oauth-apps-sandpit,oauth-apps-prod"
CI_RUNNER_APP_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --resource-group)    RESOURCE_GROUP="$2";    shift 2 ;;
    --storage-account)   STORAGE_ACCOUNT="$2";   shift 2 ;;
    --location)          LOCATION="$2";          shift 2 ;;
    --subscription)      SUBSCRIPTION_ID="$2";   shift 2 ;;
    --containers)        CONTAINERS="$2";        shift 2 ;;
    --ci-runner-app-id)  CI_RUNNER_APP_ID="$2";  shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$RESOURCE_GROUP" || -z "$STORAGE_ACCOUNT" || -z "$LOCATION" ]] && {
  echo "Usage: $0 --resource-group NAME --storage-account NAME --location REGION"
  echo "         [--subscription ID] [--containers csv] [--ci-runner-app-id ID]"
  exit 1
}

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  echo "Setting subscription: ${SUBSCRIPTION_ID}"
  az account set --subscription "$SUBSCRIPTION_ID"
else
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi

echo ""
echo "=== Resource group ==="
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Already exists: ${RESOURCE_GROUP}"
else
  echo "  Creating: ${RESOURCE_GROUP} (${LOCATION})"
  az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
  echo "  Done"
fi

echo ""
echo "=== Storage account ==="
if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  echo "  Already exists: ${STORAGE_ACCOUNT}"
else
  echo "  Creating: ${STORAGE_ACCOUNT}"
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 \
    --https-only true \
    --output none
  echo "  Done"
fi

echo ""
echo "=== Blob service properties ==="
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  --output none
echo "  Versioning enabled, soft delete 30 days"

echo ""
echo "=== Containers ==="
STORAGE_ID=$(az storage account show \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

IFS=',' read -ra CONTAINER_LIST <<< "$CONTAINERS"
for CONTAINER in "${CONTAINER_LIST[@]}"; do
  CONTAINER=$(echo "$CONTAINER" | tr -d ' ')
  if az storage container show \
       --name "$CONTAINER" \
       --account-name "$STORAGE_ACCOUNT" \
       --auth-mode login &>/dev/null; then
    echo "  Already exists: ${CONTAINER}"
  else
    echo "  Creating: ${CONTAINER}"
    az storage container create \
      --name "$CONTAINER" \
      --account-name "$STORAGE_ACCOUNT" \
      --auth-mode login \
      --output none
    echo "  Done"
  fi
done

echo ""
echo "=== CI runner access ==="
if [[ -n "$CI_RUNNER_APP_ID" ]]; then
  SP_OBJECT_ID=$(az ad sp show --id "$CI_RUNNER_APP_ID" --query id -o tsv 2>/dev/null) || {
    echo "  [WARN] Could not find service principal for app ID ${CI_RUNNER_APP_ID} — skipping RBAC"
    SP_OBJECT_ID=""
  }

  if [[ -n "$SP_OBJECT_ID" ]]; then
    for CONTAINER in "${CONTAINER_LIST[@]}"; do
      CONTAINER=$(echo "$CONTAINER" | tr -d ' ')
      SCOPE="${STORAGE_ID}/blobServices/default/containers/${CONTAINER}"
      echo "  Granting Storage Blob Data Contributor on ${CONTAINER}"
      az role assignment create \
        --assignee-object-id "$SP_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "Storage Blob Data Contributor" \
        --scope "$SCOPE" \
        --output none 2>/dev/null || echo "  (already assigned)"
    done
  fi
else
  echo "  Skipped (no --ci-runner-app-id supplied)"
  echo "  Re-run with --ci-runner-app-id <AZURE_CLIENT_ID> after bootstrap-ci-runner.sh"
fi

echo ""
echo "=== Backend configuration ==="
echo "  Add the following backend block to main.tf:"
echo ""
for CONTAINER in "${CONTAINER_LIST[@]}"; do
  CONTAINER=$(echo "$CONTAINER" | tr -d ' ')
  ENV="${CONTAINER##*-}"   # extract suffix: sandpit or prod
  echo "  # ${ENV}"
  echo "  backend \"azurerm\" {"
  echo "    resource_group_name  = \"${RESOURCE_GROUP}\""
  echo "    storage_account_name = \"${STORAGE_ACCOUNT}\""
  echo "    container_name       = \"${CONTAINER}\""
  echo "    key                  = \"oauth-apps.tfstate\""
  echo "  }"
  echo ""
done
echo "  The backend block is environment-specific — select the correct container"
echo "  per environment, or pass -backend-config at terraform init time."
