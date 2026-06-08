# terraform-azure-oauth-apps

Terraform module and workspace for creating Azure AD app registrations that allow applications to authenticate using service accounts rather than interactive logins. Covers Snowflake External OAuth, Tableau service principals, and GitHub Actions workload identity — all managed consistently through a single reusable module.

---

## Design

### The problem

Applications like Snowflake and Tableau default to user-based interactive logins. When used in automated pipelines or scheduled jobs, this means either storing user credentials somewhere insecure, or relying on a named user account that can't enforce MFA and is hard to audit. The correct solution is service account authentication via OAuth 2.0, where each application gets its own registered identity in Azure AD with credentials stored in Key Vault.

### The approach

A single Terraform module (`modules/azuread-oauth-app`) creates the Azure AD resources. It supports three authentication patterns, selected via the `app_type` variable:

| `app_type` | Credential | Used for |
|---|---|---|
| `secret` | Client secret → Key Vault | Snowflake client apps, Tableau |
| `snowflake_resource` | Client secret → Key Vault | Snowflake External OAuth resource server |
| `oidc` | Federated credential (no secret) | GitHub Actions → Azure |

Each pattern results in the same base resources: an app registration and a service principal. What differs is whether a client secret or a federated OIDC credential is attached.

### Secret rotation

Client secrets are owned and rotated by **CyberArk CPM** (Central Policy Manager). Terraform creates the app registration structure; CPM creates the first Azure AD password on initial verification and rotates it on schedule thereafter.

