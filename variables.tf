variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID"
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "environment" {
  type        = string
  description = "Environment label applied to resource names and tags (e.g. sandpit, prod)"
  default     = "sandpit"
}

variable "app_owners" {
  type        = list(string)
  description = "Azure AD object IDs set as owners on all created app registrations"
  default     = []
}

# --- Snowflake ---

variable "snowflake_resource_server_name" {
  type        = string
  description = "Display name for the Snowflake External OAuth resource server app"
  default     = "svc-snowflake-oauth-resource"
}

variable "snowflake_resource_identifier_uri" {
  type        = string
  description = "Audience URI for the Snowflake resource server, e.g. api://svc-snowflake-oauth-resource-sandpit"
}

variable "snowflake_client_apps" {
  type = list(object({
    name = string # e.g. "svc-snowflake-etl"
  }))
  description = "Client app registrations that authenticate to Snowflake via External OAuth"
  default     = []
}

# --- Tableau ---

variable "tableau_apps" {
  type = list(object({
    name = string # e.g. "svc-tableau-reporting"
  }))
  description = "App registrations for Tableau service account authentication"
  default     = []
}

# --- GitHub Actions ---

# --- CyberArk ---

variable "cyberark_tenant" {
  type        = string
  description = "CyberArk Identity tenant ID (e.g. ABC1234) — forms <tenant>.id.cyberark.cloud"
}

variable "cyberark_domain" {
  type        = string
  description = "CyberArk Privilege Cloud domain (e.g. mycompany)"
}

variable "cyberark_client_id" {
  type        = string
  description = "CyberArk service account client ID (formatted as username@cyberark.cloud.<tenant>)"
}

variable "cyberark_client_secret" {
  type        = string
  sensitive   = true
  description = "CyberArk service account client secret"
}

variable "cyberark_cpm_user" {
  type        = string
  description = "CPM user assigned as safe owner (e.g. PasswordManager)"
  default     = "PasswordManager"
}

variable "cyberark_azure_platform_id" {
  type        = string
  description = "CyberArk platform ID for Azure app registration accounts (configured in PVWA Platform Management)"
  default     = "Azure"
}

# --- GitHub Actions ---

variable "github_actions_apps" {
  type = list(object({
    name               = string       # e.g. "svc-github-actions-azure-devops"
    federated_subjects = list(string) # OIDC subjects: repo:org/repo:ref:refs/heads/main
  }))
  description = "Workload identity federation apps for GitHub Actions to Azure authentication (no client secret)"
  default     = []
}
