locals {
  enabled = var.kubernetes_auth.enable

  # The token reviewer defaults to living alongside the agent unless overridden.
  token_reviewer_namespace = coalesce(var.kubernetes_auth.token_reviewer_namespace, var.kubernetes_auth.agent_namespace)

  create_agent_sa = local.enabled && var.kubernetes_auth.create_agent_service_account
}
