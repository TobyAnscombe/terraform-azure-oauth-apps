<#
.SYNOPSIS
    Validates that the GitHub Actions OIDC federated credential is correctly configured.

.DESCRIPTION
    Checks Azure AD configuration only — does not require a live GitHub Actions run.
    Verifies the app registration exists and that federated identity credentials are present,
    then lists each configured OIDC subject and issuer.

.PARAMETER TenantId
    Azure AD tenant ID. Also read from OAUTH_TENANT_ID environment variable.

.PARAMETER AppName
    Base display name of the app registration, without environment suffix.
    Also read from OAUTH_APP_NAME environment variable.

.PARAMETER Env
    Environment suffix: sandpit or prod. Default: sandpit.
    Also read from OAUTH_ENV environment variable.

.EXAMPLE
    .\Test-GitHubActionsOidc.ps1 `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -AppName svc-github-actions-azure-devops `
        -Env sandpit
#>

[CmdletBinding()]
param(
    [string]$TenantId = $env:OAUTH_TENANT_ID,
    [string]$AppName  = $env:OAUTH_APP_NAME,
    [string]$Env      = $(if ($env:OAUTH_ENV) { $env:OAUTH_ENV } else { 'sandpit' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TenantId -or -not $AppName) {
    Write-Host "Usage: .\Test-GitHubActionsOidc.ps1 -TenantId ID -AppName NAME [-Env ENV]"
    exit 1
}

$DisplayName = "$AppName-$Env"

Write-Host "--- GitHub Actions OIDC configuration test ---"
Write-Host "  App: $DisplayName"
Write-Host ""

Write-Host "[1/3] Looking up app registration..."
$AppId    = (az ad app list --display-name $DisplayName --query "[0].appId" -o tsv 2>$null).Trim()
$ObjectId = (az ad app list --display-name $DisplayName --query "[0].id"    -o tsv 2>$null).Trim()

if (-not $AppId) {
    Write-Host "[FAIL] App registration '$DisplayName' not found in Azure AD"
    exit 1
}
Write-Host "[PASS] Found app registration"
Write-Host "       app_id (client_id): $AppId"
Write-Host "       object_id:          $ObjectId"

Write-Host ""
Write-Host "[2/3] Checking for federated identity credentials..."
$CredsJson = az ad app federated-credential list --id $ObjectId -o json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Could not list federated credentials for '$DisplayName'"
    exit 1
}

$Creds = $CredsJson | ConvertFrom-Json
if ($Creds.Count -eq 0) {
    Write-Host "[FAIL] No federated credentials found on $DisplayName"
    Write-Host "       Run terraform apply to create them"
    exit 1
}
Write-Host "[PASS] $($Creds.Count) federated credential(s) configured"

Write-Host ""
Write-Host "[3/3] Listing configured OIDC subjects..."
foreach ($Cred in $Creds) {
    $Audience = if ($Cred.audiences -and $Cred.audiences.Count -gt 0) { $Cred.audiences[0] } else { '' }
    Write-Host "  subject:  $($Cred.subject)"
    Write-Host "  issuer:   $($Cred.issuer)"
    Write-Host "  audience: $Audience"
    Write-Host ""
}

Write-Host "[INFO] To confirm end-to-end: trigger a GitHub Actions workflow that uses"
Write-Host "       azure/login@v2 with client-id=$AppId"
Write-Host "       A successful run proves the OIDC trust is working."
Write-Host ""
Write-Host "[PASS] OIDC configuration verified"
