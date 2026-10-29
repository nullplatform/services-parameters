# All cluster resources are declared as .yaml templates under ./templates and
# applied via kubernetes_manifest so the manifests stay readable and reviewable
# as plain Kubernetes YAML.
#
# NOTE: kubernetes_manifest performs a server-side dry-run at PLAN time, so the
# target cluster must be reachable when running `tofu plan` (not just apply).
# Pin the target with kube_config_context to avoid touching the wrong cluster —
# this module creates a cluster-wide RBAC binding.

provider "kubernetes" {
  config_path    = var.kube_config_path
  config_context = var.kube_config_context
}

resource "kubernetes_manifest" "agent_service_account" {
  count = local.create_agent_sa ? 1 : 0

  manifest = yamldecode(templatefile("${path.module}/templates/agent-service-account.yaml", {
    name      = var.kubernetes_auth.agent_service_account_name
    namespace = var.kubernetes_auth.agent_namespace
  }))
}

resource "kubernetes_manifest" "token_reviewer_service_account" {
  count = local.enabled ? 1 : 0

  manifest = yamldecode(templatefile("${path.module}/templates/token-reviewer-service-account.yaml", {
    name      = var.kubernetes_auth.token_reviewer_service_account_name
    namespace = local.token_reviewer_namespace
  }))
}

resource "kubernetes_manifest" "token_reviewer_binding" {
  count = local.enabled ? 1 : 0

  manifest = yamldecode(templatefile("${path.module}/templates/token-reviewer-cluster-role-binding.yaml", {
    name      = var.kubernetes_auth.token_reviewer_service_account_name
    namespace = local.token_reviewer_namespace
  }))

  depends_on = [kubernetes_manifest.token_reviewer_service_account]
}
