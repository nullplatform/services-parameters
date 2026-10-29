# AWS Systems Manager Parameter Store — Provider Architecture

This document describes the `parameters/providers/aws-parameter-store/` implementation. It stores nullplatform parameters in AWS SSM Parameter Store, using `String` for plain parameters and `SecureString` (KMS-encrypted) for secrets.

Cheapest provider in the package — Standard tier is free up to 10,000 parameters.

---

## Lifecycle

| Step | What happens                                                                |
|------|-----------------------------------------------------------------------------|
| `setup`     | `AWS_REGION` from the agent runtime (IRSA / instance profile). `PS_NAME_PREFIX` hardcoded to `/nullplatform/`. Reads `PS_KMS_KEY_ID` and `PS_TIER` from `PROVIDER_CONFIG`. |
| `store`     | Composes path via `build_external_id`. Calls `aws ssm put-parameter --overwrite`. Captures `.Version` from response. Returns `external_id = <path>#<version>`. |
| `retrieve`  | Parses path + version. Calls `aws ssm get-parameter --with-decryption`. If a version is present in external_id, appends `:<N>` to target that specific version. |
| `delete`    | Calls `aws ssm delete-parameter`. Idempotent (suppresses `ParameterNotFound`). |
| `notify`    | Not implemented — dispatcher returns default `{success: true}`. |

---

## Storage layout

Every parameter name is composed by `parameters/utils/build_external_id`:

```
/nullplatform/organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim_key>=<dim_value>...]/<parameter_name>-<parameter_id>
```

The `scope` entity is optional (only present when the parameter is bound to a deployment scope). Dimensions are also optional. See `parameters/docs/architecture.md` for the complete naming convention.

The `/nullplatform/` prefix is hardcoded — it's the invariant namespace anchor for all platform parameters and the basis for least-privilege IAM scoping (`parameter/nullplatform/*`).

Example:

```
/nullplatform/organization=acme-1255165411/account=prod-95118862/.../DB_PASSWORD-42
```

IAM can target the hierarchy via ARN pattern `arn:aws:ssm:<region>:<account>:parameter/nullplatform/*`.

---

## Type selection via PARAMETER_KIND

This is the only provider in the package that branches on `PARAMETER_KIND`:

| Kind        | SSM Type        | KMS                                                  |
|-------------|-----------------|------------------------------------------------------|
| `parameter` | `String`        | None (plain text)                                    |
| `secret`    | `SecureString`  | `PS_KMS_KEY_ID` if set, otherwise `alias/aws/ssm`    |

For other providers in the package, kind is informational — their backends encrypt all values uniformly.

---

## Versioning

Parameter Store retains versions automatically. `put-parameter --overwrite` creates a new version on every call.

### Version identity in external_id

The `external_id` returned by `store` encodes both the path and the version:

```
<canonical_path>#<version_id>
```

For Parameter Store, `version_id` is **the literal integer `.Version` returned by `put-parameter`** — we do not invent or normalize it. AWS returns it; we copy it verbatim. Real example:

```
organization=acme-1255165411/.../DB_PASSWORD-42#7
```

Here `7` means "the 7th version of this parameter". SSM addresses historical versions by suffixing the parameter name with `:<N>`, so on retrieve we call `get-parameter --name "<full-path>:7"`.

On `retrieve`:
- With `#<N>` → fetch version N.
- Without → fetch latest.

On `delete`, the version suffix is ignored — `delete-parameter` removes all versions.

---

## Tiers

| Tier                  | Free                  | Value size  | Use case                          |
|-----------------------|-----------------------|-------------|-----------------------------------|
| `Standard` (default)  | up to 10,000 params   | 4 KB        | Most cases                        |
| `Advanced`            | $0.05/param/month     | 8 KB        | Large values or > 10k params      |
| `Intelligent-Tiering` | Auto-promotes         | varies      | Mixed sizes                       |

Switch tiers via provider config `tier` attribute.

---

## Configuration

`PROVIDER_CONFIG` shape (only operator-configurable knobs — `AWS_REGION` comes from the agent runtime, `name_prefix` is hardcoded to `/nullplatform/`):

```json
{
  "kms_key_id": "alias/parameters-secure",
  "tier":       "Standard"
}
```

`kms_key_id` only matters for `kind=secret` (SecureString). For `kind=parameter` (String) it's ignored.
