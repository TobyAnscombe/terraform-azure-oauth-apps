module "github_actions_apps" {
  for_each = { for app in var.github_actions_apps : app.name => app }
  source   = "./modules/azuread-oauth-app"

  app_name           = "${each.value.name}-${var.environment}"
  app_type           = "oidc"
  federated_subjects = each.value.federated_subjects
  owners             = var.app_owners
  tags               = local.common_tags
}

# --- Azure DevOps access ---
# The service principal needs to be added to Azure DevOps project(s) manually
# (or via az devops CLI) since ADO access is not managed by the azuread provider.
#
# After apply, run once per project:
#
#   az devops project list --org https://dev.azure.com/<org>
#   az devops team add-member \
#     --project <project> \
#     --team "<project> Team" \
#     --member-id $(az ad sp show --id <application_id> --query id -o tsv)
#
# The application_id for each app is available in outputs.tf.
