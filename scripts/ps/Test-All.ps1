<#
.SYNOPSIS
    Runs all OAuth authentication tests for a given environment.

.DESCRIPTION
    Invokes Test-SnowflakeOAuth.ps1 (three clients), Test-TableauOAuth.ps1, and
    Test-GitHubActionsOidc.ps1, then prints a pass/fail summary.
    Credentials are retrieved from CyberArk AAM/CP.

.PARAMETER CyberArkCpUrl
    Base URL of the CyberArk Central Credential Provider.
    Also read from CYBERARK_CP_URL environment variable.

.PARAMETER CyberArkAppId
    CyberArk application ID used by the test runner to retrieve credentials.
    Also read from CYBERARK_APP_ID environment variable.

.PARAMETER Safe
    CyberArk safe name override. Defaults to OAuth-AppRegistrations-<Env>.
    Also read from CYBERARK_SAFE environment variable.

.PARAMETER TenantId
    Azure AD tenant ID. Also read from OAUTH_TENANT_ID environment variable.

.PARAMETER IdentifierUri
    App ID URI of the Snowflake resource server app.
    Also read from SNOWFLAKE_IDENTIFIER_URI environment variable.

.PARAMETER Env
    Environment suffix: sandpit or prod. Default: sandpit.
    Also read from OAUTH_ENV environment variable.

.EXAMPLE
    .\Test-All.ps1 `
        -CyberArkCpUrl https://cyberark-cp.example.com `
        -CyberArkAppId test-runner-sandpit `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
        -Env sandpit

.EXAMPLE
    $env:CYBERARK_CP_URL           = 'https://cyberark-cp.example.com'
    $env:CYBERARK_APP_ID           = 'test-runner-sandpit'
    $env:OAUTH_TENANT_ID           = '00000000-0000-0000-0000-000000000000'
    $env:SNOWFLAKE_IDENTIFIER_URI  = 'api://svc-snowflake-oauth-resource-sandpit'
    $env:OAUTH_ENV                 = 'sandpit'
    .\Test-All.ps1
#>

[CmdletBinding()]
param(
    [string]$CyberArkCpUrl  = $env:CYBERARK_CP_URL,
    [string]$CyberArkAppId  = $env:CYBERARK_APP_ID,
    [string]$Safe            = $env:CYBERARK_SAFE,
    [string]$TenantId        = $env:OAUTH_TENANT_ID,
    [string]$IdentifierUri   = $env:SNOWFLAKE_IDENTIFIER_URI,
    [string]$Env             = $(if ($env:OAUTH_ENV) { $env:OAUTH_ENV } else { 'sandpit' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $CyberArkCpUrl -or -not $CyberArkAppId -or -not $TenantId -or -not $IdentifierUri) {
    Write-Host "Usage: .\Test-All.ps1 -CyberArkCpUrl URL -CyberArkAppId ID -TenantId ID -IdentifierUri URI [-Env ENV] [-Safe NAME]"
    Write-Host ""
    Write-Host "Or set: CYBERARK_CP_URL, CYBERARK_APP_ID, OAUTH_TENANT_ID, SNOWFLAKE_IDENTIFIER_URI, OAUTH_ENV"
    exit 1
}

$ScriptDir = $PSScriptRoot
$PwshExe   = (Get-Process -Id $PID).Path   # current PowerShell executable
$PassCount = 0
$FailCount = 0

function Invoke-Test {
    param([string]$Label, [string]$Script, [string[]]$Arguments)
    Write-Host ("=" * 70)
    Write-Host " TEST: $Label"
    Write-Host ("=" * 70)
    & $PwshExe -NonInteractive -File $Script @Arguments
    if ($LASTEXITCODE -eq 0) {
        $script:PassCount++
    } else {
        $script:FailCount++
    }
    Write-Host ""
}

$CyberArkArgs = @('-CyberArkCpUrl', $CyberArkCpUrl, '-CyberArkAppId', $CyberArkAppId)
if ($Safe) { $CyberArkArgs += @('-Safe', $Safe) }

$CommonArgs    = $CyberArkArgs + @('-TenantId', $TenantId, '-Env', $Env)
$SnowflakeArgs = $CommonArgs   + @('-IdentifierUri', $IdentifierUri)

Invoke-Test "Snowflake ETL client" "$ScriptDir/Test-SnowflakeOAuth.ps1" `
    ($SnowflakeArgs + @('-AppName', 'svc-snowflake-etl'))

Invoke-Test "SnapLogic -> Snowflake" "$ScriptDir/Test-SnowflakeOAuth.ps1" `
    ($SnowflakeArgs + @('-AppName', 'svc-snaplogic-snowflake'))

Invoke-Test "Matillion -> Snowflake" "$ScriptDir/Test-SnowflakeOAuth.ps1" `
    ($SnowflakeArgs + @('-AppName', 'svc-matillion-snowflake'))

Invoke-Test "Tableau" "$ScriptDir/Test-TableauOAuth.ps1" `
    ($CommonArgs + @('-AppName', 'svc-tableau-datasource'))

Invoke-Test "GitHub Actions OIDC config" "$ScriptDir/Test-GitHubActionsOidc.ps1" `
    @('-TenantId', $TenantId, '-Env', $Env, '-AppName', 'svc-github-actions-azure-devops')

Write-Host ("=" * 70)
Write-Host " RESULTS: $PassCount passed, $FailCount failed"
Write-Host ("=" * 70)

if ($FailCount -gt 0) { exit 1 }
exit 0
