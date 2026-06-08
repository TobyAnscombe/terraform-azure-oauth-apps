<#
.SYNOPSIS
    One-time setup: creates the GitHub Actions service principal for Terraform CI OIDC authentication.

.DESCRIPTION
    Creates an Azure AD app registration with a service principal, assigns Contributor on the
    subscription, grants Application.ReadWrite.OwnedBy on Microsoft Graph with admin consent,
    and adds federated OIDC credentials for main, sandpit, and pull_request subjects.

    Run once from a machine with az CLI access and Owner / Application Administrator rights.
    After this runs, add the three AZURE_* values as GitHub Actions repository variables.

.PARAMETER DisplayName
    Display name for the app registration. Default: svc-terraform-ci-runner.

.PARAMETER Repo
    GitHub repository in org/repo format. Default: TobyAnscombe/terraform-azure-oauth-apps.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to the current az CLI subscription.

.EXAMPLE
    .\Bootstrap-CiRunner.ps1

.EXAMPLE
    .\Bootstrap-CiRunner.ps1 `
        -DisplayName "svc-terraform-ci-runner" `
        -Repo "MyOrg/terraform-azure-oauth-apps" `
        -SubscriptionId "00000000-0000-0000-0000-000000000000"
#>

[CmdletBinding()]
param(
    [string]$DisplayName    = 'svc-terraform-ci-runner',
    [string]$Repo           = 'TobyAnscombe/terraform-azure-oauth-apps',
    [string]$SubscriptionId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv 2>$null).Trim()
    if (-not $SubscriptionId) {
        Write-Host "[FAIL] Could not determine subscription ID — run 'az login' or pass -SubscriptionId"
        exit 1
    }
}

$TenantId = (az account show --query tenantId -o tsv 2>$null).Trim()
if (-not $TenantId) {
    Write-Host "[FAIL] Could not determine tenant ID — run 'az login'"
    exit 1
}

Write-Host "Creating app registration: $DisplayName"
$AppId = (az ad app create --display-name $DisplayName --query appId -o tsv 2>$null).Trim()
if (-not $AppId) {
    Write-Host "[FAIL] Failed to create app registration"
    exit 1
}
Write-Host "  application_id = $AppId"

Write-Host "Creating service principal"
$SpObjectId = (az ad sp create --id $AppId --query id -o tsv 2>$null).Trim()
if (-not $SpObjectId) {
    Write-Host "[FAIL] Failed to create service principal"
    exit 1
}
Write-Host "  service_principal_object_id = $SpObjectId"

Write-Host "Assigning Contributor role on subscription $SubscriptionId"
az role assignment create `
    --assignee $AppId `
    --role "Contributor" `
    --scope "/subscriptions/$SubscriptionId" `
    --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Role assignment failed"
    exit 1
}

Write-Host "Granting Application.ReadWrite.OwnedBy permission"
# Application.ReadWrite.OwnedBy: 18a4783c-866b-4cc7-a460-3d5e5662c884
az ad app permission add `
    --id $AppId `
    --api "00000003-0000-0000-c000-000000000002" `
    --api-permissions "18a4783c-866b-4cc7-a460-3d5e5662c884=Role" `
    --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Permission add failed"
    exit 1
}

Write-Host "Granting admin consent"
az ad app permission admin-consent --id $AppId --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Admin consent failed"
    exit 1
}

$FederatedCredentials = @(
    @{ name = 'github-actions-main';    subject = "repo:${Repo}:ref:refs/heads/main" },
    @{ name = 'github-actions-sandpit'; subject = "repo:${Repo}:ref:refs/heads/sandpit" },
    @{ name = 'github-actions-pr';      subject = "repo:${Repo}:pull_request" }
)

foreach ($Cred in $FederatedCredentials) {
    Write-Host "Adding federated credential: $($Cred.name)"
    $Params = @{
        name      = $Cred.name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $Cred.subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress

    az ad app federated-credential create `
        --id $AppId `
        --parameters $Params `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Failed to add federated credential '$($Cred.name)'"
        exit 1
    }
}

Write-Host ""
Write-Host "Bootstrap complete. Add the following as GitHub Actions repository variables:"
Write-Host "  AZURE_CLIENT_ID       = $AppId"
Write-Host "  AZURE_TENANT_ID       = $TenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID = $SubscriptionId"
Write-Host ""
Write-Host "NOTE: Application.ReadWrite.OwnedBy means this CI runner can only manage"
Write-Host "app registrations it owns. The app_owners variable in tfvars must include"
Write-Host "the object ID of this service principal ($SpObjectId) or use"
Write-Host "Application.ReadWrite.All if broader access is required."
