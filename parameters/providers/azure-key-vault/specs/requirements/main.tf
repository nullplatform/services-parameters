resource "terraform_data" "validation" {
  lifecycle {
    # Cross-variable check: an enabled role assignment needs at least one vault to
    # scope to — either external ids or a vault created here (var.key_vault).
    precondition {
      condition     = !var.service_principal.enable || length(var.service_principal.key_vault_ids) > 0 || var.key_vault.enable
      error_message = "When service_principal.enable=true, scope the role to at least one vault: set service_principal.key_vault_ids and/or enable key_vault to create one."
    }
  }
}

# Resolve the existing service principal's object (principal) id from its client
# (application) id — this is the RBAC principal the role assignment targets.
data "azuread_service_principal" "this" {
  count     = var.service_principal.enable ? 1 : 0
  client_id = var.service_principal.client_id
}

resource "azurerm_role_assignment" "this" {
  for_each = local.vault_ids

  scope                = each.value
  role_definition_name = var.service_principal.role
  principal_id         = data.azuread_service_principal.this[0].object_id
}

resource "azurerm_key_vault" "this" {
  count = var.key_vault.enable ? 1 : 0

  name                = var.key_vault.name
  resource_group_name = var.key_vault.resource_group_name
  location            = var.key_vault.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = var.key_vault.sku_name

  # Required by this provider: RBAC data-plane authorization, not access policies.
  rbac_authorization_enabled = true

  # Hardened data-plane defaults (overridable via var.key_vault).
  purge_protection_enabled      = var.key_vault.purge_protection_enabled
  soft_delete_retention_days    = var.key_vault.soft_delete_retention_days
  public_network_access_enabled = var.key_vault.public_network_access_enabled

  tags = var.key_vault.tags

  dynamic "network_acls" {
    for_each = var.key_vault.network_acls != null ? [var.key_vault.network_acls] : []
    content {
      default_action             = network_acls.value.default_action
      bypass                     = network_acls.value.bypass
      ip_rules                   = network_acls.value.ip_rules
      virtual_network_subnet_ids = network_acls.value.virtual_network_subnet_ids
    }
  }
}

################################################################################
# Wiring example: connect this module to the nullplatform agent (service
# principal auth). This block is COMMENTED OUT on purpose — uncommenting it would
# deploy an agent. It is here only as a copy-paste reference.
#
# The agent authenticates to Azure with the client's existing service principal.
# This module only assigns that SP the Key Vault role (see service_principal
# above); the client_id / client_secret / tenant_id go to the agent DIRECTLY as
# env vars. The secret never passes through this module or its tofu state.
#
# module "agent" {
#   source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/agent?ref=vX.Y.Z"
#
#   cloud_provider = "azure"
#
#   # --- Service-principal auth (the client's existing SP) ---
#   azure_client_id     = "<sp-client-id>"     # same value passed to service_principal.client_id here
#   azure_client_secret = var.sp_client_secret # supplied to the agent directly; keep it out of this module's state
#   azure_tenant_id     = module.azure_key_vault_requirements.tenant_id
#
#   # --- Plus the agent module's other required inputs ---
#   api_key               = var.np_api_key
#   cluster_name          = "your-aks-cluster"
#   nrn                   = "organization=...:account=...:namespace=..."
#   tags_selectors        = { key = "value" }
#   image_tag             = "your-image-tag"
#   azure_subscription_id = "your-subscription-id"
#   azure_resource_group  = "your-resource-group"
#   # private_gateway_name / private_hosted_zone_rg / public_gateway_name as required
# }
################################################################################
