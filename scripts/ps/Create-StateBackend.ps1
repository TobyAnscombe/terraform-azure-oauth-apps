<#
.SYNOPSIS
    Creates the Azure Storage Account used as the Terraform state backend.

.DESCRIPTION
    Run once before the first terraform init. Idempotent — safe to re-run.
    Optionally grants the CI runner service principal Storage Blob Data
    Contributor on each container. Run after bootstrap-ci-runner.sh to
    assign access in one pass.

.PARAMETER ResourceGroup
    Name of the resource group to create or use (e.g. rg-terraform-state).

.PARAMETER StorageAccount
    Storage account name — 3-24 chars, lowercase letters and numbers only
    (e.g. stterraformstate).

.PARAMETER Location
    Azure region for the resource group and storage account (e.g. "UK South").

.PARAMETER SubscriptionId
    Optional. Azure subscription ID. Defaults to the current az CLI subscription.

.PARAMETER Containers
    Comma-separated list of container names to create.
    Default: oauth-apps-sandpit,oauth-apps-prod

.PARAMETER CiRunnerAppId
    Optional. Application (client) ID of the CI runner service principal.
    When supplied, grants Storage Blob Data Contributor on each container.

.EXAMPLE
    .\Create-StateBackend.ps1 `
        -ResourceGroup rg-terraform-state `
        -StorageAccount stterraformstate `
        -Location "UK South"

.EXAMPLE
    .\Create-StateBackend.ps1 `
        -ResourceGroup rg-terraform-state `
        -StorageAccount stterraformstate `
        -Location "UK South" `
        -CiRunnerAppId 00000000-0000-0000-0000-000000000000
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$StorageAccount,

    [Parameter(Mandatory)]
    [string]$Location,

    [string]$SubscriptionId,

    [string]$Containers = "oauth-apps-sandpit,oauth-apps-prod",

    [string]$CiRunnerAppId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Az {
    param([string[]]$Arguments)
    $result = az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments[0]) failed: $result"
    }
    return $result
}

function Test-AzResource {
    param([string[]]$Arguments)
    az @Arguments 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

# Set subscription
if ($SubscriptionId) {
    Write-Host "Setting subscription: $SubscriptionId"
    Invoke-Az "account", "set", "--subscription", $SubscriptionId | Out-Null
} else {
    $SubscriptionId = (Invoke-Az "account", "show", "--query", "id", "-o", "tsv").Trim()
}

$ContainerList = $Containers -split ',' | ForEach-Object { $_.Trim() }

Write-Host ""
Write-Host "=== Resource group ==="
if (Test-AzResource "group", "show", "--name", $ResourceGroup) {
    Write-Host "  Already exists: $ResourceGroup"
} else {
    Write-Host "  Creating: $ResourceGroup ($Location)"
    Invoke-Az "group", "create", "--name", $ResourceGroup, "--location", $Location, "--output", "none" | Out-Null
    Write-Host "  Done"
}

Write-Host ""
Write-Host "=== Storage account ==="
if (Test-AzResource "storage", "account", "show", "--name", $StorageAccount, "--resource-group", $ResourceGroup) {
    Write-Host "  Already exists: $StorageAccount"
} else {
    Write-Host "  Creating: $StorageAccount"
    Invoke-Az "storage", "account", "create",
        "--name", $StorageAccount,
        "--resource-group", $ResourceGroup,
        "--location", $Location,
        "--sku", "Standard_LRS",
        "--allow-blob-public-access", "false",
        "--min-tls-version", "TLS1_2",
        "--https-only", "true",
        "--output", "none" | Out-Null
    Write-Host "  Done"
}

Write-Host ""
Write-Host "=== Blob service properties ==="
Invoke-Az "storage", "account", "blob-service-properties", "update",
    "--account-name", $StorageAccount,
    "--enable-versioning", "true",
    "--enable-delete-retention", "true",
    "--delete-retention-days", "30",
    "--output", "none" | Out-Null
Write-Host "  Versioning enabled, soft delete 30 days"

Write-Host ""
Write-Host "=== Containers ==="
$StorageId = (Invoke-Az "storage", "account", "show",
    "--name", $StorageAccount,
    "--resource-group", $ResourceGroup,
    "--query", "id", "-o", "tsv").Trim()

foreach ($Container in $ContainerList) {
    if (Test-AzResource "storage", "container", "show",
            "--name", $Container,
            "--account-name", $StorageAccount,
            "--auth-mode", "login") {
        Write-Host "  Already exists: $Container"
    } else {
        Write-Host "  Creating: $Container"
        Invoke-Az "storage", "container", "create",
            "--name", $Container,
            "--account-name", $StorageAccount,
            "--auth-mode", "login",
            "--output", "none" | Out-Null
        Write-Host "  Done"
    }
}

Write-Host ""
Write-Host "=== CI runner access ==="
if ($CiRunnerAppId) {
    try {
        $SpObjectId = (Invoke-Az "ad", "sp", "show", "--id", $CiRunnerAppId, "--query", "id", "-o", "tsv").Trim()
    } catch {
        Write-Warning "Could not find service principal for app ID $CiRunnerAppId — skipping RBAC"
        $SpObjectId = $null
    }

    if ($SpObjectId) {
        foreach ($Container in $ContainerList) {
            $Scope = "$StorageId/blobServices/default/containers/$Container"
            Write-Host "  Granting Storage Blob Data Contributor on $Container"
            try {
                Invoke-Az "role", "assignment", "create",
                    "--assignee-object-id", $SpObjectId,
                    "--assignee-principal-type", "ServicePrincipal",
                    "--role", "Storage Blob Data Contributor",
                    "--scope", $Scope,
                    "--output", "none" | Out-Null
            } catch {
                Write-Host "  (already assigned)"
            }
        }
    }
} else {
    Write-Host "  Skipped (no -CiRunnerAppId supplied)"
    Write-Host "  Re-run with -CiRunnerAppId <AZURE_CLIENT_ID> after bootstrap-ci-runner.sh"
}

Write-Host ""
Write-Host "=== Backend configuration ==="
Write-Host "  Add the following backend block to main.tf:"
Write-Host ""
foreach ($Container in $ContainerList) {
    $Env = $Container -replace '.*-', ''   # extract suffix: sandpit or prod
    Write-Host "  # $Env"
    Write-Host "  backend `"azurerm`" {"
    Write-Host "    resource_group_name  = `"$ResourceGroup`""
    Write-Host "    storage_account_name = `"$StorageAccount`""
    Write-Host "    container_name       = `"$Container`""
    Write-Host "    key                  = `"oauth-apps.tfstate`""
    Write-Host "  }"
    Write-Host ""
}
Write-Host "  The backend block is environment-specific — select the correct container"
Write-Host "  per environment, or pass -backend-config at terraform init time."
