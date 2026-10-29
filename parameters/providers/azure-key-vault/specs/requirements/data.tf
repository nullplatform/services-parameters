################################################################################
# Optionally grant an existing Azure AD service principal Key Vault access via
# Azure RBAC, and/or create the Key Vault itself. Toggled independently by
# var.service_principal.enable and var.key_vault.enable. This module does NOT
# create the service principal or handle its client secret — the secret is wired
# into the agent environment directly and never passes through tofu state.
################################################################################

# Tenant tofu authenticates against (wired into the agent as AZURE_TENANT_ID).
data "azurerm_client_config" "current" {}