This gives you calendar-driven rotation, emergency rotation, verification, failure alerting, and a full audit trail — independent of any Terraform apply cycle. See [CyberArk integration](#cyberark-integration) for setup.

### Why no secrets for GitHub Actions?

GitHub Actions supports [Workload Identity Federation](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect). Instead of a client secret, Azure trusts a short-lived OIDC token issued by GitHub's token endpoint. The `federated_subjects` variable controls exactly which repo, branch, or environment is trusted — nothing broader.

### Sandpit vs Production

The workspace is environment-aware via the `environment` variable. The CI pipeline maps branches to environments:

- `sandpit` branch → sandpit tfvars + sandpit GitHub Actions environment
- `main` branch → prod tfvars + prod GitHub Actions environment

State is stored in separate Azure Storage containers per environment. Promotion is a PR from `sandpit` → `main`, reviewed before apply.

---

## Repository structure

```
terraform-azure-oauth-apps/
├── modules/
│   └── azuread-oauth-app/      # Reusable module — all app types
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── main.tf                     # Provider config and backend
├── locals.tf                   # Shared locals (tags, well-known app IDs)
├── variables.tf                # All input variables
├── cyberark.tf                 # CyberArk safe + account management
├── snowflake.tf                # Snowflake resource server + client apps
├── tableau.tf                  # Tableau app registrations
├── github_actions.tf           # GitHub Actions OIDC apps
├── outputs.tf                  # App IDs, Snowflake SQL
├── terraform.tfvars.example    # Template — copy to terraform.tfvars
├── scripts/
│   ├── bash/
│   │   ├── bootstrap-ci-runner.sh      # One-time CI runner setup via az CLI
│   │   ├── create-state-backend.sh     # Create Azure Storage state backend
│   │   ├── test-snowflake-oauth.sh     # Validate Snowflake token exchange
│   │   ├── test-tableau-oauth.sh       # Validate Tableau token exchange
│   │   ├── test-github-actions-oidc.sh # Validate OIDC federated config
│   │   └── test-all.sh                 # Run all tests, PASS/FAIL summary
│   └── ps/
│       ├── Bootstrap-CiRunner.ps1      # One-time CI runner setup via az CLI
│       ├── Create-StateBackend.ps1     # Create Azure Storage state backend
│       ├── Test-SnowflakeOAuth.ps1     # Validate Snowflake token exchange
│       ├── Test-TableauOAuth.ps1       # Validate Tableau token exchange
│       ├── Test-GitHubActionsOidc.ps1  # Validate OIDC federated config
│       └── Test-All.ps1                # Run all tests, PASS/FAIL summary
└── .github/
    └── workflows/
        └── terraform.yml       # Security scan + lint + plan/apply
```

---

## Prerequisites

- Terraform >= 1.5.0
- Azure CLI (`az`) authenticated to the target tenant
- Azure AD permissions: **Application Administrator** (or Global Administrator) to create app registrations
- CyberArk Privilege Cloud with PAM administrator access (safe creation, platform management)
- A GitHub repository with Actions enabled

### Required Azure AD permissions for the Terraform runner

The service principal running Terraform needs `Application.ReadWrite.OwnedBy` on Microsoft Graph to create and manage the app registrations it owns. The bootstrap script configures this automatically.

---

## Getting started

Steps 1–4 are one-time setup. Steps 5–9 are per-environment (repeat for `sandpit` and `prod`).

---

### Step 1 — Bootstrap the CI runner

Creates the service principal that GitHub Actions uses to authenticate to Azure via OIDC. Run once from any machine with `az` CLI access and Application Administrator rights.

```bash
chmod +x scripts/bash/bootstrap-ci-runner.sh
./scripts/bash/bootstrap-ci-runner.sh "svc-terraform-ci-runner" "YourOrg/terraform-azure-oauth-apps"
```

```powershell
.\scripts\ps\Bootstrap-CiRunner.ps1 `
    -DisplayName "svc-terraform-ci-runner" `
    -Repo "YourOrg/terraform-azure-oauth-apps"
```

The script prints three values — keep them, you will need them in Step 4:

```
AZURE_CLIENT_ID       = <output>
AZURE_TENANT_ID       = <output>
AZURE_SUBSCRIPTION_ID = <output>
```

---

### Step 2 — Create the state backend

Creates the Azure Storage Account, containers, and CI runner RBAC in one pass. Idempotent — safe to re-run.

```bash
# bash
./scripts/bash/create-state-backend.sh \
  --resource-group rg-terraform-state \
  --storage-account stterraformstate \
  --location "UK South" \
  --ci-runner-app-id <AZURE_CLIENT_ID from Step 1>
```

```powershell
# PowerShell
.\scripts\ps\Create-StateBackend.ps1 `
  -ResourceGroup rg-terraform-state `
  -StorageAccount stterraformstate `
  -Location "UK South" `
  -CiRunnerAppId <AZURE_CLIENT_ID from Step 1>
```

The script prints the backend block to add to `main.tf`. Copy the sandpit block:

```hcl
backend "azurerm" {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = "stterraformstate"
  container_name       = "oauth-apps-sandpit"
  key                  = "oauth-apps.tfstate"
}
```

---

### Step 3 — Set up CyberArk

#### 3a. Create the Azure AD platform in PVWA

In PVWA → **Administration → Platform Management**, duplicate an existing Azure platform or create a new one with the following settings:

- **Allow automatic password change**: Yes
- **Allow automatic password verification**: Yes
- **Allow automatic password reconciliation**: Yes

Note the platform name — it must match `cyberark_azure_platform_id` in `terraform.tfvars` (default: `"Azure"`).

#### 3b. Create a CPM service principal for Azure AD

This service principal is what CPM uses to create and rotate Azure AD passwords. Run once.

```bash
# Create the service principal (record the appId and password output)
az ad sp create-for-rbac --name "svc-cyberark-cpm-azuread" --skip-assignment

# Grant Application.ReadWrite.OwnedBy on Microsoft Graph
az ad app permission add \
  --id <appId from above> \
  --api 00000003-0000-0000-c000-000000000002 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role

# Admin consent (requires Global Administrator)
az ad app permission admin-consent --id <appId from above>
```

Store the resulting credentials in CyberArk (in a dedicated infrastructure safe). Then configure the Azure AD platform connection settings (Step 3a) with the tenant ID and these credentials.

---

### Step 4 — Configure GitHub Actions

In GitHub → Settings → Secrets and variables → Actions, add the following **repository variables**:

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | CI runner app ID (Step 1 output) |
| `AZURE_TENANT_ID` | Azure AD tenant ID (Step 1 output) |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID (Step 1 output) |
| `CYBERARK_TENANT` | CyberArk Identity tenant ID (e.g. `ACA4779`) |
| `CYBERARK_DOMAIN` | Privilege Cloud subdomain (e.g. `mycompany`) |
| `CYBERARK_CLIENT_ID` | CyberArk service account client ID |
| `CYBERARK_CPM_USER` | CPM user name (e.g. `PasswordManager`) |
| `CYBERARK_AZURE_PLATFORM_ID` | Platform name from PVWA (Step 3a) |

Add this **repository secret**:

| Secret | Value |
|---|---|
| `CYBERARK_CLIENT_SECRET` | CyberArk service account password |

Create two GitHub Actions **environments** named `sandpit` and `prod`. Configure environment protection rules (required reviewers, deployment branch rules) as appropriate.

---

### Step 5 — Prepare the workspace

#### 5a. Generate UUIDs for Snowflake app roles

The Snowflake resource server defines two app roles — each requires a unique UUID:

```bash
uuidgen  # use for the SYSADMIN role id
uuidgen  # use for the READONLY role id
```

Open `snowflake.tf` and replace each `"00000000-0000-0000-0000-000000000000"` placeholder with one of the generated UUIDs.

#### 5b. Create tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# Azure
tenant_id       = "<your-azure-ad-tenant-id>"
subscription_id = "<your-azure-subscription-id>"
environment     = "sandpit"

# Snowflake
snowflake_resource_identifier_uri = "api://svc-snowflake-oauth-resource-sandpit"

# CyberArk
cyberark_tenant            = "<identity-tenant-id>"           # e.g. ACA4779
cyberark_domain            = "<privilege-cloud-subdomain>"    # e.g. mycompany
cyberark_client_id         = "svc-terraform@cyberark.cloud.<tenant>"
cyberark_cpm_user          = "PasswordManager"
cyberark_azure_platform_id = "Azure"    # must match platform name from Step 3a
```

Set the CyberArk client secret as an environment variable — never put it in the tfvars file:

```bash
export TF_VAR_cyberark_client_secret="<your-secret>"
```

For CI, create `sandpit.tfvars` and `prod.tfvars` with the non-sensitive values for each environment. The CI workflow picks these up automatically.

---

### Step 6 — First apply (sandpit, local)

```bash
# Authenticate to Azure
az login

# Initialise Terraform with the state backend
terraform init

# Preview what will be created — review before applying
terraform plan -var-file="terraform.tfvars"

# Apply
terraform apply -var-file="terraform.tfvars"
```

The following resources are created per environment:

| Resource | Count |
|---|---|
| `azuread_application` | one per app (resource server + 3 clients + Tableau + GitHub Actions app) |
| `azuread_service_principal` | one per app |
| `azuread_application_federated_identity_credential` | on the GitHub Actions app |
| `azuread_app_role_assignment` | per client app on the resource server |
| `cyberark_safe` | `OAuth-AppRegistrations-sandpit` |
| `cyberark_azure_account` | one per app (secret managed by CPM) |

After apply completes, print the outputs:

```bash
# All outputs
terraform output

# Snowflake SQL (needed in Step 7)
terraform output -raw snowflake_security_integration_sql

# Application IDs for each client app (needed for Snowflake user LOGIN_NAME)
terraform output snowflake_client_apps
```

---

### Step 7 — Post-apply: configure Snowflake

#### 7a. Run the security integration SQL

Log into Snowflake as `ACCOUNTADMIN` and run the full SQL block from:

```bash
terraform output -raw snowflake_security_integration_sql
```

This creates the External OAuth security integration that validates Azure AD tokens.

#### 7b. Create Snowflake users

For each client app, create a Snowflake user with `LOGIN_NAME` set to the Azure AD application ID. The token maps via `EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'appid'` — the `LOGIN_NAME` must match exactly.

```sql
-- Repeat for each app from `terraform output snowflake_client_apps`

CREATE USER svc_etl
  LOGIN_NAME = '<application_id>'
  DEFAULT_ROLE = READONLY
  DISPLAY_NAME = 'ETL Service Account';

GRANT ROLE READONLY TO USER svc_etl;
```

---

### Step 8 — Verify CPM has onboarded credentials

After `terraform apply`, CPM picks up the new accounts and creates the initial Azure AD passwords. This typically takes between a few minutes and one CPM polling interval (commonly 10–60 minutes on first onboard).

#### 8a. Check PVWA

1. Go to **Accounts** and search for `svc-snaplogic-snowflake-sandpit`
2. Confirm **Last Modified** has updated since the apply
3. Confirm **CPM Status** shows as managed (not pending or failed)
4. If the account shows a verification failure, CPM will retry automatically — wait for reconciliation before proceeding

#### 8b. Run the test scripts

Once CPM has completed the initial cycle, run the test scripts to validate the full chain end-to-end. Each test checks three things: CyberArk CP credential retrieval, Azure AD token acquisition, and token claim validation.

```bash
# bash — all apps
./scripts/bash/test-all.sh \
  --cyberark-cp-url https://cyberark-cp.example.com \
  --cyberark-app-id test-runner-sandpit \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --env sandpit

# bash — individual app
./scripts/bash/test-snowflake-oauth.sh \
  --cyberark-cp-url https://cyberark-cp.example.com \
  --cyberark-app-id test-runner-sandpit \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --app-name svc-snaplogic-snowflake \
  --env sandpit
```

```powershell
# PowerShell — all apps
.\scripts\ps\Test-All.ps1 `
  -CyberArkCpUrl https://cyberark-cp.example.com `
  -CyberArkAppId test-runner-sandpit `
  -TenantId <tenant_id> `
  -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
  -Env sandpit

# PowerShell — individual app
.\scripts\ps\Test-SnowflakeOAuth.ps1 `
  -CyberArkCpUrl https://cyberark-cp.example.com `
  -CyberArkAppId test-runner-sandpit `
  -TenantId <tenant_id> `
  -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
  -AppName svc-snaplogic-snowflake `
  -Env sandpit
```

A passing run looks like:

```
[PASS] Credentials retrieved (client_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
[PASS] Token received
[PASS] Snowflake External OAuth authentication verified
       Token is valid for Snowflake SECURITY INTEGRATION with audience api://svc-snowflake-oauth-resource-sandpit
```

For quick ad-hoc testing without CyberArk (pass credentials directly):

```bash
./scripts/bash/test-snowflake-oauth.sh \
  --client-id <appId> \
  --client-secret <secret> \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --app-name svc-snaplogic-snowflake \
  --env sandpit
```

#### 8c. Validate GitHub Actions OIDC config

```bash
./scripts/bash/test-github-actions-oidc.sh \
  --tenant-id <tenant_id> \
  --app-name svc-github-actions-azure-devops \
  --env sandpit
```

```powershell
.\scripts\ps\Test-GitHubActionsOidc.ps1 `
  -TenantId <tenant_id> `
  -AppName svc-github-actions-azure-devops `
  -Env sandpit
```

This checks Azure AD configuration only — no live GitHub Actions run required. To confirm end-to-end OIDC, trigger a workflow that uses `azure/login@v2` with `client-id: ${{ vars.AZURE_CLIENT_ID }}`.

---

### Step 9 — Push to CI

```bash
git checkout -b sandpit
git add .
git commit -m "initial oauth app registrations"
git push -u origin sandpit
```

Opening a pull request triggers `terraform plan` and posts the plan output as a PR comment. Merging to `sandpit` triggers `terraform apply`. Promoting to production is a PR from `sandpit` → `main`.

To add an environment or change configuration, edit the relevant `.tf` file or `.tfvars`, open a PR, review the plan output, then merge.

---

## App-specific configuration

### Snowflake External OAuth

Snowflake requires two app registrations to work with Azure AD External OAuth:

1. **Resource server** — represents Snowflake as a protected resource. Azure AD issues tokens with this app's identifier URI (`api://...`) as the `aud` claim. Defined in `snowflake.tf` as `module.snowflake_resource_server`.

2. **Client apps** — one per service account or pipeline. Each client app uses its client secret to request a token from Azure AD with the resource server as the audience. Defined as `module.snowflake_clients` (one instance per entry in `var.snowflake_client_apps`).

**App roles** on the resource server map 1:1 to Snowflake roles. The `value` field (e.g. `session:role:READONLY`) appears in the token's `roles` claim. The placeholder UUIDs in `snowflake.tf` must be replaced with real ones before running:

```bash
uuidgen  # run once per role
```

**After apply**, run the Snowflake SQL output in your Snowflake account as `ACCOUNTADMIN`:

```bash
terraform output -raw snowflake_security_integration_sql
```

Then create a Snowflake user for each client app, setting `LOGIN_NAME` to the client app's `application_id`:

```sql
CREATE USER svc_etl
  LOGIN_NAME = '<application_id from terraform output>'
  DEFAULT_ROLE = READONLY
  DISPLAY_NAME = 'ETL Service Account';
```

The token maps via `EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'appid'`, so the Snowflake user's `LOGIN_NAME` must match the Azure AD application (client) ID exactly.

**Adding a new Snowflake client app** — add an entry to `snowflake_client_apps` in tfvars and apply:

```hcl
snowflake_client_apps = [
  { name = "svc-snowflake-etl" },
  { name = "svc-snowflake-new-pipeline" }  # add this
]
```

### SnapLogic → Snowflake

This deployment uses an **on-premises Groundplex**. Workload Identity Federation does not apply here — WIF requires a managed identity or OIDC token source attached to the workload (e.g. Azure Managed Identity on a cloud VM). An on-prem Groundplex has no such token source, so **client credentials is the correct and only practical approach**.

Add SnapLogic to `snowflake_client_apps` and apply:

```hcl
snowflake_client_apps = [
  { name = "svc-snaplogic-snowflake" }
]
```

Terraform creates the app registration and service principal, and registers the account in CyberArk Vault. CPM then creates the initial Azure AD password and rotates it on schedule. After apply, configure SnapLogic as follows.

#### Retrieve credentials

The Groundplex retrieves credentials from CyberArk AAM/CP at startup — see [CyberArk integration](#cyberark-integration) for the consumer configuration. Credentials are never stored in Key Vault or Terraform state.

#### Snowflake user

Create a Snowflake user whose `LOGIN_NAME` matches the SnapLogic client app's `application_id` (from `terraform output snowflake_client_apps`):

```sql
CREATE USER svc_snaplogic
  LOGIN_NAME = '<application_id>'
  DEFAULT_ROLE = READONLY
  DISPLAY_NAME = 'SnapLogic Service Account';

GRANT ROLE READONLY TO USER svc_snaplogic;
```

#### SnapLogic OAuth2 Account

In the SnapLogic Designer, create an **OAuth2 Account** with the following values:

| Field | Value |
|---|---|
| OAuth2 Flow | Client Credentials |
| Token URL | `https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/token` |
| Client ID | `<client_id from Key Vault>` |
| Client Secret | `<client_secret from Key Vault>` |
| Scope | `<snowflake_resource_identifier_uri>/.default` |

The `.default` suffix on the scope instructs Azure AD to issue a token covering all statically configured app permissions — required for the client credentials flow.

#### SnapLogic Snowflake Account

Create a **Snowflake - DB Account** in SnapLogic and reference the OAuth2 Account above:

| Field | Value |
|---|---|
| JDBC URL | `jdbc:snowflake://<account>.snowflakecomputing.com/` |
| Authenticator | `oauth` |
| OAuth2 Account | *(select the account created above)* |
| Database | *(your target database)* |
| Warehouse | *(your target warehouse)* |
| Role | `READONLY` *(or whichever role was granted)* |

At pipeline runtime the Groundplex requests a token from Azure AD using the client credentials, then presents it to Snowflake as a Bearer token. The `SECURITY INTEGRATION` (from `terraform output -raw snowflake_security_integration_sql`) validates the token's signature and audience before allowing the connection.

### Matillion → Snowflake

Matillion is typically hosted on EC2 in the customer's AWS account. This means it is a cloud workload, but in AWS rather than Azure.

**WIF does not apply for EC2-hosted Matillion.** WIF requires a workload that can produce an OIDC JWT — Azure Managed Identity does this for Azure VMs, and EKS IRSA does it for Kubernetes pods. Standard EC2 instances produce AWS SigV4 credentials via IMDS, which are not OIDC tokens and cannot be trusted by Azure AD as federated credentials. Client credentials is the correct approach.

Add Matillion to `snowflake_client_apps` and apply:

```hcl
snowflake_client_apps = [
  { name = "svc-matillion-snowflake" }
]
```

#### Snowflake user

```sql
CREATE USER svc_matillion
  LOGIN_NAME = '<application_id from terraform output>'
  DEFAULT_ROLE = READONLY
  DISPLAY_NAME = 'Matillion Service Account';

GRANT ROLE READONLY TO USER svc_matillion;
```

#### Credential retrieval

Matillion retrieves credentials from CyberArk AAM/CP at startup — see [CyberArk integration](#cyberark-integration) for the consumer configuration. The EC2 instance's IAM role can be used as the AAM application identity constraint, removing any need to pre-provision credentials on the instance.

#### Matillion Snowflake connection

In Matillion, create a Snowflake connection and configure OAuth:

| Field | Value |
|---|---|
| Authentication | OAuth |
| Token Endpoint | `https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/token` |
| Client ID | `<client_id from CyberArk>` |
| Client Secret | `<client_secret from CyberArk>` |
| Scope | `<snowflake_resource_identifier_uri>/.default` |
| Account | `<account>.snowflakecomputing.com` |
| Warehouse | *(your target warehouse)* |
| Database | *(your target database)* |
| Role | `READONLY` |

### Tableau

Each entry in `tableau_apps` creates a standard service principal. Credentials are managed by CyberArk CPM. The minimum permission is `User.Read` (Microsoft Graph). Expand `api_permissions` in `tableau.tf` once the required Tableau scopes are confirmed for your deployment.

The consuming application retrieves credentials from CyberArk AAM/CP at runtime — see [CyberArk integration](#cyberark-integration).

### GitHub Actions → Azure DevOps

Each entry in `github_actions_apps` creates a service principal with one or more federated credentials. No client secret is created. The `federated_subjects` list controls which GitHub repo/branch/environment combinations are trusted.

Common subject patterns:

```hcl
federated_subjects = [
  "repo:MyOrg/my-repo:ref:refs/heads/main",        # main branch only
  "repo:MyOrg/my-repo:environment:production",      # specific environment
  "repo:MyOrg/my-repo:pull_request"                 # any PR (plan-only use)
]
```

After apply, the service principal must be added to Azure DevOps manually — the `azuread` Terraform provider does not manage ADO membership. Instructions are in `github_actions.tf`.

In the GitHub Actions workflow, authenticate using:

```yaml
- uses: azure/login@v2
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

---

## Outputs

After `terraform apply`:

| Output | Description |
|---|---|
| `snowflake_resource_server` | Application ID, SP object ID, and audience URI |
| `snowflake_client_apps` | Per-app application IDs |
| `tableau_apps` | Per-app application IDs |
| `github_actions_apps` | Application IDs and SP object IDs |
| `snowflake_security_integration_sql` | Ready-to-run SQL for Snowflake ACCOUNTADMIN |

Client secrets are not output by Terraform — they are created and held exclusively by CyberArk CPM.

```bash
# Show all outputs
terraform output

# Get just the Snowflake SQL
terraform output -raw snowflake_security_integration_sql
```

---

## Module reference

`modules/azuread-oauth-app` is self-contained and can be called from any root workspace.

| Variable | Type | Required | Description |
|---|---|---|---|
| `app_name` | string | yes | Display name of the app registration |
| `app_type` | string | yes | `secret`, `oidc`, or `snowflake_resource` |
| `federated_subjects` | list(string) | for oidc | OIDC subjects to trust |
| `api_permissions` | list(object) | no | API permissions grouped by resource app |
| `app_roles` | list(object) | no | App roles to expose on the registration |
| `identifier_uris` | list(string) | for snowflake_resource | Audience URIs |
| `owners` | list(string) | no | AAD object IDs of app owners |

| Output | Description |
|---|---|
| `application_id` | Application (client) ID |
| `object_id` | Application object ID |
| `service_principal_object_id` | Service principal object ID |
| `app_id_uri` | First identifier URI — used for Snowflake security integration |

---

## Secret rotation

Secret rotation is owned by **CyberArk CPM**. Terraform creates the app registration structure only — it does not create Azure AD passwords or write to Key Vault.

### How CPM rotation works

1. `terraform apply` creates the app registration and a CyberArk account with `sm_manage = true`. The account is seeded with a placeholder secret.
2. CPM verifies the placeholder against Azure AD — verification fails (it is not a real credential).
3. CPM performs reconciliation: it creates a real Azure AD password (new key credential), stores the value in CyberArk Vault, and marks the account as verified.
4. From this point CPM owns the lifecycle: rotation fires on the platform schedule, CPM creates a new password (create-before-destroy), and the Vault value is updated.
5. Applications retrieve the current credential from CyberArk AAM/CP — they receive the updated value automatically after each rotation cycle.

The gap between step 1 and step 3 is the CPM schedule (typically minutes to hours on first onboard). No application should attempt to use the credential until CPM has completed the initial reconciliation.

### Required permissions for CPM

The CPM user needs `Application.ReadWrite.OwnedBy` (or `Application.ReadWrite.All`) on Microsoft Graph to create and delete password credentials on Azure AD app registrations. This is in addition to any Key Vault permissions already configured.

```bash
# Grant the CPM service principal Application.ReadWrite.OwnedBy
az ad app permission add \
  --id <cpm-service-principal-app-id> \
  --api 00000003-0000-0000-c000-000000000002 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role  # Application.ReadWrite.OwnedBy

az ad app permission grant \
  --id <cpm-service-principal-app-id> \
  --api 00000003-0000-0000-c000-000000000002
```

---

## CyberArk integration

CyberArk is the authoritative source for all OAuth client secrets in this workspace. Terraform creates the Azure AD app registration structure and provisions the CyberArk safe and account objects via `cyberark.tf`. CPM then creates and rotates the Azure AD passwords independently of any Terraform run.

### Credential flow

```
Terraform apply
    └── CyberArk Vault (Safe: OAuth-AppRegistrations-<env>)
            ├── CPM (sm_manage=true): creates + rotates Azure AD password
            ├── AAM/CP → SnapLogic Groundplex (on-prem)
            ├── AAM/CP → Matillion EC2 (AWS)
            └── AAM/CP → Tableau server
```

No Azure Key Vault is required by this workspace. Terraform state contains no client secret values.

### Rotation model

| Concern | Owner |
|---|---|
| App registration structure | Terraform |
| Azure AD password (create / rotate / delete) | CyberArk CPM |
| Credential retrieval by applications | CyberArk AAM/CP |

---

### 1. Azure AD platform in PVWA

In PVWA under **Administration → Platform Management**, create or duplicate a platform for Azure AD app registrations:

- **Automatic Password Management → Allow automatic password change**: Yes — CPM creates and rotates Azure AD passwords
- **Allow automatic password verification**: Yes
- **Allow automatic password reconciliation**: Yes — CPM reconciles on first onboard (placeholder secret → real credential)
- **Connection settings**: tenant ID, CPM service principal client ID and secret (stored in a separate infrastructure safe)

The platform ID set here must match `cyberark_azure_platform_id` in `terraform.tfvars`.

---

### 2. CPM service principal for Azure AD

CPM needs a service principal with rights to create and delete password credentials on app registrations:

```bash
az ad sp create-for-rbac --name "svc-cyberark-cpm-azuread" --skip-assignment

# Grant Application.ReadWrite.OwnedBy on Microsoft Graph
az ad app permission add \
  --id <app-id-from-above> \
  --api 00000003-0000-0000-c000-000000000002 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role

az ad app permission admin-consent --id <app-id-from-above>
```

Store these credentials in CyberArk itself (in a dedicated infrastructure safe), not in a config file.

---

### 3. Safe and account creation (Terraform)

Both the safe and all accounts are created by `cyberark.tf`. Add the required variables to `terraform.tfvars`:

```hcl
cyberark_tenant            = "ABC1234"
cyberark_domain            = "mycompany"
cyberark_client_id         = "svc-terraform-ci@cyberark.cloud.ABC1234"
cyberark_client_secret     = ""    # set via env var: export TF_VAR_cyberark_client_secret=...
cyberark_cpm_user          = "PasswordManager"
cyberark_azure_platform_id = "Azure"    # platform name as shown in PVWA Platform Management
```

Add the following as GitHub Actions repository variables:

| Variable | Value |
|---|---|
| `CYBERARK_TENANT` | Identity tenant ID |
| `CYBERARK_DOMAIN` | Privilege Cloud domain |
| `CYBERARK_CLIENT_ID` | Service account client ID |
| `CYBERARK_CPM_USER` | CPM user name |
| `CYBERARK_AZURE_PLATFORM_ID` | Azure platform name from PVWA |
| `CYBERARK_CLIENT_SECRET` | **Secret** (not variable) — the service account password |

After `terraform apply`, the safe `OAuth-AppRegistrations-<env>` and one `cyberark_azure_account` per app exist in CyberArk. Accounts are created with `sm_manage = true` — CPM immediately takes ownership, creates the initial Azure AD password on first verification, and rotates on schedule thereafter.

**Accounts created** (one per app):

```
svc-snowflake-oauth-resource-<env>
svc-snowflake-etl-<env>
svc-snaplogic-snowflake-<env>
svc-matillion-snowflake-<env>
svc-tableau-datasource-<env>
```

---

### 4. Ansible alternative

If the Terraform cyberark provider is unavailable or you need to bulk-import accounts, `playbooks/cyberark-onboard-oauth.yml` does the same as `cyberark.tf`. It reads `terraform output -json` to get application IDs and creates accounts with `automatic_management_enabled: true` — CPM creates the initial password on first verification. No secret value is supplied by the playbook.

```bash
cp playbooks/vars/cyberark_settings.yml.example playbooks/vars/cyberark_settings.yml
# populate cyberark_settings.yml

ansible-playbook playbooks/cyberark-onboard-oauth.yml -e environment=sandpit
```

Do not run this playbook if `cyberark.tf` is already managing the accounts — Terraform owns the account lifecycle in that case.

---

### 5. Consumer configuration (AAM / Credential Provider)

Define an AAM application in PVWA for each consuming system under **Applications**. The application identity constraints determine which process or machine is allowed to retrieve the credential.

**SnapLogic Groundplex (on-prem)**

| Property | Value |
|---|---|
| Application ID | `snaplogic-groundplex-<env>` |
| Authentication method | OS User, IP address, or certificate hash (whichever the Groundplex process runs under) |
| Allowed safes | `OAuth-AppRegistrations-<env>` |
| Allowed accounts | `oauth-svc-snaplogic-snowflake-<env>-*` |

The Groundplex retrieves credentials via the CyberArk CP SDK or REST API at startup and passes them to the SnapLogic OAuth2 Account configuration. SnapLogic's credential caching means the application does not call CyberArk on every pipeline run — only on startup or when the cached credential fails.

**Matillion on AWS EC2**

| Property | Value |
|---|---|
| Application ID | `matillion-ec2-<env>` |
| Authentication method | IP address of the EC2 instance, or AWS IAM role ARN if using CyberArk Conjur |
| Allowed safes | `OAuth-AppRegistrations-<env>` |
| Allowed accounts | `oauth-svc-matillion-snowflake-<env>-*` |

Matillion retrieves credentials at instance startup via a bootstrap script that calls the CyberArk CP REST API, then writes them to Matillion's encrypted credential store. The EC2 instance's security group should restrict outbound access to the CyberArk CP endpoint.

---

### 6. Rotation lifecycle

```
1. CPM rotation schedule fires (configured on the Azure AD platform in PVWA)

2. CPM creates a new Azure AD password (create-before-destroy — no outage)
   ├── New password credential created on the app registration
   ├── CyberArk Vault value updated
   └── Old password credential deleted from Azure AD

3. Application next retrieval via AAM/CP returns new value
   └── No application reconfiguration needed
```

Rotation is independent of Terraform. No `terraform apply` is required for credential rotation.

**Emergency rotation** (PVWA or REST API):

```bash
# Trigger immediate rotation via CyberArk REST API
curl -X POST "https://<pvwa>/PasswordVault/API/Accounts/<account-id>/Change" \
  -H "Authorization: Bearer <session-token>"
```

---

### 7. Verification after rotation

After each rotation cycle, verify the chain end-to-end:

```bash
# 1. Confirm CyberArk account last modified date (PVWA account details or REST API)
curl "https://<pvwa>/PasswordVault/API/Accounts?search=svc-snaplogic-snowflake-<env>" \
  -H "Authorization: Bearer <session-token>"

# 2. Test retrieval via CyberArk CP
curl "https://<cyberark-cp>/AIMWebService/api/Accounts?AppID=snaplogic-groundplex-<env>&Safe=OAuth-AppRegistrations-<env>&Object=svc-snaplogic-snowflake-<env>"

# 3. Test that the retrieved secret produces a valid Azure AD token
CLIENT_ID=$(az ad app list --display-name svc-snaplogic-snowflake-<env> --query "[0].appId" -o tsv)
CLIENT_SECRET=<secret from step 2>
curl -X POST "https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/token" \
  -d "client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=<identifier_uri>/.default&grant_type=client_credentials"
# Should return {"token_type":"Bearer","expires_in":3599,...}
```

Or use the test scripts (bash or PowerShell):

```bash
# bash — single app
./scripts/bash/test-snowflake-oauth.sh \
  --cyberark-cp-url https://cyberark-cp.example.com \
  --cyberark-app-id test-runner-sandpit \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --app-name svc-snaplogic-snowflake \
  --env sandpit

# bash — all apps
./scripts/bash/test-all.sh \
  --cyberark-cp-url https://cyberark-cp.example.com \
  --cyberark-app-id test-runner-sandpit \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --env sandpit
```

```powershell
# PowerShell — single app
.\scripts\ps\Test-SnowflakeOAuth.ps1 `
  -CyberArkCpUrl https://cyberark-cp.example.com `
  -CyberArkAppId test-runner-sandpit `
  -TenantId <tenant_id> `
  -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
  -AppName svc-snaplogic-snowflake `
  -Env sandpit

# PowerShell — all apps
.\scripts\ps\Test-All.ps1 `
  -CyberArkCpUrl https://cyberark-cp.example.com `
  -CyberArkAppId test-runner-sandpit `
  -TenantId <tenant_id> `
  -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
  -Env sandpit
```

A successful token exchange confirms the full chain: Terraform app registration → CyberArk CPM credential → AAM/CP retrieval → Azure AD token → Snowflake.

---

## Terraform state backend

State is stored in an **Azure Storage Account blob container**, configured in `main.tf`:

```hcl
backend "azurerm" {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = "stterraformstate"
  container_name       = "oauth-apps"
  key                  = "oauth-apps.tfstate"
}
```

Update these four values to match your environment before running `terraform init`. The storage account and container must exist first — Terraform will not create them.

### Provisioning the storage account

```bash
az group create \
  --name rg-terraform-state \
  --location "UK South"

az storage account create \
  --name stterraformstate \
  --resource-group rg-terraform-state \
  --sku Standard_LRS \
  --allow-blob-public-access false \
  --min-tls-version TLS1_2 \
  --https-only true

az storage account blob-service-properties update \
  --account-name stterraformstate \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30

az storage container create \
  --name oauth-apps \
  --account-name stterraformstate \
  --auth-mode login
```

### What is in the state file

The state file is not encrypted at rest beyond Azure Storage's default service-managed encryption. It contains:

- Azure AD object IDs and application IDs
- Tenant and subscription IDs
- CyberArk safe and account metadata

**Client secrets are not in the state file.** This workspace does not create Azure AD passwords — CyberArk CPM does. No sensitive credential values are ever written to Terraform state.

### Securing the storage account

| Control | Configuration |
|---|---|
| Public access | Disabled — enforced by `--allow-blob-public-access false` above |
| Shared key access | Disable if your organisation policy permits — forces AAD-only auth: `az storage account update --name stterraformstate --allow-shared-key-access false` |
| RBAC access | Grant the CI runner `Storage Blob Data Contributor` on the container only, not the full storage account |
| Versioning | Enabled — allows recovery if state is corrupted or accidentally overwritten |
| Soft delete | Enabled with 30-day retention — protects against accidental deletion |
| Diagnostic logs | Enable storage account diagnostic logs to audit who reads or writes the state blob |
| Network access | Restrict to known IP ranges or a private endpoint if your environment supports it |

### Granting the CI runner access

```bash
# Get the CI runner's service principal object ID
SP_OBJECT_ID=$(az ad sp show --id <AZURE_CLIENT_ID> --query id -o tsv)

# Scope access to the container, not the full storage account
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show --name stterraformstate --query id -o tsv)/blobServices/default/containers/oauth-apps"
```

No other identity should have write access to the state container.

### Separate state per environment

Use separate containers for sandpit and production to prevent a sandpit pipeline from touching production state:

```bash
az storage container create --name oauth-apps-sandpit --account-name stterraformstate --auth-mode login
az storage container create --name oauth-apps-prod    --account-name stterraformstate --auth-mode login
```

Update `container_name` in the backend block (or pass via `-backend-config`) per environment.

---

## Security notes

- `terraform.tfvars` is gitignored — never commit files containing real tenant IDs, subscription IDs, or object IDs.
- The CI runner uses `Application.ReadWrite.OwnedBy` — it can only modify app registrations it owns, limiting blast radius if the runner is compromised. Upgrade to `Application.ReadWrite.All` only if you need to manage pre-existing registrations.
- Client secrets never appear in Terraform state, Key Vault, or CI logs — they are created and held exclusively by CyberArk CPM.
- OIDC federated subjects are scoped to specific repos and branches. Avoid wildcards.
- gitleaks runs on every push and PR to detect any accidentally committed secrets before they reach the remote.

---

## CI/CD

The workflow (`.github/workflows/terraform.yml`) runs three parallel jobs on every push and PR:

| Job | Runs when | Purpose |
|---|---|---|
| `secret-scan` | always | gitleaks secret scan via [TobyAnscombe/github-actions](https://github.com/TobyAnscombe/github-actions) — full history, SARIF uploaded to Security tab |
| `validate` | always | `terraform validate` + tflint — no Azure credentials required |
| `terraform` | after secret-scan + validate pass | plan on PR, apply on push |

The `terraform` job gates on `secret-scan` and `validate` — a failed scan or lint error blocks apply.

### Required GitHub Actions variables and secrets

Add the following as **repository variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | CI runner service principal app ID (from bootstrap script) |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `CYBERARK_TENANT` | CyberArk Identity tenant ID |
| `CYBERARK_DOMAIN` | CyberArk Privilege Cloud domain |
| `CYBERARK_CLIENT_ID` | CyberArk service account client ID |
| `CYBERARK_CPM_USER` | CPM user name (e.g. `PasswordManager`) |
| `CYBERARK_AZURE_PLATFORM_ID` | Azure platform name from PVWA |

Add the following as **repository secrets**:

| Secret | Value |
|---|---|
| `CYBERARK_CLIENT_SECRET` | CyberArk service account password |

---

## Annex A — Getting to a testable state

This annex walks through the steps needed to go from a completed `terraform apply` to a point where the test scripts produce a passing result. Work through each stage in order — each one is a pre-condition for the next.

---

### Stage 1 — Verify the Azure AD app registrations exist

After `terraform apply`, confirm the app registrations are visible in Azure AD before doing anything else.

```bash
# List all apps created for this environment
az ad app list \
  --query "[?contains(displayName, '-sandpit')].{name:displayName, appId:appId}" \
  -o table
```

You should see one row per app:

```
Name                                         AppId
-------------------------------------------  ------------------------------------
svc-snowflake-oauth-resource-sandpit         xxxxxxxx-...
svc-snowflake-etl-sandpit                    xxxxxxxx-...
svc-snaplogic-snowflake-sandpit              xxxxxxxx-...
svc-matillion-snowflake-sandpit              xxxxxxxx-...
svc-tableau-datasource-sandpit               xxxxxxxx-...
svc-github-actions-azure-devops-sandpit      xxxxxxxx-...
```

If any are missing, re-run `terraform apply`.

Check that the resource server has its app roles configured (required for the Snowflake token `roles` claim):

```bash
RESOURCE_ID=$(az ad app list --display-name svc-snowflake-oauth-resource-sandpit --query "[0].id" -o tsv)
az ad app show --id "$RESOURCE_ID" --query "appRoles[].{value:value, displayName:displayName}" -o table
```

Expected:

```
Value                DisplayName
-------------------  -----------
session:role:SYSADMIN  SYSADMIN
session:role:READONLY  READONLY
```

If no roles appear, check that the UUIDs in `snowflake.tf` were replaced (Step 5a) and re-apply.

---

### Stage 2 — Verify CPM has completed the initial onboard

After `terraform apply` creates the CyberArk accounts, CPM picks them up and attempts verification. The placeholder secret (`PENDING_CPM_ROTATION`) fails verification, which triggers reconciliation — CPM creates a real Azure AD password and stores it in the Vault. This is the initial onboard cycle.

**What you are waiting for**: CPM status changes from `Unverified` or `InProcess` to `Success`.

#### 2a. Check via PVWA

1. Log into PVWA → **Accounts**
2. Filter by safe: `OAuth-AppRegistrations-sandpit`
3. For each account, check:
   - **CPM Status** column: must be **Success**
   - **Last Password Change**: must be a timestamp *after* the `terraform apply` date

If the status shows **Failure**: open the account, expand **CPM Details**, and read the failure reason. Common causes:
- CPM service principal lacks `Application.ReadWrite.OwnedBy` on Microsoft Graph (Step 3b of Getting started)
- Azure AD platform connection settings are wrong (wrong tenant ID or CPM SP credentials)

If the status shows **InProcess** or blank: CPM is still working — wait 5–10 minutes and refresh.

#### 2b. Check via REST API (optional)

```bash
# Authenticate to PVWA
SESSION=$(curl -s -X POST "https://<pvwa>/PasswordVault/API/auth/CyberArk/Logon" \
  -H "Content-Type: application/json" \
  -d '{"username":"<user>","password":"<pass>"}' | tr -d '"')

# Query the account
curl -s "https://<pvwa>/PasswordVault/API/Accounts?search=svc-snaplogic-snowflake-sandpit&safeName=OAuth-AppRegistrations-sandpit" \
  -H "Authorization: Bearer $SESSION" | python3 -m json.tool
```

Look for `"cpmStatus": "success"` in the response. Do not proceed to Stage 3 until at least one account shows success.

---

### Stage 3 — Test the Azure AD token flow (direct mode)

Before configuring the AAM Application, prove that the Azure AD layer works correctly using a credential retrieved manually from PVWA. This isolates the token flow from the CyberArk CP retrieval path — if this stage fails, there is a problem with the Azure AD configuration, not with CyberArk.

#### 3a. Retrieve the current credential from PVWA

1. In PVWA → **Accounts** → open `svc-snaplogic-snowflake-sandpit`
2. Note the **Username** field — this is the Azure AD `application_id` (client ID)
3. Click **Show** or **Copy** to retrieve the current password

Keep the password secure. You will use it only for this test.

#### 3b. Run a test in direct mode

```bash
# bash
./scripts/bash/test-snowflake-oauth.sh \
  --client-id <username/application_id from PVWA> \
  --client-secret "<password from PVWA>" \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --app-name svc-snaplogic-snowflake \
  --env sandpit
```

```powershell
# PowerShell
.\scripts\ps\Test-SnowflakeOAuth.ps1 `
  -ClientId <username/application_id from PVWA> `
  -ClientSecret "<password from PVWA>" `
  -TenantId <tenant_id> `
  -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
  -AppName svc-snaplogic-snowflake `
  -Env sandpit
```

A passing result confirms:

- The Snowflake resource server and client app are correctly linked in Azure AD
- The app role assignments are in place
- The token `aud` claim matches the `identifier_uri` and the `appid` claim matches the client app

**Do not proceed to Stage 4 if this fails.** Resolve the Azure AD issue first — there is no point debugging the CyberArk AAM path if the token flow itself is broken.

Run the same test for Tableau:

```bash
./scripts/bash/test-tableau-oauth.sh \
  --client-id <application_id> \
  --client-secret "<password>" \
  --tenant-id <tenant_id> \
  --app-name svc-tableau-datasource \
  --env sandpit
```

---

### Stage 4 — Configure the AAM test runner application in PVWA

The `--cyberark-app-id` parameter in the test scripts corresponds to a **CyberArk Application** object in PVWA. This object tells the CP service which callers are permitted to retrieve credentials from which safes.

#### 4a. Create the application

In PVWA → **Applications → Add Application**:

| Field | Value |
|---|---|
| Application ID | `test-runner-sandpit` *(must match the `--cyberark-app-id` argument)* |
| Description | `Test runner for OAuth app registration validation` |
| Location | `/` |

Click **OK** to save.

#### 4b. Add the allowed safe

On the application detail page → **Allowed Safes → Add Safe**:

- Safe name: `OAuth-AppRegistrations-sandpit`

This grants the application permission to retrieve any account from this safe via the CP REST API.

#### 4c. Add an identity constraint

Click **Allowed Machines** (or **Authentication Methods** depending on your PVWA version) → **Add**:

| Identity type | When to use |
|---|---|
| **IP address** | Workstation — add your machine's IP as seen by the CP server |
| **OS User** | Add the OS username running the test script |
| **Certificate** | Pipeline runners — more secure; requires a client certificate on the caller |

For workstation testing, IP address is the simplest. Enter your source IP — if you are behind NAT or a VPN, use the IP that the CP server will see, not necessarily your local LAN IP. You can confirm the correct IP by checking the CP server's access log after a failed request.

Multiple identity entries are combined with OR — add both IP and OS User if needed.

#### 4d. Verify the CP Provider user can read the safe

The CyberArk CP service runs as a vault user named `Prov_<hostname>` (or similar, depending on your installation). This user must have **Retrieve accounts** permission on the OAuth safe.

In PVWA → **Safes** → `OAuth-AppRegistrations-sandpit` → **Members**:

- Check whether a `Prov_` user is already listed
- If not: click **Add Member**, search for `Prov_`, select your CP host user, and assign the **CP User** built-in role (grants Retrieve only)

> On many installations this is automatic. If your CP has already been used with other safes, the Provider user is likely already present.

---

### Stage 5 — Run the full test suite (CyberArk mode)

With all prior stages complete, run the full suite:

```bash
# bash — all apps
./scripts/bash/test-all.sh \
  --cyberark-cp-url https://<cyberark-cp-hostname> \
  --cyberark-app-id test-runner-sandpit \
  --tenant-id <tenant_id> \
  --identifier-uri api://svc-snowflake-oauth-resource-sandpit \
  --env sandpit
```

```powershell
# PowerShell — all apps
.\scripts\ps\Test-All.ps1 `
  -CyberArkCpUrl https://<cyberark-cp-hostname> `
  -CyberArkAppId test-runner-sandpit `
  -TenantId <tenant_id> `
  -IdentifierUri api://svc-snowflake-oauth-resource-sandpit `
  -Env sandpit
```

Expected final output:

```
======================================================================
 RESULTS: 5 passed, 0 failed
======================================================================
```

The five tests are: Snowflake ETL client, SnapLogic, Matillion, Tableau, and GitHub Actions OIDC config check.

---

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `[FAIL] App registration '...' not found in Azure AD` | `terraform apply` has not run | Run `terraform apply` and re-check Stage 1 |
| `[FAIL] No app roles found on resource server` | Placeholder UUIDs not replaced | Replace UUIDs in `snowflake.tf` (Step 5a) and re-apply |
| `[FAIL] CyberArk CP request failed` — HTTP 403 | Identity constraint not matched | Confirm your source IP in PVWA application allowed machines; check Provider user is a safe member |
| `[FAIL] CyberArk CP request failed` — connection error | CP URL unreachable | Verify network path to CP server; confirm CP service is running |
| `[FAIL] Could not parse Content field` | Account exists but CPM has not yet rotated | Check Stage 2 — CPM status must be `Success` before using CP retrieval |
| `[FAIL] No access_token` with `AADSTS700016` | Wrong client ID | Confirm `application_id` in PVWA Username field matches `az ad app show --id <id> --query appId` |
| `[FAIL] No access_token` with `AADSTS7000215` | Credential mismatch — CPM placeholder still being used | CPM initial reconciliation not complete — wait and recheck Stage 2 |
| `[FAIL] Unexpected audience` | Wrong `--identifier-uri` | Run `terraform output snowflake_resource_server` and use the `app_id_uri` value |
| `[FAIL] No federated credentials found` (OIDC test) | `terraform apply` not run or wrong `app_type` | Verify `github_actions.tf` has `app_type = "oidc"` and re-apply |
