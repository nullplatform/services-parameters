variable "nrn" {
  description = "NRN where the provider specification is anchored (the top-level scope it belongs to)."
  type        = string
}

variable "np_api_key" {
  description = "nullplatform API key used by the upstream parameter_storage modules to register the provider spec and instances."
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
  default     = "parameters/providers/hashicorp-vault/specs/install/hashicorp-vault-configuration.json.tpl"
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
    object shaped to match the hashicorp-vault provider specification schema.
    Instances with enable_notification_channel=true also get their own agent API key +
    notification channel (anchored at the instance NRN). Fields:
      attributes                  — provider config matching the spec schema:
                                      sensibility.applies_to plus setup.address / setup.namespace /
                                      setup.path_prefix / setup.auth_mode / setup.kubernetes_role.
                                      namespace is the Vault Enterprise namespace (leave null for the
                                      root namespace on Vault OSS). path_prefix is the KV v2
                                      `<mount>/data/<subpath>` prefix; leave it null to use the default
                                      (secret/data/nullplatform). auth_mode is "userpass" (default) or
                                      "kubernetes"; kubernetes_role is only used (and required) when
                                      auth_mode = "kubernetes" — leave it null for userpass.
      enable_notification_channel — create the agent API key + notification channel (default false).
      tags_selectors              — tags the agent uses to select/filter this channel against scope
                                      tags (e.g. { environment = "production" }); default {}.
  EOT
  type = map(object({
    nrn                         = string
    dimensions                  = map(string)
    enable_notification_channel = optional(bool, false)
    tags_selectors              = optional(map(string), {})
    attributes = object({
      sensibility = object({
        applies_to = list(string)
      })
      setup = object({
        address         = string
        namespace       = optional(string)
        path_prefix     = optional(string)
        auth_mode       = optional(string, "userpass")
        kubernetes_role = optional(string)
      })
    })
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, instance in var.instances : contains(["userpass", "kubernetes"], instance.attributes.setup.auth_mode)
    ])
    error_message = "attributes.setup.auth_mode must be \"userpass\" or \"kubernetes\"."
  }

  validation {
    condition = alltrue([
      for _, instance in var.instances :
      instance.attributes.setup.auth_mode != "kubernetes" || try(instance.attributes.setup.kubernetes_role, null) != null
    ])
    error_message = "attributes.setup.kubernetes_role is required when attributes.setup.auth_mode = \"kubernetes\"."
  }
}
