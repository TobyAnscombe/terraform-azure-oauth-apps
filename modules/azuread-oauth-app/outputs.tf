output "application_id" {
  description = "Application (client) ID — use as client_id in OAuth flows"
  value       = azuread_application.this.application_id
}

output "object_id" {
  description = "Application object ID"
  value       = azuread_application.this.object_id
}

output "service_principal_object_id" {
  description = "Service principal object ID — use for role assignments"
  value       = azuread_service_principal.this.object_id
}

output "app_id_uri" {
  description = "First identifier URI (audience) — used to configure Snowflake security integration"
  value       = length(var.identifier_uris) > 0 ? var.identifier_uris[0] : null
}
