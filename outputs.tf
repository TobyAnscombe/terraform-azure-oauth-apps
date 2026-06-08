output "snowflake_resource_server" {
  description = "Snowflake External OAuth resource server details"
  value = {
    application_id              = module.snowflake_resource_server.application_id
    service_principal_object_id = module.snowflake_resource_server.service_principal_object_id
    app_id_uri                  = module.snowflake_resource_server.app_id_uri
  }
}

output "snowflake_client_apps" {
  description = "Snowflake client app registrations"
  value = {
    for name, mod in module.snowflake_clients : name => {
      application_id = mod.application_id
    }
  }
}

output "tableau_apps" {
  description = "Tableau app registrations"
  value = {
    for name, mod in module.tableau_apps : name => {
      application_id = mod.application_id
    }
  }
}

output "github_actions_apps" {
  description = "GitHub Actions workload identity app registrations"
  value = {
    for name, mod in module.github_actions_apps : name => {
      application_id              = mod.application_id
      service_principal_object_id = mod.service_principal_object_id
    }
  }
}

output "snowflake_security_integration_sql" {
  description = "Copy-paste SQL to run in Snowflake to configure External OAuth"
  value       = <<-EOT
    -- Run the following in Snowflake as ACCOUNTADMIN
    -- Snowflake users for service accounts should have LOGIN_NAME set to the
    -- client app's application_id (available in snowflake_client_apps output).

    CREATE OR REPLACE SECURITY INTEGRATION snowflake_external_oauth_azure_${var.environment}
      TYPE = EXTERNAL_OAUTH
      ENABLED = TRUE
      EXTERNAL_OAUTH_TYPE = AZURE
      EXTERNAL_OAUTH_ISSUER = 'https://sts.windows.net/${var.tenant_id}/'
      EXTERNAL_OAUTH_JWS_KEYS_URL = 'https://login.microsoftonline.com/${var.tenant_id}/discovery/v2.0/keys'
      EXTERNAL_OAUTH_AUDIENCE_LIST = ('${var.snowflake_resource_identifier_uri}')
      EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'appid'
      EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'login_name';

    -- For each service account, create a Snowflake user matched to the client app:
    -- CREATE USER svc_etl_user
    --   LOGIN_NAME = '<application_id from snowflake_client_apps output>'
    --   DEFAULT_ROLE = READONLY
    --   DISPLAY_NAME = 'ETL Service Account';
  EOT
}
