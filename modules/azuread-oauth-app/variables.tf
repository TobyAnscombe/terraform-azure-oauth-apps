variable "app_name" {
  type        = string
  description = "Display name for the Azure AD app registration"
}

variable "app_type" {
  type        = string
  description = "Type of app: 'secret' (client secret managed by CyberArk CPM), 'oidc' (workload identity), 'snowflake_resource' (External OAuth resource server)"
  validation {
    condition     = contains(["secret", "oidc", "snowflake_resource"], var.app_type)
    error_message = "app_type must be one of: secret, oidc, snowflake_resource"
  }
}

variable "federated_subjects" {
  type        = list(string)
  description = "OIDC subjects for workload identity federation (e.g. 'repo:org/repo:ref:refs/heads/main')"
  default     = []
}

variable "api_permissions" {
  type = list(object({
    resource_app_id = string
    permissions = list(object({
      id   = string
      type = string # "Scope" for delegated, "Role" for application
    }))
  }))
  description = "API permissions grouped by resource application"
  default     = []
}

variable "app_roles" {
  type = list(object({
    id           = string # UUID — must be unique within the app
    display_name = string
    description  = string
    value        = string # Claim value emitted in the token 'roles' array
  }))
  description = "App roles to expose (used by Snowflake resource server for role mapping)"
  default     = []
}

variable "identifier_uris" {
  type        = list(string)
  description = "Application ID URIs (audience). Required for Snowflake resource server. Format: api://<descriptive-name>"
  default     = []
}

variable "owners" {
  type        = list(string)
  description = "Object IDs of Azure AD users who own this app registration"
  default     = []
}
