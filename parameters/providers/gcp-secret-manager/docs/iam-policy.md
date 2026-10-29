# GCP Secret Manager — IAM Policy

Least-privilege access for the agent identity. The `specs/requirements/` module applies exactly this; the manual equivalent is below.

## Permissions the provider uses

| Operation | Permission | Evaluated on |
|-----------|------------|--------------|
| `store` (every time) | `secretmanager.versions.add` | the secret |
| `store` (first time only, when `addVersion` answers 404) | `secretmanager.secrets.create` | the project |
| `retrieve` | `secretmanager.versions.access` | the secret |
| `delete` | `secretmanager.secrets.delete` | the secret |

## Role

The default (`specs/requirements`, `custom_role.enable = true`) is a **custom role with exactly the four permissions above**. Prefer it over `roles/secretmanager.admin`: the admin role also carries `secretmanager.secrets.list`, which is checked against the project and therefore admitted by the project clause of the condition below, so the agent could enumerate every secret name in a shared project.

```bash
gcloud iam roles create nullplatformParametersSecretManager --project <PROJECT_ID> \
  --title "nullplatform parameters (GCP Secret Manager)" \
  --permissions secretmanager.secrets.create,secretmanager.secrets.delete,secretmanager.versions.access,secretmanager.versions.add
```

## Binding

Grant the role with an IAM condition that admits the project itself (where `secrets.create` is checked) plus only the secrets under the provider's prefix. Existing secrets of other teams in a shared project stay out of reach: the agent can neither read, version nor delete them.

```
resource.type == "cloudresourcemanager.googleapis.com/Project" ||
resource.name.startsWith("projects/<PROJECT_NUMBER>/secrets/<NAME_PREFIX>__")
```

- `<PROJECT_NUMBER>` is the numeric project number (secret resource names use the number, not the id).
- `<NAME_PREFIX>` must equal the runtime `setup.name_prefix` (default `nullplatform`). The double underscore is part of the naming scheme, so a prefix `nullplatform` does not also match `nullplatform-other__…`.

### Accepted trade-off: the project clause

`secretmanager.secrets.create` is checked against the project, not against the secret being created, so the condition has to admit the project resource (`resource.type == "cloudresourcemanager.googleapis.com/Project"`). That clause is not limited by name: **the agent can create a secret with any name in the project**, not only `<NAME_PREFIX>__*`.

What it still cannot do with a secret outside the prefix: add versions to it, read it, or delete it. Those permissions are checked on the secret, and the prefix clause does not admit it. So the agent cannot plant a value in, or read a value from, another team's secret. The residual risk is name squatting: in a shared project it could create an empty secret under a name another team intends to use. If that matters, give nullplatform a dedicated secrets project.

With `roles/secretmanager.admin` instead of the custom role, the same clause also admits `secretmanager.secrets.list` (see Role above).

## Member: the agent's KSA through Workload Identity Federation (recommended)

On GKE with Workload Identity, grant the agent's Kubernetes service account directly. The agent needs no GCP service account, annotation or key:

```
principal://iam.googleapis.com/projects/<POOL_PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_PROJECT_ID>.svc.id.goog/subject/ns/<NAMESPACE>/sa/<KSA_NAME>
```

`<POOL_PROJECT_ID>` and `<POOL_PROJECT_NUMBER>` identify the project that owns the workload identity pool, which is **the GKE cluster's project**. When the cluster and the secrets live in the same project they equal `<PROJECT_ID>` / `<PROJECT_NUMBER>`; when the cluster is in another project, use that project's id and number (`gcloud projects describe <CLUSTER_PROJECT_ID> --format='value(projectNumber)'`). `specs/requirements` does this from `kubernetes_service_account.workload_pool`, looking the number up or taking `workload_pool_project_number`.

With the nullplatform agent chart defaults: namespace `nullplatform-tools`, KSA `nullplatform-agent`.

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="principal://iam.googleapis.com/projects/<POOL_PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_PROJECT_ID>.svc.id.goog/subject/ns/nullplatform-tools/sa/nullplatform-agent" \
  --role="projects/<PROJECT_ID>/roles/nullplatformParametersSecretManager" \
  --condition='title=nullplatform-secrets,expression=resource.type == "cloudresourcemanager.googleapis.com/Project" || resource.name.startsWith("projects/<PROJECT_NUMBER>/secrets/nullplatform__")'
```

An agent that authenticates with a GCP service account instead (outside GKE, through `GCP_ACCESS_TOKEN`) gets the same binding with `--member="serviceAccount:<SA_EMAIL>"`.

## Notes

- `<NAME_PREFIX>` cannot contain `__` (setup, the `specs/requirements` variable validation and the provider spec all reject it), so one prefix never covers another prefix's secrets.
- Granting `roles/secretmanager.secretAccessor` alone is **not** enough: `store` and `delete` need create, addVersion and delete.
- How Secret Manager evaluates `resource.type` / `resource.name` for `secrets.create` is the assumption the project clause rests on; validate it once per environment with a real store (see the provider's architecture doc).
