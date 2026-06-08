terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
  }
}

locals {
  create_oidc = var.app_type == "oidc"
}

resource "azuread_application" "this" {
  display_name    = var.app_name
  identifier_uris = var.identifier_uris
  owners          = var.owners

  dynamic "required_resource_access" {
    for_each = var.api_permissions
    content {
      resource_app_id = required_resource_access.value.resource_app_id

      dynamic "resource_access" {
        for_each = required_resource_access.value.permissions
        content {
          id   = resource_access.value.id
          type = resource_access.value.type
        }
      }
    }
  }

  dynamic "app_role" {
    for_each = var.app_roles
    content {
      allowed_member_types = ["Application"]
      description          = app_role.value.description
      display_name         = app_role.value.display_name
      enabled              = true
      id                   = app_role.value.id
      value                = app_role.value.value
    }
  }

  web {
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }
}

resource "azuread_service_principal" "this" {
  client_id = azuread_application.this.client_id
  owners    = var.owners
}

resource "azuread_application_federated_identity_credential" "this" {
  for_each              = local.create_oidc ? toset(var.federated_subjects) : toset([])
  application_object_id = azuread_application.this.object_id
  display_name          = "oidc-${substr(sha256(each.value), 0, 8)}"
  description           = "Workload identity: ${each.value}"
  audiences             = ["api://AzureADTokenExchange"]
  issuer                = "https://token.actions.githubusercontent.com"
  subject               = each.value
}
