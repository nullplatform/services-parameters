locals {
  # Workload pool of the cluster the agent runs on: "<pool_project_id>.svc.id.goog".
  workload_pool            = coalesce(var.kubernetes_service_account.workload_pool, "${var.project_id}.svc.id.goog")
  workload_pool_project_id = trimsuffix(local.workload_pool, ".svc.id.goog")

  # The principal needs the number of the project that owns the pool. Use the
  # explicit number if given; else the secrets project's number when the pool is
  # in the same project; else look it up (data.google_project.workload_pool).
  workload_pool_lookup = (
    var.kubernetes_service_account.enable
    && var.kubernetes_service_account.workload_pool_project_number == null
    && local.workload_pool_project_id != var.project_id
  )
  workload_pool_project_number = coalesce(
    var.kubernetes_service_account.workload_pool_project_number,
    local.workload_pool_lookup ? data.google_project.workload_pool[0].number : data.google_project.this.number,
  )

  # Workload Identity Federation principal of the agent's KSA. Granting it
  # directly means the agent needs no GCP service account annotation. Format:
  # principal://iam.googleapis.com/projects/<POOL_PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_PROJECT_ID>.svc.id.goog/subject/ns/<NAMESPACE>/sa/<KSA>
  workload_identity_member = var.kubernetes_service_account.enable ? (
    "principal://iam.googleapis.com/projects/${local.workload_pool_project_number}/locations/global/workloadIdentityPools/${local.workload_pool}/subject/ns/${var.kubernetes_service_account.namespace}/sa/${var.kubernetes_service_account.name}"
  ) : ""

  role = var.custom_role.enable ? google_project_iam_custom_role.provider[0].id : var.role

  members = toset(compact(concat([local.workload_identity_member], var.members)))

  # Every secret the provider owns is named "<prefix>__..." (see naming).
  secret_name_prefix = "projects/${data.google_project.this.number}/secrets/${var.name_prefix}__"
}
