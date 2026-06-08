locals {
  common_tags = {
    environment = var.environment
    managed_by  = "terraform"
  }

  # Microsoft Graph well-known application ID (constant across all tenants)
  msgraph_app_id = "00000003-0000-0000-c000-000000000002"
}
