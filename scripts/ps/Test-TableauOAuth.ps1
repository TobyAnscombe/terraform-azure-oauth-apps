<#
.SYNOPSIS
    Tests that a Tableau service principal can obtain a valid token from Azure AD.

.DESCRIPTION
    Credentials are retrieved from CyberArk AAM/CP, or passed directly via
    -ClientId / -ClientSecret for quick ad-hoc testing.

.PARAMETER CyberArkCpUrl
    Base URL of the CyberArk Central Credential Provider (e.g. https://cyberark-cp.example.com).
    Also read from CYBERARK_CP_URL environment variable.

.PARAMETER CyberArkAppId
    CyberArk application ID registered to retrieve credentials.
    Also read from CYBERARK_APP_ID environment variable.

.PARAMETER Safe
    CyberArk safe name. Defaults to OAuth-AppRegistrations-<Env>.
    Also read from CYBERARK_SAFE environment variable.

.PARAMETER TenantId
    Azure AD tenant ID. Also read from OAUTH_TENANT_ID environment variable.

.PARAMETER AppName
    Base display name of the app registration, without environment suffix.
    Also read from OAUTH_APP_NAME environment variable.

.PARAMETER Env
    Environment suffix: sandpit or prod. Default: sandpit.
    Also read from OAUTH_ENV environment variable.

.PARAMETER ClientId
    Direct mode: Azure AD application (client) ID.
    Also read from OAUTH_CLIENT_ID environment variable.

.PARAMETER ClientSecret
    Direct mode: client secret value.
    Also read from OAUTH_CLIENT_SECRET environment variable.

.EXAMPLE
    .\Test-TableauOAuth.ps1 `
        -CyberArkCpUrl https://cyberark-cp.example.com `
        -CyberArkAppId tableau-server-sandpit `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -AppName svc-tableau-datasource `
        -Env sandpit

.EXAMPLE
    .\Test-TableauOAuth.ps1 `
        -ClientId <appId> `
        -ClientSecret <secret> `
        -TenantId 00000000-0000-0000-0000-000000000000 `
        -AppName svc-tableau-datasource
#>

[CmdletBinding()]
param(
    [string]$CyberArkCpUrl  = $env:CYBERARK_CP_URL,
    [string]$CyberArkAppId  = $env:CYBERARK_APP_ID,
    [string]$Safe            = $env:CYBERARK_SAFE,
    [string]$TenantId        = $env:OAUTH_TENANT_ID,
    [string]$AppName         = $env:OAUTH_APP_NAME,
    [string]$Env             = $(if ($env:OAUTH_ENV) { $env:OAUTH_ENV } else { 'sandpit' }),
    [string]$ClientId        = $env:OAUTH_CLIENT_ID,
    [string]$ClientSecret    = $env:OAUTH_CLIENT_SECRET
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JwtClaims {
    param([string]$Token, [string[]]$Fields)
    $payload = $Token.Split('.')[1]
    $rem = $payload.Length % 4
    if ($rem -gt 0) { $payload += '=' * (4 - $rem) }
    $payload  = $payload.Replace('-', '+').Replace('_', '/')
    $full     = [System.Text.Encoding]::UTF8.GetString(
                    [System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $result   = [ordered]@{}
    foreach ($f in $Fields) {
        if ($null -ne $full.$f) { $result[$f] = $full.$f }
    }
    return $result
}

if (-not $TenantId -or -not $AppName) {
    Write-Host "Usage: .\Test-TableauOAuth.ps1 -TenantId ID -AppName NAME [-Env ENV]"
    Write-Host "       (-CyberArkCpUrl URL -CyberArkAppId ID [-Safe NAME]) OR (-ClientId ID -ClientSecret SECRET)"
    exit 1
}

$TokenUrl    = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$Scope       = "https://graph.microsoft.com/.default"
$AccountName = "$AppName-$Env"

Write-Host "--- Tableau OAuth test ---"
Write-Host "  App:   $AccountName"
Write-Host "  Scope: $Scope"
Write-Host ""

Write-Host "[1/3] Retrieving credentials..."
if ($ClientId -and $ClientSecret) {
    Write-Host "       Source: direct (-ClientId / -ClientSecret)"
} elseif ($CyberArkCpUrl -and $CyberArkAppId) {
    $SafeName = if ($Safe) { $Safe } else { "OAuth-AppRegistrations-$Env" }
    Write-Host "       Source: CyberArk AAM ($CyberArkCpUrl)"
    Write-Host "       Safe:   $SafeName / Object: $AccountName"

    $ClientId = (az ad app list --display-name $AccountName --query "[0].appId" -o tsv 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $ClientId) {
        Write-Host "[FAIL] App registration '$AccountName' not found in Azure AD"
        exit 1
    }

    try {
        $CpResponse = Invoke-RestMethod `
            -Uri "$CyberArkCpUrl/AIMWebService/api/Accounts?AppID=$CyberArkAppId&Safe=$SafeName&Object=$AccountName" `
            -Headers @{ Accept = 'application/json' }
    } catch {
        Write-Host "[FAIL] CyberArk CP request failed — is the CP reachable and AppID allowed?"
        Write-Host "       $_"
        exit 1
    }

    $ClientSecret = $CpResponse.Content
    if (-not $ClientSecret) {
        Write-Host "[FAIL] Could not parse Content field from CyberArk response"
        exit 1
    }
} else {
    Write-Host "[FAIL] Provide either (-CyberArkCpUrl + -CyberArkAppId) or (-ClientId + -ClientSecret)"
    exit 1
}
Write-Host "[PASS] Credentials retrieved (client_id: $ClientId)"

Write-Host ""
Write-Host "[2/3] Requesting token from Azure AD..."
try {
    $TokenResponse = Invoke-RestMethod -Method Post -Uri $TokenUrl `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $Scope
        }
} catch {
    $errBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
    $errMsg  = if ($errBody -and $errBody.error_description) { $errBody.error_description } else { $_.ToString() }
    Write-Host "[FAIL] Token request failed"
    Write-Host "       $errMsg"
    exit 1
}

if (-not $TokenResponse.access_token) {
    Write-Host "[FAIL] No access_token in response"
    exit 1
}
Write-Host "[PASS] Token received"

Write-Host ""
Write-Host "[3/3] Validating token claims..."
$Claims = Get-JwtClaims -Token $TokenResponse.access_token -Fields 'aud', 'iss', 'appid', 'exp'
$Claims | ConvertTo-Json | Write-Host

if ($Claims['appid'] -ne $ClientId) {
    Write-Host "[FAIL] Unexpected appid in token: got '$($Claims['appid'])', expected '$ClientId'"
    exit 1
}

Write-Host ""
Write-Host "[PASS] Tableau OAuth authentication verified"
