output "agent_service_account" {
  description = "Name/namespace of the agent ServiceAccount to bind in the Vault role (bound_service_account_names / bound_service_account_namespaces). Null when disabled."
  value = local.enabled ? {
    name      = var.kubernetes_auth.agent_service_account_name
    namespace = var.kubernetes_auth.agent_namespace
  } : null
}

output "token_reviewer_service_account" {
  description = "Name/namespace of the token-reviewer ServiceAccount. Use its token as token_reviewer_jwt in `vault write auth/kubernetes/config`. Null when disabled."
  value = local.enabled ? {
    name      = var.kubernetes_auth.token_reviewer_service_account_name
    namespace = local.token_reviewer_namespace
  } : null
}
