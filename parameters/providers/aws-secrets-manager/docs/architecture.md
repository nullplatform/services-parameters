# AWS Secrets Manager — Architecture

This document describes how the `parameters/providers/aws-secrets-manager/` provider stores, retrieves, and deletes nullplatform parameters using AWS Secrets Manager (SM).

---

## Role in the parameter lifecycle

A nullplatform parameter has a `kind` that decides where its values are persisted:

| Kind                  | Storage location                         | This provider |
|-----------------------|------------------------------------------|---------------|
| `nullplatform-storage` | nullplatform's own datastore             | Not involved  |
| `third-party-storage`  | External provider (AWS SM, Vault, etc.)  | Used          |

This provider handles parameters configured for third-party storage that the platform routes to AWS Secrets Manager. The platform's choice is per-parameter, and a single parameter — secret or not — can be routed here. Routing a non-secret parameter to AWS SM is supported but costlier than alternatives like Parameter Store; the choice is the platform operator's.

The interaction is event-driven via four actions:

| Action     | Trigger                                          | Effect on AWS SM                                   |
|------------|--------------------------------------------------|----------------------------------------------------|
| `store`    | A parameter value is created or updated          | `CreateSecret` first time, `PutSecretValue` otherwise (new version) |
| `retrieve` | A consumer needs the value                       | `GetSecretValue`, returns the AWSCURRENT version   |
| `delete`   | The parameter is deleted                         | `DeleteSecret --force-delete-without-recovery`      |
| `notify`   | nullplatform-side ack hook                       | No-op (returns `{success: true}`)                  |

---

## Naming strategy

Every secret name is composed from the parameter's NRN entities (with slugs and IDs), its dimensions, and the parameter name + ID:

```
nullplatform/organization=<slug>-<id>/account=<slug>-<id>/.../<dim_key>=<dim_value>/<parameter_name>-<parameter_id>
```

The path follows the **human-friendliness principle**: anyone entering the AWS Secrets Manager console must be able to find the secret by knowing the parameter's context, without consulting nullplatform metadata.

### Optional path components

Two segments of the path are conditional:

- **`scope` entity** — optional. It appears as a segment between `application=...` and the dimensions, only when the parameter is bound to a specific deployment scope. When absent, the path goes directly from `application=...` to dimensions (or to the parameter name if no dimensions).
- **Dimensions** — optional. A parameter may have zero dimensions, in which case no `key=value` segments appear. If present, they are sorted alphabetically by key.

The canonical entity order is `organization → account → namespace → application → scope`. The first four are always present in nullplatform's NRN; `scope` is added on demand.

### Examples

**Minimal** — parameter with required entities only, no scope, no dimensions:

```
nullplatform/organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/DB_PASSWORD-42
```

**With scope** — same parameter bound to a deployment scope:

```
nullplatform/organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/scope=staging-789/DB_PASSWORD-42
```

**With dimensions** — same parameter without scope but with two dimensions:

```
nullplatform/organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/country=argentina/environment=production/DB_PASSWORD-42
```

**Full** — parameter with scope AND dimensions:

```
nullplatform/organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/scope=staging-789/country=argentina/environment=production/DB_PASSWORD-42
```

Notes:

- **Slug-id format** (`<slug>-<id>`): slugs are human-readable, IDs are stable. Combining both gives both readability and resilience to potential slug rename support in the future.
- **Slugs travel in the notification payload** (`entities`/`value_entities` carry `<entity>_slug` fields, guaranteed by the platform contract), so `build_external_id` reads them straight from `CONTEXT` — no `np` call.
- **Dimensions are sorted alphabetically by key** for determinism — the same (NRN, dimensions, parameter) tuple always produces the same secret name.
- **`parameter_name-parameter_id`** at the end: name for legibility, ID for uniqueness across renames.

### IAM anchor

The fixed `nullplatform/` prefix is the IAM scoping anchor:

```
arn:aws:secretsmanager:<region>:<account>:secret:nullplatform/*
```

A single ARN pattern covers everything this provider creates, without granting account-wide access. See `iam-policy.md`.

### sts:AssumeRole

Before any AWS call, this provider's `setup` declares its IAM identity and sources the shared `utils/assume_role_step`:

```bash
ASSUME_ROLE_SELECTOR="secret_manager"
ASSUME_ROLE_OVERRIDE_ENV="SECRET_MANAGER_ASSUME_ROLE_ARN"
ASSUME_ROLE_DEFAULT_ENV="SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT"
ASSUME_ROLE_SESSION_PREFIX="np-secret-manager"
source "$PARAMETERS_ROOT/utils/assume_role_step"
```

The step is provider-agnostic — `aws-parameter-store` does the same with its own selector (`parameter_store`) and env-var names (`PARAMETER_STORE_ASSUME_ROLE_ARN[_DEFAULT]`). The step:

