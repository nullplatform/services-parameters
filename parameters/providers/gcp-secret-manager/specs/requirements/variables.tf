variable "project_id" {
  description = "GCP project that holds the secrets. Must match the runtime provider config `setup.project_id` (and GCP_SECRET_MANAGER_PROJECT_ID)."
  type        = string
}

variable "name_prefix" {
  description = "Secret id prefix the IAM condition is scoped to. Must match the runtime provider config `setup.name_prefix` (default \"nullplatform\") — the coupling is by name, not by reference."
  type        = string
  default     = "nullplatform"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.name_prefix)) && !can(regex("__", var.name_prefix))
    error_message = "name_prefix may only contain letters, digits, '_' and '-' (Secret Manager secret id charset), and cannot contain '__' (the segment separator)."
  }
}

variable "kubernetes_service_account" {
  description = <<-EOT
    Grant the agent's Kubernetes service account through GKE Workload Identity
    Federation. The agent then authenticates via the metadata server with no GCP
    service account, annotation or key. Requires Workload Identity on the cluster
    and node pool (GKE_METADATA mode).
    Fields:
      enable        — set true to grant the KSA principal.
      namespace     — namespace of the agent's KSA (default "nullplatform-tools").
      name          — name of the agent's KSA (default "nullplatform-agent").
      workload_pool — workload identity pool; defaults to "<project_id>.svc.id.goog",
                      set it ("<cluster_project_id>.svc.id.goog") when the
                      cluster lives in another project.
      workload_pool_project_number — number of the project that owns the pool.
                      Optional: when the pool is in another project and this is
                      unset, it is looked up (the tofu identity then needs
                      resourcemanager.projects.get on that project).
  EOT
  type = object({
    enable                       = bool
    namespace                    = optional(string, "nullplatform-tools")
    name                         = optional(string, "nullplatform-agent")
    workload_pool                = optional(string)
    workload_pool_project_number = optional(string)
  })
  default = {
    enable = true
  }

  validation {
    condition     = endswith(coalesce(var.kubernetes_service_account.workload_pool, ".svc.id.goog"), ".svc.id.goog")
    error_message = "kubernetes_service_account.workload_pool must be \"<project_id>.svc.id.goog\"."
  }

  validation {
    condition     = var.kubernetes_service_account.workload_pool_project_number == null || can(regex("^[0-9]+$", var.kubernetes_service_account.workload_pool_project_number))
    error_message = "kubernetes_service_account.workload_pool_project_number must be the numeric project number."
  }
}

variable "members" {
  description = "Extra IAM members to grant the same conditional access (e.g. \"serviceAccount:agent@project.iam.gserviceaccount.com\" for an agent that authenticates with a GCP service account)."
  type        = list(string)
  default     = []
}

variable "custom_role" {
  description = <<-EOT
    Create (default) and grant a custom role holding only the four permissions the
    provider uses: secrets.create, secrets.delete, versions.access, versions.add.
    Set enable = false to grant var.role instead.
    Fields:
      enable  — create and grant the custom role (default true).
      role_id — custom role id, unique per project (letters, digits, '_' and '.').
  EOT
  type = object({
    enable  = bool
    role_id = optional(string, "nullplatformParametersSecretManager")
  })
  default = {
    enable = true
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_.]{3,64}$", var.custom_role.role_id))
    error_message = "custom_role.role_id must be 3-64 characters of letters, digits, '_' and '.'."
  }
}

variable "role" {
  description = "Predefined role granted under the prefix condition when custom_role.enable = false. Note that roles/secretmanager.admin also carries secrets.list, which the project clause of the condition admits."
  type        = string
  default     = "roles/secretmanager.admin"

  # Restrict to Secret Manager roles so an accidental Owner/Editor can't be
  # granted project-wide through this module.
  validation {
    condition     = startswith(var.role, "roles/secretmanager.")
    error_message = "role must be a Secret Manager role (roles/secretmanager.*)."
  }
}

variable "enable_api" {
  description = "Enable secretmanager.googleapis.com on the project. Leave false when the API is managed elsewhere."
  type        = bool
  default     = false
}
