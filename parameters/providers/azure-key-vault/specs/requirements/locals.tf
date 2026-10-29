locals {
  # Vault created by this module (if any), folded into the SP's RBAC scope.
  created_vault_ids = var.key_vault.enable ? [azurerm_key_vault.this[0].id] : []

  # One role assignment per vault the service principal should reach:
  # caller-supplied external ids plus any vault created here. Empty (no
  # assignments) when the service-principal grant is disabled.
  vault_ids = var.service_principal.enable ? {
    for id in concat(var.service_principal.key_vault_ids, local.created_vault_ids) : id => id
  } : {}
}