1. Reads the scope's NRN and dimensions from `CONTEXT` (`value_dimensions` for scope-level, else `dimensions`) — all resolved from the payload, no `np scope read`.
2. Calls `np provider list --categories identity-access-control --nrn <nrn> [--dimensions ...]` to fetch the IAM provider that the platform has dimension-resolved for this scope.
3. Picks the ARN from `.iam_role_arns.arns[]` whose `selector` matches `ASSUME_ROLE_SELECTOR`.
4. Calls `sts:AssumeRole` and exports `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.

Precedence: `${!ASSUME_ROLE_OVERRIDE_ENV}` (e.g. `SECRET_MANAGER_ASSUME_ROLE_ARN`) → IAM provider selector → `${!ASSUME_ROLE_DEFAULT_ENV}` (per-account agent default) → agent credentials.

### ARN suffix

AWS SM appends a random 6-character suffix to every secret ARN:

```
arn:aws:secretsmanager:<region>:<account>:secret:nullplatform/.../DB_PASSWORD-42-XXXXXX
```

Use the wildcard form (`nullplatform/*`) in IAM policies — exact ARN matches without the suffix will not match.

---

## Versioning

nullplatform parameter values are **immutable**. Each update of the same (parameter_id, NRN, dimensions) tuple creates a new VERSION of the same value, not a new value.

AWS Secrets Manager has native version retention. We use it as the source of truth:

- **First `store`** for a given path → `CreateSecret`. A new secret is created with version 1.
- **Subsequent `store`** for the same path → `PutSecretValue`. A new version is appended, and `AWSCURRENT` moves to it.
- **All previous versions are retained inside the same secret** (up to AWS SM's 100-version cap, after which the oldest unlabeled versions are pruned automatically).

### Version identity in external_id

The `external_id` returned by `store` encodes both the path and the version:

```
<canonical_path>#<version_id>
```

For AWS SM, `version_id` is **the literal `VersionId` UUID v4 returned by `CreateSecret` / `PutSecretValue`** — we do not invent or normalize it. AWS returns it in the response; we copy it verbatim into the suffix. Real example:

```
organization=acme-1255165411/.../DB_PASSWORD-42#a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d
```

The hex string after `#` is the exact VersionId AWS reports for that PutSecretValue / CreateSecret call. It can be used as-is with `aws secretsmanager get-secret-value --version-id` to fetch that specific version.

This means nullplatform — which already persists and re-sends `external_id` on every operation — automatically retains the version reference without needing a separate field. On `retrieve`:

- If `external_id` carries `#<version_id>` → fetch that specific historical version using `--version-id <VersionId>`.
- If `external_id` has no `#` suffix → fetch `AWSCURRENT` (latest).

On `delete`, the version suffix is ignored — `DeleteSecret` removes all versions of the secret.

### Why this matters for cost

AWS SM charges $0.40 per secret per month, **regardless of version count**. Putting versions in the same secret is essentially free; creating a new secret per version would multiply cost linearly with update frequency. The implementation enforces the cheap path.

### Why this matters for history

Storing all versions in a single secret means operators can view and restore older values. Restoration is platform-orchestrated: read an old version via `retrieve(external_id with #version)`, then store the value again — that becomes the new latest version.

---

## Secret payload shape

The value stored in AWS SM is a JSON envelope, not the raw value:

```json
{
  "parameter_id": 42,
  "value": "the-actual-secret-value",
  "stored_at": "2026-06-23T12:34:56Z",
  "external_id": "organization=acme-1255165411/.../DB_PASSWORD-42"
}
```

| Field          | Purpose                                                      |
|----------------|--------------------------------------------------------------|
| `parameter_id` | nullplatform parameter ID (reverse lookup)                   |
| `value`        | The actual stored value                                      |
| `stored_at`    | UTC timestamp of this version (audit trail)                  |
| `external_id`  | Canonical handle nullplatform persists (matches secret name) |

Each version of the secret carries its own `stored_at` and the value that was active at that point in time.

---

## Lifecycle notes

### Hard delete

`delete` uses `--force-delete-without-recovery`. This bypasses AWS SM's default 7–30 day soft-delete window. The trade-off:

- Recoverability after deletion: lost.
- Cost: no longer paying for soft-deleted secrets.
- Name reuse: immediate.

For nullplatform's model — where the version history is the recovery mechanism, not the soft-delete window — this is the right default. An operator who needs the soft-delete window can override via provider config (future extension).

### Error handling

| Error condition                        | `store`           | `retrieve`               | `delete`           |
|----------------------------------------|-------------------|--------------------------|--------------------|
| Resource exists (on store)             | New version added | N/A                      | N/A                |
| ResourceNotFoundException              | N/A               | Exit 1 + troubleshooting | Idempotent success |
| Any other error (IAM, network, region) | Exit 1 + troubleshooting | Exit 1 + troubleshooting | Exit 1 + troubleshooting |

For `delete`, `ResourceNotFoundException` is treated as idempotent success — the resource is already in the desired state, the work is done. For `retrieve`, not-found is a real error: returning a sentinel like "value not found" as the value would mislead the platform into displaying that string as the parameter's actual value. Every other error — particularly IAM permission failures — propagates as a real error with troubleshooting guidance.

### Encryption at rest

All values are encrypted by AWS SM. By default, SM uses the AWS-managed KMS key `aws/secretsmanager`. To use a customer-managed KMS key (CMK), set `kms_key_id` in the provider's configuration; the agent then grants `kms:Decrypt` and `kms:GenerateDataKey` on that key (see `iam-policy.md`).
