# GCP Secret Manager — Provider Architecture

This document describes the `parameters/providers/gcp-secret-manager/` implementation. It stores nullplatform parameters as Google Cloud Secret Manager secrets, exploiting Secret Manager's native versioning.

Everything goes through the Secret Manager REST API (`https://secretmanager.googleapis.com/v1`) with `curl` and `jq`: no `gcloud` CLI is needed in the agent image. The shared `api` helper sends every request: the bearer token goes in a mode-600 temp header file read with `curl -H @file` (removed on exit) and request bodies go on stdin, so neither the token nor the value ever appears on curl's argv (`ps`, `/proc/<pid>/cmdline`). This needs curl 7.55 or later.

---

## Lifecycle

| Step | What happens |
|------|--------------|
| `setup`     | Reads `project_id`, `name_prefix` and `replica_locations`. Gets an access token from the metadata server (the agent pod's Workload Identity), or uses `GCP_ACCESS_TOKEN` when set. Exports `GCP_ACCESS_TOKEN`, `GSM_PROJECT_ID`, `GSM_API_URL`, `GSM_NAME_PREFIX`, `GSM_REPLICA_LOCATIONS`. |
| `store`     | Builds the canonical path with `build_external_id`, maps it to a secret id (see Storage layout), validates the 255-char limit, then `POST /secrets/<id>:addVersion`. Only on `404` (first store) it creates the secret (`POST /secrets?secretId=`; `409` from a concurrent store is fine) and retries `addVersion`. Returns `external_id = <canonical_path>#<version>`. |
| `retrieve`  | Maps `EXTERNAL_ID_PATH` to the secret id. Accepts only an integer version suffix (or `latest`) and fails otherwise, then `GET /secrets/<id>/versions/<version or latest>:access` and base64-decodes the payload. |
| `delete`    | Maps `EXTERNAL_ID_PATH` to the secret id. `DELETE /secrets/<id>` (removes every version). Idempotent. |
| `notify`    | Not implemented — dispatcher returns default `{success: true}`. |

---

## Storage layout

The `external_id` returned to nullplatform keeps the **canonical slash form** produced by the shared `build_external_id`, so it stays portable across providers:

```
organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim_key>=<dim_value>...]/<parameter_name>-<parameter_id>
```

Secret ids only allow `[A-Za-z0-9_-]` (max **255** characters), so `naming/gsm_secret_id` flattens that path deterministically, and `store`, `retrieve` and `delete` all share that single function:

| Canonical | Secret id |
|-----------|-----------|
| `/` (segment separator) | `__` |
| `=` (entity / dimension separator) | `-` |
| any other char outside the charset (e.g. `.`) | `-` |

The configured prefix (default `nullplatform`) is joined the same way. Example:

```
external_id: organization=acme-123456789/account=production-987654321/namespace=billing-111/application=api-222/DB_PASSWORD-42#3
secret id:   nullplatform__organization-acme-123456789__account-production-987654321__namespace-billing-111__application-api-222__DB_PASSWORD-42
```

Unlike Azure Key Vault (127 chars), the 255-char budget fits the full form, slugs included, so an operator browsing the Secret Manager console reads the whole nullplatform context from the name. `store` validates the limit **before** calling the API and fails with a clear error on overflow.

### Labels

`store` labels every secret it creates with the parameter's NRN, so secrets can be filtered and costs broken down by organization, account, namespace, application or scope. The keys follow the platform tags the nullplatform services put on their resources: `<entity>_id` holds the id and `<entity>` the slug.

| Label | Value | When |
|---|---|---|
| `organization_id`, `organization` | organization id, slug | always |
| `account_id`, `account` | account id, slug | always |
| `namespace_id`, `namespace` | namespace id, slug | always |
| `application_id`, `application` | application id, slug | always |
| `scope_id`, `scope` | scope id, slug | scope-level values only |
| `managed_by` | `nullplatform` | always |
| `parameter_id` | nullplatform parameter id | always |

- **Source.** The values come from the payload's `value_entities` (scope-level values) or `entities`, the same fields that build the secret id. An entity missing from the payload gets no label.
- **Not overridable.** `managed_by` and `parameter_id` are merged last, and nothing else in the payload (for example a `tags` or `labels` object) becomes a label.
- **Label rules.** GCP label values allow only lowercase letters, digits, `_` and `-`, up to 63 characters. Values are lowercased, any other character becomes `-`, and longer values are truncated to 63. The 12 labels at most stay well under the limit of 64 per secret.
- **Set on creation only.** Labels are written when the secret is created. Later stores only add versions and leave the labels as they are, so updating a value costs no extra call and needs no `secretmanager.secrets.update` permission.

> **The prefix is part of the name, not of the `external_id`.** Changing `name_prefix` on a provider configuration that already holds values makes every existing parameter answer `404` on retrieve. Treat it as fixed once values exist; to move, re-store the values under the new configuration.

---

## Versioning

Secret Manager has native versioning: a secret is a container and every `addVersion` appends an immutable version, numbered `1, 2, 3, …`.

- Every `store` → `addVersion` first. On an existing secret that is the only call (→ `2`, `3`, …).
- First `store` for an `external_id` → `addVersion` answers `404`, so the secret is created and `addVersion` retried (→ version `1`).

### Version identity in external_id

```
<canonical_path>#<version_id>
```

`version_id` is the **literal integer Secret Manager returns**: the last segment of the version resource name `projects/<number>/secrets/<id>/versions/<n>`. It is not invented or normalized.

On `retrieve`:
- With `#<n>` → `GET .../versions/<n>:access` (that historical version).
- Without → `GET .../versions/latest:access`.
- Anything other than an integer or `latest` (e.g. `#../../<other_secret>/versions/1`) is rejected before any call, so a tampered suffix cannot address a different secret.

A version that was disabled or destroyed outside nullplatform answers `400 FAILED_PRECONDITION`; `retrieve` exits non-zero with troubleshooting.

On `delete`, the version suffix is ignored — deleting the secret removes all versions. Secret Manager has **no soft-delete**, so there is no purge step and the name is free again immediately.

---

## Replication

- **Default: automatic** — Google chooses where to replicate the payload.
- **`replica_locations`** set (e.g. `["europe-west1"]`) → user-managed replication to exactly those regions, for data-residency requirements.

Replication is fixed when a secret is created. Changing `replica_locations` affects new secrets only; existing ones keep their original policy (later stores only call `addVersion`).

---

## Authentication

1. **Workload Identity (default, recommended on GKE).** `setup` asks the metadata server (`metadata.google.internal`) for a token. With GKE Workload Identity Federation the token belongs to the agent's Kubernetes service account itself (`principal://…/subject/ns/<namespace>/sa/<name>`), so the agent needs no GCP service account, annotation or key. `specs/requirements` grants that principal access.
2. **`GCP_ACCESS_TOKEN` env var.** Overrides the metadata server, for runs outside GCP (e.g. local testing with `gcloud auth print-access-token`). Env only, never provider config — keep credentials off-platform.

Least-privilege IAM, including the trade-off of the project clause in the IAM condition, is in [iam-policy.md](iam-policy.md).

---

## Configuration

`PROVIDER_CONFIG` shape (provider spec `gcp-secret-manager`):

```json
{
  "sensibility": { "applies_to": ["secret"] },
  "setup": {
    "project_id": "acme-prod-secrets",
    "name_prefix": "nullplatform",
    "replica_locations": ["europe-west1"]
  }
}
```

| Setting | Provider config | Env fallback | Default |
|---------|-----------------|--------------|---------|
| Project | `.setup.project_id` | `GCP_SECRET_MANAGER_PROJECT_ID` | — (required) |
| Name prefix | `.setup.name_prefix` | `GCP_SECRET_MANAGER_NAME_PREFIX` | `nullplatform` |
| Replica locations | `.setup.replica_locations` (array) | `GCP_SECRET_MANAGER_REPLICA_LOCATIONS` (comma-separated) | automatic replication |
| Access token | — | `GCP_ACCESS_TOKEN` | metadata server |

---

## Cost model

Secret Manager bills per **active secret version** per replica location per month, plus access operations; the first few versions and operations each month are free (check current list prices). Two consequences:

- Native versioning keeps one secret per parameter context, so updating a parameter adds a version, never a new secret.
- Old versions stay active (and billed) until destroyed. The provider never destroys versions, because nullplatform may ask for any historical revision.

---

## Install specs

- `specs/install/` — registers the `gcp-secret-manager` parameter-storage specification and one provider configuration per instance (NRN + dimensions), plus the agent notification channel, with the shared tofu-modules. Same shape as the other providers.
- `specs/requirements/` — grants the agent's KSA principal (and/or extra members) a custom role with only the four permissions the provider uses, under an IAM condition scoped to the `name_prefix`, and can enable the API.
