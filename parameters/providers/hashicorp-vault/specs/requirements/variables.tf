variable "kube_config_path" {
  description = "Path to the kubeconfig used to apply the cluster resources. Null uses the provider's default discovery (KUBE_CONFIG_PATH / ~/.kube/config)."
  type        = string
  default     = null
}

variable "kube_config_context" {
  description = "kubeconfig context to target. Set this to avoid applying the cluster-wide RBAC (system:auth-delegator binding) to the wrong cluster."
  type        = string
  default     = null
}

variable "kubernetes_auth" {
  description = <<-EOT
    Optionally create the in-cluster Kubernetes resources that Vault's `kubernetes`
    auth method needs so the nullplatform agent can authenticate with its pod
    ServiceAccount identity (auth_mode = "kubernetes" in the install module).

    It provisions two things via .yaml templates applied from Terraform:
      1. The agent ServiceAccount the Vault role binds to (bound_service_account_names /
         bound_service_account_namespaces). Skip with create_agent_service_account=false
         if the agent Helm chart already manages it.
      2. A token-reviewer ServiceAccount bound to the built-in `system:auth-delegator`
         ClusterRole. Its token is used as `token_reviewer_jwt` when configuring
         `vault write auth/kubernetes/config`.

    Fields:
      enable                              — set true to create the resources.
      agent_namespace                     — namespace of the nullplatform agent (required when enable=true).
      agent_service_account_name          — name of the agent ServiceAccount (required when enable=true).
      create_agent_service_account        — also create the agent ServiceAccount (default true).
      token_reviewer_service_account_name — token-reviewer SA name (default "vault-auth").
      token_reviewer_namespace            — token-reviewer SA namespace (default: agent_namespace).
  EOT
  type = object({
    enable                              = bool
    agent_namespace                     = optional(string, "")
    agent_service_account_name          = optional(string, "")
    create_agent_service_account        = optional(bool, true)
    token_reviewer_service_account_name = optional(string, "vault-auth")
    token_reviewer_namespace            = optional(string, "")
  })
  default = {
    enable = false
  }

  validation {
    condition     = !var.kubernetes_auth.enable || (var.kubernetes_auth.agent_namespace != "" && var.kubernetes_auth.agent_service_account_name != "")
    error_message = "agent_namespace and agent_service_account_name are required when kubernetes_auth.enable=true."
  }
}
