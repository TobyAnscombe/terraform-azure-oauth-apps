# Resource server — represents Snowflake as a protected OAuth resource.
# Azure AD issues tokens with this app's identifier URI as the audience.
module "snowflake_resource_server" {
  source = "./modules/azuread-oauth-app"

  app_name        = "${var.snowflake_resource_server_name}-${var.environment}"
  app_type        = "snowflake_resource"
  identifier_uris = [var.snowflake_resource_identifier_uri]
  owners          = var.app_owners

  # App roles map 1:1 to Snowflake roles. The 'value' field appears in the
  # token 'roles' claim and can be used with EXTERNAL_OAUTH_SCOPE_MAPPING.
  # Add additional roles as required; each id must be a unique UUID.
  app_roles = [
    {
      id           = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
      display_name = "SYSADMIN"
      description  = "Snowflake SYSADMIN role"
      value        = "session:role:SYSADMIN"
    },
    {
      id           = "b2c3d4e5-f6a7-8901-bcde-f01234567891"
      display_name = "READONLY"
      description  = "Snowflake read-only role"
      value        = "session:role:READONLY"
    }
  ]
}

# Client apps — one per service account / use case.
# Each client app authenticates to Snowflake using the resource server above.
module "snowflake_clients" {
  for_each = { for app in var.snowflake_client_apps : app.name => app }
  source   = "./modules/azuread-oauth-app"

  app_name = "${each.value.name}-${var.environment}"
  app_type = "secret"
  owners   = var.app_owners

  # Request access to the Snowflake resource server.
  # The permission ID must match an app role ID from the resource server above.
  api_permissions = [
    {
      resource_app_id = module.snowflake_resource_server.application_id
      permissions = [
        {
          id   = "a1b2c3d4-e5f6-7890-abcd-ef1234567890" # SYSADMIN role id
          type = "Role"
        }
      ]
    }
  ]
}

# Grant each client service principal the SYSADMIN app role on the resource server.
# Without this assignment the token will not contain the role claim.
resource "azuread_app_role_assignment" "snowflake_client_role" {
  for_each = module.snowflake_clients

  app_role_id         = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  principal_object_id = each.value.service_principal_object_id
  resource_object_id  = module.snowflake_resource_server.service_principal_object_id
}
