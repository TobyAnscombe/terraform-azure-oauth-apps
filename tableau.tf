module "tableau_apps" {
  for_each = { for app in var.tableau_apps : app.name => app }
  source   = "./modules/azuread-oauth-app"

  app_name = "${each.value.name}-${var.environment}"
  app_type = "secret"
  owners   = var.app_owners

  # Baseline: User.Read allows the service principal to read its own profile.
  # Expand permissions here once Tableau's required scopes are confirmed.
  # Common additions: Sites.Read.All, Reports.Read.All for Power BI data sources.
  api_permissions = [
    {
      resource_app_id = local.msgraph_app_id
      permissions = [
        {
          id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read (delegated)
          type = "Scope"
        }
      ]
    }
  ]
}
