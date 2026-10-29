# HashiCorp Vault — Provider Architecture

This document describes the `parameters/providers/hashicorp-vault/` implementation. It stores nullplatform parameters as Vault KV v2 secrets, exploiting Vault's native versioning.

---

## Lifecycle

| Step | What happens                                                                          |
|------|---------------------------------------------------------------------------------------|
| `setup`     | Reads `VAULT_ADDR`, `VAULT_AUTH_MODE` (default `userpass`) and the mode's inputs, plus two independent path axes: `VAULT_NAMESPACE` (the Vault Enterprise namespace, empty = root) and `VAULT_PATH_PREFIX` (the KV v2 `<mount>/data/<subpath>` prefix, default `secret/data/nullplatform`). When a namespace is set, prefixes the login URL with it — credentials are namespace-scoped, so a root login would be denied. Authenticates against Vault and exports the derived short-lived token as `VAULT_TOKEN` plus `VAULT_NAMESPACE`. Fails fast if address or credentials/identity are missing. |
| `store`     | Composes the canonical path via `build_external_id` and prepends `VAULT_PATH_PREFIX`, so the `external_id` is the full, self-contained KV path (the namespace is applied separately as a URL prefix, not embedded). POSTs to `$VAULT_ADDR/v1/<namespace>/<full_path>` with a JSON payload. **Validates the HTTP status** (curl `-s` exits 0 on HTTP errors, so a failed write must not be reported as success). Captures the new version number from Vault's response. Returns `external_id = <VAULT_PATH_PREFIX>/<path>#<version>`. |
| `retrieve`  | Splits `EXTERNAL_ID` into path + version. GETs `$VAULT_ADDR/v1/<namespace>/<full_path>?version=<N>` using the path **verbatim** (the KV prefix is already embedded — never recomposed against the current `VAULT_PATH_PREFIX`, so a later `setup.path_prefix` change can't orphan the reference). The namespace comes from the current config. Returns `{value}` or `{value: "value not found"}`. |
| `delete`    | Parses path from external_id. DELETEs the metadata endpoint (KV v2) — removes all versions. Idempotent. |
| `notify`    | Not implemented — dispatcher returns default `{success: true}`. |

---

## Storage layout

Every secret path is composed by `parameters/utils/build_external_id`:

```
<VAULT_PATH_PREFIX>/organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim_key>=<dim_value>...]/<parameter_name>-<parameter_id>
```

The `scope` entity is optional (only present when the parameter is bound to a deployment scope). Dimensions are also optional — a parameter may have zero of them. See `parameters/docs/architecture.md` for the complete naming convention.

Default `VAULT_PATH_PREFIX` is `secret/data/nullplatform` (KV v2 — note the `data/` segment is required by the v2 API).

Example full path:

```
secret/data/nullplatform/organization=acme-1255165411/account=prod-95118862/.../DB_PASSWORD-42
```

The path is human-friendly: navigating the Vault UI, an operator can find any secret by knowing the parameter's NRN + dimensions + name.

---

## Versioning

Vault KV v2 has native versioning. Every `POST /v1/secret/data/<path>` creates a new version, all retained inside the same path. Old versions can be fetched with `?version=<N>`.

### Version identity in external_id

The `external_id` returned by `store` is the full Vault path (KV prefix included)
plus the version:

```
<VAULT_PATH_PREFIX>/<canonical_path>#<version_id>
```

Embedding the KV prefix makes the `external_id` self-contained: `retrieve`/`delete`
resolve it verbatim, so reconfiguring `setup.path_prefix` never orphans previously
stored references. (The Vault namespace is applied from the current config as a URL
prefix and is deliberately not embedded — moving to a different namespace is a
migration, not a config tweak.)

For Vault KV v2, `version_id` is **the literal integer version number returned by Vault** in `.data.version` — we do not invent or normalize it. Real example:

```
secret/data/nullplatform/organization=acme-1255165411/.../DB_PASSWORD-42#3
```

Here `3` means "Vault version 3 of this secret". It can be used as-is with `?version=3` to fetch that specific version.

On `retrieve`:
- If `external_id` carries `#<N>` → fetch that historical version via `?version=N`.
- If no `#` suffix → fetch the latest (default Vault behavior).

On `delete`, the version suffix is ignored. KV v2's data DELETE removes the latest version label; for full purging across all versions you'd use `metadata` endpoint — see Vault docs for the soft/hard delete distinction.

---

## Secret payload

The body stored in Vault is a JSON envelope:

```json
{
  "data": {
    "parameter_id": 42,
    "value": "the-actual-value",
    "stored_at": "2026-06-23T12:34:56Z",
    "external_id": "secret/data/nullplatform/organization=acme-1255165411/.../DB_PASSWORD-42"
  }
}
```

The `data` wrapper is KV v2's API requirement; the inner object is our envelope.

---

## Authentication

`setup` authenticates against Vault and exchanges the credentials/identity for a
short-lived client token, which it exports as `VAULT_TOKEN`. `store`, `retrieve`
and `delete` are auth-agnostic — they just send that token in the `X-Vault-Token`
header. Two modes are selectable via `.setup.auth_mode` (or `VAULT_AUTH_MODE`):

| Mode         | Inputs                                                                 | Login endpoint                        |
|--------------|-----------------------------------------------------------------------|---------------------------------------|
| `userpass`   | `VAULT_USERNAME`, `VAULT_PASSWORD` (env only — the password is sensitive) | `POST /v1/auth/userpass/login/<user>` |
| `kubernetes` | `.setup.kubernetes_role` + the pod's ServiceAccount JWT (mounted file) | `POST /v1/auth/kubernetes/login`      |

The authenticated identity (userpass user or the Vault Kubernetes role) must have
a policy granting read/write on the configured `VAULT_PATH_PREFIX` namespace.

The auth mounts are hardcoded to Vault's defaults (`auth/userpass`,
`auth/kubernetes`). Because the agent re-authenticates on every run, each token is
short-lived and scoped to the identity's policy — credential/role lifecycle
management (rotating passwords, binding the ServiceAccount) is the operator's
responsibility. See the provider [`README.md`](../README.md) for the required
Vault + cluster setup per mode.
