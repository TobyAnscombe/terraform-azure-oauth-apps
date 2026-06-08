#!/usr/bin/env bash
# test-tableau-oauth.sh
#
# Tests that a Tableau service principal can obtain a valid token from Azure AD.
# Credentials are retrieved from CyberArk AAM/CP, or passed directly via
# --client-id / --client-secret for quick ad-hoc testing.
#
# Usage (CyberArk retrieval):
#   ./test-tableau-oauth.sh \
#     --cyberark-cp-url https://cyberark-cp.example.com \
#     --cyberark-app-id tableau-server-sandpit \
#     --safe OAuth-AppRegistrations-sandpit \
#     --tenant-id 00000000-0000-0000-0000-000000000000 \
#     --app-name svc-tableau-datasource \
#     --env sandpit
#
# Usage (direct):
#   ./test-tableau-oauth.sh \
#     --client-id <appId> --client-secret <secret> \
#     --tenant-id 00000000-0000-0000-0000-000000000000 \
#     --app-name svc-tableau-datasource \
#     --env sandpit

set -euo pipefail

CYBERARK_CP_URL="${CYBERARK_CP_URL:-}"
CYBERARK_APP_ID="${CYBERARK_APP_ID:-}"
CYBERARK_SAFE="${CYBERARK_SAFE:-}"
TENANT_ID="${OAUTH_TENANT_ID:-}"
APP_NAME="${OAUTH_APP_NAME:-}"
ENV="${OAUTH_ENV:-sandpit}"
CLIENT_ID="${OAUTH_CLIENT_ID:-}"
CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --cyberark-cp-url) CYBERARK_CP_URL="$2";  shift 2 ;;
    --cyberark-app-id) CYBERARK_APP_ID="$2";  shift 2 ;;
    --safe)            CYBERARK_SAFE="$2";     shift 2 ;;
    --tenant-id)       TENANT_ID="$2";         shift 2 ;;
    --app-name)        APP_NAME="$2";          shift 2 ;;
    --env)             ENV="$2";               shift 2 ;;
    --client-id)       CLIENT_ID="$2";         shift 2 ;;
    --client-secret)   CLIENT_SECRET="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$TENANT_ID" || -z "$APP_NAME" ]] && {
  echo "Usage: $0 --tenant-id ID --app-name NAME [--env ENV]"
  echo "       (--cyberark-cp-url URL --cyberark-app-id ID --safe NAME) OR (--client-id ID --client-secret SECRET)"
  exit 1
}

TOKEN_URL="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
SCOPE="https://graph.microsoft.com/.default"
ACCOUNT_NAME="${APP_NAME}-${ENV}"

echo "--- Tableau OAuth test ---"
echo "  App:   ${ACCOUNT_NAME}"
echo "  Scope: ${SCOPE}"
echo ""

echo "[1/3] Retrieving credentials..."
if [[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]]; then
  echo "       Source: direct (--client-id / --client-secret)"
elif [[ -n "$CYBERARK_CP_URL" && -n "$CYBERARK_APP_ID" ]]; then
  SAFE="${CYBERARK_SAFE:-OAuth-AppRegistrations-${ENV}}"
  echo "       Source: CyberArk AAM (${CYBERARK_CP_URL})"
  echo "       Safe:   ${SAFE} / Object: ${ACCOUNT_NAME}"

  CLIENT_ID=$(az ad app list --display-name "${ACCOUNT_NAME}" --query "[0].appId" -o tsv 2>/dev/null) || {
    echo "[FAIL] App registration '${ACCOUNT_NAME}' not found in Azure AD"
    exit 1
  }
  [[ -z "$CLIENT_ID" ]] && { echo "[FAIL] Could not find app '${ACCOUNT_NAME}'"; exit 1; }

  CP_RESPONSE=$(curl -s --fail \
    "${CYBERARK_CP_URL}/AIMWebService/api/Accounts?AppID=${CYBERARK_APP_ID}&Safe=${SAFE}&Object=${ACCOUNT_NAME}" \
    -H "Accept: application/json") || {
    echo "[FAIL] CyberArk CP request failed — is the CP reachable and AppID allowed?"
    exit 1
  }
  CLIENT_SECRET=$(echo "$CP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['Content'])" 2>/dev/null) || {
    echo "[FAIL] Could not parse Content field from CyberArk response"
    echo "       Response: ${CP_RESPONSE}"
    exit 1
  }
else
  echo "[FAIL] Provide either (--cyberark-cp-url + --cyberark-app-id) or (--client-id + --client-secret)"
  exit 1
fi
echo "[PASS] Credentials retrieved (client_id: ${CLIENT_ID})"

echo ""
echo "[2/3] Requesting token from Azure AD..."
RESPONSE=$(curl -s -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=${SCOPE}")

ACCESS_TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
ERROR=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description',''))" 2>/dev/null)

[[ -z "$ACCESS_TOKEN" ]] && {
  echo "[FAIL] No access_token in response"
  echo "       ${ERROR}"
  exit 1
}
echo "[PASS] Token received"

echo ""
echo "[3/3] Validating token claims..."
PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
CLAIMS=$(python3 -c "
import base64, json, sys
p = sys.argv[1]
p += '=' * (4 - len(p) % 4)
p = p.replace('-','+').replace('_','/')
d = json.loads(base64.b64decode(p))
print(json.dumps({k: d[k] for k in ['aud','iss','appid','exp'] if k in d}, indent=2))
" "$PAYLOAD")

echo "$CLAIMS"

APPID=$(echo "$CLAIMS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('appid',''))")
[[ "$APPID" == "$CLIENT_ID" ]] || {
  echo "[FAIL] Unexpected appid in token: got '${APPID}', expected '${CLIENT_ID}'"
  exit 1
}

echo ""
echo "[PASS] Tableau OAuth authentication verified"
