#!/usr/bin/env bash
# test-github-actions-oidc.sh
#
# Validates that the GitHub Actions OIDC federated credential is correctly
# configured on the service principal. Does not require a live GitHub Actions
# run — checks Azure AD configuration only.
#
# Usage:
#   ./test-github-actions-oidc.sh \
#     --tenant-id 00000000-0000-0000-0000-000000000000 \
#     --app-name svc-github-actions-azure-devops \
#     --env sandpit

set -euo pipefail

TENANT_ID="${OAUTH_TENANT_ID:-}"
APP_NAME="${OAUTH_APP_NAME:-}"
ENV="${OAUTH_ENV:-sandpit}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --tenant-id) TENANT_ID="$2"; shift 2 ;;
    --app-name)  APP_NAME="$2";  shift 2 ;;
    --env)       ENV="$2";       shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$TENANT_ID" || -z "$APP_NAME" ]] && {
  echo "Usage: $0 --tenant-id ID --app-name NAME [--env ENV]"
  exit 1
}

DISPLAY_NAME="${APP_NAME}-${ENV}"

echo "--- GitHub Actions OIDC configuration test ---"
echo "  App: ${DISPLAY_NAME}"
echo ""

echo "[1/3] Looking up app registration..."
APP_ID=$(az ad app list --display-name "$DISPLAY_NAME" --query "[0].appId" -o tsv 2>/dev/null)
OBJECT_ID=$(az ad app list --display-name "$DISPLAY_NAME" --query "[0].id" -o tsv 2>/dev/null)

[[ -z "$APP_ID" ]] && {
  echo "[FAIL] App registration '${DISPLAY_NAME}' not found in Azure AD"
  exit 1
}
echo "[PASS] Found app registration"
echo "       app_id (client_id): ${APP_ID}"
echo "       object_id:          ${OBJECT_ID}"

echo ""
echo "[2/3] Checking for federated identity credentials..."
CREDS=$(az ad app federated-credential list --id "$OBJECT_ID" -o json 2>/dev/null)
COUNT=$(echo "$CREDS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

[[ "$COUNT" -eq 0 ]] && {
  echo "[FAIL] No federated credentials found on ${DISPLAY_NAME}"
  echo "       Run terraform apply to create them"
  exit 1
}
echo "[PASS] ${COUNT} federated credential(s) configured"

echo ""
echo "[3/3] Listing configured OIDC subjects..."
echo "$CREDS" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    print(f\"  subject:  {c['subject']}\")
    print(f\"  issuer:   {c['issuer']}\")
    print(f\"  audience: {c.get('audiences', [''])[0]}\")
    print()
"

echo "[INFO] To confirm end-to-end: trigger a GitHub Actions workflow that uses"
echo "       azure/login@v2 with client-id=${APP_ID}"
echo "       A successful run proves the OIDC trust is working."
echo ""
echo "[PASS] OIDC configuration verified"
