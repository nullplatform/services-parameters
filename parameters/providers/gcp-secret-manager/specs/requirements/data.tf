################################################################################
# Grant the agent's identity least-privilege access to Secret Manager, and
# optionally enable the Secret Manager API. The identity is either the agent's
# Kubernetes service account through GKE Workload Identity Federation (no GCP
# service account and no key at all), or any extra IAM members passed in.
################################################################################

# The project number appears in secret resource names (projects/<number>/...),
# which the IAM condition matches against.
data "google_project" "this" {
  project_id = var.project_id
}

# Workload Identity principals are scoped by the number of the project that OWNS
# the workload pool (the cluster's project), which is not necessarily the
# secrets project. Looked up only when the pool lives in another project and its
# number was not given explicitly (needs resourcemanager.projects.get there).
data "google_project" "workload_pool" {
  count = local.workload_pool_lookup ? 1 : 0

  project_id = local.workload_pool_project_id
}
