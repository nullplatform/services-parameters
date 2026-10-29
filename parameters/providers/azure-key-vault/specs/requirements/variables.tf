variable "service_principal" {
  description = <<-EOT
    Optionally grant an EXISTING Azure AD service principal access to one or more
    Key Vaults via Azure RBAC. This module does NOT create the service principal
    or handle its client secret — you bring your own (e.g. the client's existing
    SP). Pass the SP's client_id; the module resolves its object id and assigns
    the role, scoped per vault. The client_id / client_secret / tenant_id are
    wired into the agent environment directly (AZURE_CLIENT_ID /
    AZURE_CLIENT_SECRET / AZURE_TENANT_ID) — the secret never passes through this
    module or its tofu state.
    Resolving the object id requires the tofu caller to have Azure AD directory
    read permission on the service principal.
    Fields:
      enable        — set true to create the role assignments.
      client_id     — application (client) ID of the existing service principal
                      (required when enable=true).
      key_vault_ids — resource IDs of the Key Vaults to grant access to, one role
                      assignment per vault; combined with a vault created via
                      var.key_vault. Example:
                      "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>".
      role          — RBAC role assigned on each vault. Default
                      "Key Vault Secrets Officer" grants the secret
                      get/list/set/delete/purge the agent needs.
  EOT
  type = object({
    enable        = bool
    client_id     = optional(string, "")
    key_vault_ids = optional(list(string), [])
    role          = optional(string, "Key Vault Secrets Officer")
  })
  default = {
    enable = false
  }

  validation {
    condition     = !var.service_principal.enable || var.service_principal.client_id != ""
    error_message = "service_principal.client_id is required when service_principal.enable=true."
  }

  # "At least one vault to scope to when enabled" is a cross-variable check
  # (external ids or a vault created via var.key_vault), so it lives in the
  # terraform_data.validation precondition in main.tf — a variable's own
  # validation block may only reference its own variable.
  validation {
    condition = !var.service_principal.enable || alltrue([
      for id in var.service_principal.key_vault_ids :
      can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+$", id))
    ])
    error_message = "Each service_principal.key_vault_ids entry must be a full Key Vault resource ID (/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>), so the role assignment is scoped to the vault and not a broader scope."
  }

  # Restrict to Key Vault data-plane roles so an accidental "Owner"/"Contributor"
  # can't grant control-plane access at vault scope. Edit this list if you use a
  # custom data-plane role.
  validation {
    condition = !var.service_principal.enable || contains(
      ["Key Vault Secrets Officer", "Key Vault Secrets User", "Key Vault Reader"],
      var.service_principal.role
    )
    error_message = "service_principal.role must be a Key Vault data-plane role (Key Vault Secrets Officer / Secrets User / Reader); management roles like Owner or Contributor are not allowed."
  }
}

variable "key_vault" {
  description = <<-EOT
    Optionally create the Azure Key Vault this provider stores parameters in.
    Independent of var.service_principal: you can create only the vault, only the
    role assignment, or both. When both are enabled the created vault is added to
    the service principal's RBAC scope automatically (no need to wire a computed
    id). The vault is created with the Azure RBAC authorization model
    (rbac_authorization_enabled = true), which this provider requires.
    IMPORTANT: key_vault.name MUST match the runtime provider config `vault_name`
    (and AZURE_KEY_VAULT_NAME) — that coupling is by name, not by reference.
    Data-plane hardening (purge protection, soft delete) is on by default; the
    NETWORK posture defaults to public access — restrict it via
    public_network_access_enabled and/or network_acls (which defaults to Deny).
    Fields:
      enable                        — set true to create the Key Vault.
      name                          — vault name (required when enable=true; must
                                      equal the runtime vault_name).
      resource_group_name           — resource group for the vault (required when
                                      enable=true).
      location                      — Azure region for the vault (required when
                                      enable=true).
      sku_name                      — "standard" (default) or "premium".
      purge_protection_enabled      — default true (hardened; blocks permanent
                                      delete during the soft-delete window).
      soft_delete_retention_days    — default 90.
      public_network_access_enabled — default true. Set false for private-only
                                      access (requires the agent to reach the
                                      vault over a private endpoint).
      network_acls                  — optional firewall rules. When set,
                                      default_action defaults to "Deny" so
                                      ip_rules act as an allow-list.
      tags                          — optional resource tags.
  EOT
  type = object({
    enable                        = bool
    name                          = optional(string, "")
    resource_group_name           = optional(string, "")
    location                      = optional(string, "")
    sku_name                      = optional(string, "standard")
    purge_protection_enabled      = optional(bool, true)
    soft_delete_retention_days    = optional(number, 90)
    public_network_access_enabled = optional(bool, true)
    network_acls = optional(object({
      default_action             = optional(string, "Deny")
      bypass                     = optional(string, "AzureServices")
      ip_rules                   = optional(list(string), [])
      virtual_network_subnet_ids = optional(list(string), [])
    }))
    tags = optional(map(string), {})
  })
  default = {
    enable = false
  }

  validation {
    condition     = !var.key_vault.enable || var.key_vault.name != ""
    error_message = "key_vault.name is required when key_vault.enable=true (and must match the runtime vault_name)."
  }

  validation {
    condition     = !var.key_vault.enable || var.key_vault.resource_group_name != ""
    error_message = "key_vault.resource_group_name is required when key_vault.enable=true."
  }

  validation {
    condition     = !var.key_vault.enable || var.key_vault.location != ""
    error_message = "key_vault.location is required when key_vault.enable=true."
  }

  validation {
    condition     = contains(["standard", "premium"], var.key_vault.sku_name)
    error_message = "key_vault.sku_name must be \"standard\" or \"premium\"."
  }

  validation {
    condition     = var.key_vault.network_acls == null || contains(["Allow", "Deny"], var.key_vault.network_acls.default_action)
    error_message = "key_vault.network_acls.default_action must be \"Allow\" or \"Deny\"."
  }

  validation {
    condition     = var.key_vault.network_acls == null || contains(["AzureServices", "None"], var.key_vault.network_acls.bypass)
    error_message = "key_vault.network_acls.bypass must be \"AzureServices\" or \"None\"."
  }
}
