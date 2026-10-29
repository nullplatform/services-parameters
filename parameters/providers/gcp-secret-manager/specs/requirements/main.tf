resource "google_project_service" "secretmanager" {
  count = var.enable_api ? 1 : 0

  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# Least-privilege default: only the four permissions the provider calls. Unlike
# roles/secretmanager.admin it carries no secrets.list, so the agent cannot even
# enumerate other teams' secret names in a shared project.
resource "google_project_iam_custom_role" "provider" {
  count = var.custom_role.enable ? 1 : 0

  project     = var.project_id
  role_id     = var.custom_role.role_id
  title       = "nullplatform parameters (GCP Secret Manager)"
  description = "Store, retrieve and delete nullplatform parameters as Secret Manager secrets"
  permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
  ]
}

# One conditional binding per member. Secret Manager evaluates create (and list)
# against the project, and everything else (addVersion, access, delete) against
# the secret, so the condition admits the project itself plus only the secrets
# under the provider's prefix — existing secrets of other teams in a shared
# project stay out of reach.
resource "google_project_iam_member" "secret_manager" {
  for_each = local.members

  project = var.project_id
  role    = local.role
  member  = each.value

  condition {
    title       = "nullplatform-${var.name_prefix}-secrets"
    description = "Secret Manager access limited to secrets named ${var.name_prefix}__*"
    expression  = "resource.type == \"cloudresourcemanager.googleapis.com/Project\" || resource.name.startsWith(\"${local.secret_name_prefix}\")"
  }

  depends_on = [google_project_service.secretmanager]
}
