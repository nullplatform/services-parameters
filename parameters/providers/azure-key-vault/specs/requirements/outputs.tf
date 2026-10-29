output "service_principal_object_id" {
  description = "Object (principal) ID of the existing service principal the Key Vault role was assigned to. Empty when service_principal.enable=false."
  value       = length(data.azuread_service_principal.this) > 0 ? data.azuread_service_principal.this[0].object_id : ""
}

output "tenant_id" {
  description = "Tenant ID tofu authenticates against. Wire into the agent as AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "vault_id" {
  description = "Resource ID of the Key Vault created by this module (the RBAC scope target). Empty when key_vault.enable=false."
  value       = length(azurerm_key_vault.this) > 0 ? azurerm_key_vault.this[0].id : ""
}

output "vault_uri" {
  description = "URI of the Key Vault created by this module. Empty when key_vault.enable=false."
  value       = length(azurerm_key_vault.this) > 0 ? azurerm_key_vault.this[0].vault_uri : ""
}
