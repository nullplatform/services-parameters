variable "nrn" {
  description = "NRN where the provider specification is anchored (the top-level scope it belongs to)."
  type        = string
}

variable "np_api_key" {
  description = "nullplatform API key used by the upstream configuration module to register provider instances."
  type        = string
  sensitive   = true
}

variable "extra_visible_to_nrns" {
  description = "Additional NRNs that should see the provider specification besides var.nrn and the per-instance NRNs."
  type        = list(string)
  default     = []
}

variable "template_path" {
  description = "Path to the provider specification configuration template used by the parameter_storage_definition module."
  type        = string
  default     = "parameters/providers/azure-key-vault/specs/install/azure-key-vault-configuration.json.tpl"
}

variable "repository_parameter_storage_spec_branch" {
  description = "Branch of the parameters repository from which the parameter storage spec is fetched."
  type        = string
  default     = "main"
}

variable "repository_parameter_storage_spec" {
  description = "Base raw URL of the parameters repository hosting the parameter storage spec."
  type        = string
  default     = "https://raw.githubusercontent.com/nullplatform/parameters-provider/refs/heads"
}

variable "instances" {
  description = <<-EOT
    Provider instances to create. Map key is a stable identifier (used in for_each).
    Each entry carries its own NRN, dimensions, and a provider-specific `attributes`
    object shaped to match the Azure Key Vault provider specification schema
    (sensibility.applies_to + setup.vault_name).
    Instances with enable_notification_channel=true (the default) also get their own
    agent API key + notification channel, anchored at the instance NRN. Fields:
      attributes                  — provider config matching the provider spec schema:
                                    sensibility.applies_to (secret / non_secret) and setup.vault_name.
      enable_notification_channel — create the agent API key + notification channel for this instance (default true).
      tags_selectors              — tags the agent uses to select/filter this channel against scope tags
                                    (e.g. { environment = "production" }); default {}.
  EOT
  type = map(object({
    nrn                         = string
    dimensions                  = map(string)
    enable_notification_channel = optional(bool, true)
    tags_selectors              = optional(map(string), {})
    attributes = object({
      sensibility = object({
        applies_to = list(string)
      })
      setup = object({
        vault_name = string
      })
    })
  }))
  default = {}
}
