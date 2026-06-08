#!/usr/bin/env bash
# test-all.sh
#
# Runs all OAuth authentication tests for a given environment.
# Credentials are retrieved from CyberArk AAM/CP, or passed directly.
#
# Usage (CyberArk retrieval):
#   ./test-all.sh \
#     --cyberark-cp-url https://cyberark-cp.example.com \
#     --cyberark-app-id test-runner-sandpit \
#     --tenant-id 00000000-0000-0000-0000-000000000000 \
#     --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
#     --env sandpit
#
# Or set environment variables:
#   export CYBERARK_CP_URL=https://cyberark-cp.example.com
#   export CYBERARK_APP_ID=test-runner-sandpit
#   export OAUTH_TENANT_ID=00000000-0000-0000-0000-000000000000
#   export SNOWFLAKE_IDENTIFIER_URI=api://svc-snowflake-oauth-resource-sandpit
#   export OAUTH_ENV=sandpit
#   ./test-all.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYBERARK_CP_URL="${CYBERARK_CP_URL:-}"
CYBERARK_APP_ID="${CYBERARK_APP_ID:-}"
CYBERARK_SAFE="${CYBERARK_SAFE:-}"
TENANT_ID="${OAUTH_TENANT_ID:-}"
IDENTIFIER_URI="${SNOWFLAKE_IDENTIFIER_URI:-}"
ENV="${OAUTH_ENV:-sandpit}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --cyberark-cp-url) CYBERARK_CP_URL="$2";  shift 2 ;;
    --cyberark-app-id) CYBERARK_APP_ID="$2";  shift 2 ;;
    --safe)            CYBERARK_SAFE="$2";     shift 2 ;;
    --tenant-id)       TENANT_ID="$2";         shift 2 ;;
    --identifier-uri)  IDENTIFIER_URI="$2";    shift 2 ;;
    --env)             ENV="$2";               shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

[[ -z "$CYBERARK_CP_URL" || -z "$CYBERARK_APP_ID" || -z "$TENANT_ID" || -z "$IDENTIFIER_URI" ]] && {
  echo "Usage: $0 --cyberark-cp-url URL --cyberark-app-id ID --tenant-id ID --identifier-uri URI [--env ENV] [--safe NAME]"
  echo ""
  echo "Or export: CYBERARK_CP_URL, CYBERARK_APP_ID, OAUTH_TENANT_ID, SNOWFLAKE_IDENTIFIER_URI, OAUTH_ENV"
  exit 1
}

PASS=0
FAIL=0

run_test() {
  local label="$1"
  shift
  echo "======================================================================"
  echo " TEST: ${label}"
  echo "======================================================================"
  if "$@"; then
    echo ""
    PASS=$((PASS + 1))
  else
    echo ""
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

SAFE_ARG=""
[[ -n "$CYBERARK_SAFE" ]] && SAFE_ARG="--safe $CYBERARK_SAFE"

COMMON_ARGS="--cyberark-cp-url $CYBERARK_CP_URL --cyberark-app-id $CYBERARK_APP_ID --tenant-id $TENANT_ID --env $ENV $SAFE_ARG"
SNOWFLAKE_ARGS="$COMMON_ARGS --identifier-uri $IDENTIFIER_URI"

# Snowflake client apps
run_test "Snowflake ETL client" \
  "$SCRIPT_DIR/test-snowflake-oauth.sh" $SNOWFLAKE_ARGS --app-name svc-snowflake-etl

run_test "SnapLogic -> Snowflake" \
  "$SCRIPT_DIR/test-snowflake-oauth.sh" $SNOWFLAKE_ARGS --app-name svc-snaplogic-snowflake

run_test "Matillion -> Snowflake" \
  "$SCRIPT_DIR/test-snowflake-oauth.sh" $SNOWFLAKE_ARGS --app-name svc-matillion-snowflake

# Tableau
run_test "Tableau" \
  "$SCRIPT_DIR/test-tableau-oauth.sh" $COMMON_ARGS --app-name svc-tableau-datasource

# GitHub Actions OIDC (config check only — no live token needed)
run_test "GitHub Actions OIDC config" \
  "$SCRIPT_DIR/test-github-actions-oidc.sh" --tenant-id $TENANT_ID --env $ENV \
    --app-name svc-github-actions-azure-devops

# Summary
echo "======================================================================"
echo " RESULTS: ${PASS} passed, ${FAIL} failed"
echo "======================================================================"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
