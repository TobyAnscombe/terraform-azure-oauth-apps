terraform {
  required_providers {
    cyberark = {
      source  = "cyberark/cyberark"
      version = "~> 1.0"
    }
  }
}

provider "cyberark" {
  tenant        = var.cyberark_tenant
  domain        = var.cyberark_domain
  client_id     = var.cyberark_client_id
  client_secret = var.cyberark_client_secret
}

# Safe — created once, owns all OAuth accounts for this environment.
resource "cyberark_safe" "oauth_registrations" {
  safe_name        = "OAuth-AppRegistrations-${var.environment}"
  description      = "OAuth client credentials for Azure AD app registrations — managed by Terraform, rotated by CyberArk CPM"
  member           = var.cyberark_cpm_user
  member_type      = "user"
  permission_level = "full"
  managing_cpm     = var.cyberark_cpm_user

  number_of_days_retention = 7
}

locals {
  # Address used for all Azure AD app accounts — scoped to the tenant
  aad_address = "login.microsoftonline.com/${var.tenant_id}"
}

# Snowflake External OAuth resource server
resource "cyberark_azure_account" "snowflake_resource_server" {
  name          = "${var.snowflake_resource_server_name}-${var.environment}"
  safe          = cyberark_safe.oauth_registrations.safe_name
  platform      = var.cyberark_azure_platform_id
  username      = module.snowflake_resource_server.application_id
  secret        = "PENDING_CPM_ROTATION"
  ms_app_id     = module.snowflake_resource_server.application_id
  ms_app_obj_id = module.snowflake_resource_server.object_id
  address       = local.aad_address
  sm_manage     = true

  lifecycle {
    # CPM creates and rotates the Azure AD password — ignore Vault-side value drift
    ignore_changes = [secret]
  }
}

# Snowflake client apps — one account per entry in snowflake_client_apps
resource "cyberark_azure_account" "snowflake_clients" {
  for_each = module.snowflake_clients

  name          = "${each.key}-${var.environment}"
  safe          = cyberark_safe.oauth_registrations.safe_name
  platform      = var.cyberark_azure_platform_id
  username      = each.value.application_id
  secret        = "PENDING_CPM_ROTATION"
  ms_app_id     = each.value.application_id
  ms_app_obj_id = each.value.object_id
  address       = local.aad_address
  sm_manage     = true

  lifecycle {
    ignore_changes = [secret]
  }
}

# Tableau apps
resource "cyberark_azure_account" "tableau" {
  for_each = module.tableau_apps

  name          = "${each.key}-${var.environment}"
  safe          = cyberark_safe.oauth_registrations.safe_name
  platform      = var.cyberark_azure_platform_id
  username      = each.value.application_id
  secret        = "PENDING_CPM_ROTATION"
  ms_app_id     = each.value.application_id
  ms_app_obj_id = each.value.object_id
  address       = local.aad_address
  sm_manage     = true

  lifecycle {
    ignore_changes = [secret]
  }
}
