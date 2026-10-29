# Azure Key Vault — Provider Architecture

This document describes the `parameters/providers/azure-key-vault/` implementation. It stores nullplatform parameters as Azure Key Vault (AKV) secrets, exploiting AKV's native versioning.

---

## Lifecycle

| Step | What happens                                                                  |
|------|-------------------------------------------------------------------------------|
| `setup`     | Reads `AZ_VAULT_NAME`. Authenticates the service principal (client-credentials) and exports `AZ_ACCESS_TOKEN` + `AZ_VAULT_URL`. |
| `store`     | Builds the slug-free secret name (= `external_id`; see Storage layout), validates the 127-char limit, `PUT /secrets/<name>` with `tags.managed_by=nullplatform`. Extracts version from the returned id URL. Returns `external_id = <name>#<version>`. |
| `retrieve`  | Uses `external_id` (path part) as the secret name verbatim. `GET /secrets/<name>[/<version>]`. |
| `delete`    | `DELETE /secrets/<name>` (soft-delete) + best-effort `DELETE /deletedsecrets/<name>` (purge). Idempotent. |
| `notify`    | Not implemented — dispatcher returns default `{success: true}`. |

---

## Storage layout

**The AKV secret name IS the `external_id`** — there is no separate transform. `store` builds the name, returns it verbatim as the `external_id`, and `retrieve`/`delete` use `external_id` directly as the secret name. This keeps the two identical (no lossy mapping to reverse).

AKV secret names allow only `[A-Za-z0-9-]` and are capped at **127 characters**. To fit that budget the name is built **slug-free** and **starts at `application`** — the upper entities (`organization`, `account`, `namespace`) are dropped because the vault is already scoped to that context, and the `application` + `parameter` ids are globally unique so the value is still addressed unambiguously:

```
application-321402625[-scope-<id>][-<dimKey>-<dimVal>...]-<paramName>-<paramId>
```

- Only the NRN **ids** are used (not the `<slug>-<id>` form the shared `build_external_id` produces for other providers). Entity **type names are kept** (`application-`, `scope-`) for readability.
- Entities in canonical NRN order from `application` onward (`application`, `scope`); dimensions sorted alphabetically; the parameter is `<name>-<id>`.
- Every segment is sanitized to `[A-Za-z0-9-]` (any other char → `-`).

`store` **validates the 127-char limit before calling AKV** and fails with a clear error if a deeply-nested scope with many/long dimensions or a long parameter name overflows it.

---

## Versioning

AKV has native versioning. Every write (`PUT /secrets/<name>`) creates a new version, all retained inside the same secret. The version identifier is the last segment of the returned `id` URL.

### Version identity in external_id

The `external_id` returned by `store` is the secret name plus the version:

```
<secret_name>#<version_id>
```

For Azure Key Vault, `version_id` is **the literal hex string version returned by AKV** — we do not invent or normalize it. AKV returns the secret's id as a URL like `https://my-vault.vault.azure.net/secrets/my-secret/93a0b2eb12a64fa7b3acb18900a8d33d`; we extract the last path segment. Real example:

```
application-321402625-DB-PASSWORD-42#93a0b2eb12a64fa7b3acb18900a8d33d
```

That 32-char hex string is the AKV version identifier. It maps to the REST path `GET /secrets/<name>/93a0b2eb12a64fa7b3acb18900a8d33d` to fetch that specific historical version.

On `retrieve`:
- With `#<hex>` → fetch that version (`GET /secrets/<name>/<hex>`).
- Without → fetch the latest (`GET /secrets/<name>`).

On `delete`, the version suffix is ignored — the soft-delete + purge remove all versions.

---

## Soft-delete + purge

AKV uses soft-delete by default (90-day retention). The provider does both:

1. `DELETE /secrets/<name>` — moves to soft-deleted state.
2. `DELETE /deletedsecrets/<name>` — hard-deletes from the soft-delete bin, freeing the name immediately.

If the identity lacks `Purge` permission, purge fails with a warning but delete still succeeds. The secret stays in the soft-delete window and is auto-cleaned by Azure at retention expiry.

---

## Configuration

`PROVIDER_CONFIG` shape:

```json
{
  "vault_name": "my-keyvault"
}
```

## Authentication

The agent authenticates to Azure as a service principal and talks to Key Vault
over the **data-plane REST API with `curl`** — no Azure CLI is used. `setup` runs
the OAuth2 client-credentials flow against Azure AD
(`POST login.microsoftonline.com/<tenant>/oauth2/v2.0/token`, scope
`https://vault.azure.net/.default`) using `AZURE_CLIENT_ID` /
`AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID`, and exports the resulting bearer token
as `AZ_ACCESS_TOKEN`. The `store`/`retrieve`/`delete` steps send it in the
`Authorization: Bearer` header against `<vault>.vault.azure.net`.

### Why REST/`curl` instead of the Azure CLI

The nullplatform agent runtime does **not** ship the Azure CLI (`az`). The
obvious alternative — installing it at runtime through the agent's tool manager
(`mise`) — proved unworkable:

- `az` is a heavy Python CLI. `mise`'s `azure-cli` resolves to either an asdf
  plugin that **clones from GitHub** or a `pipx`/PyPI install — both need egress
  to public package registries.
- Real clusters are network-restricted. In the deployment that drove this
  design, the agent pods had **no egress to GitHub or PyPI** (org security
  policy), so every install path failed (`mise ... IO error` / `dns error`).
  Even where egress exists, installing `az` on **every** parameter operation is
  slow and fragile.

The Key Vault data plane is a plain REST API, so `curl` (always present in the
runtime) plus a client-credentials token is all that's needed. This removes the
runtime-install dependency entirely and only requires egress to the two
endpoints the agent must reach anyway: Azure AD (`login.microsoftonline.com`,
for the token) and the vault (`<vault>.vault.azure.net`, reachable publicly or
via a private endpoint). Azure AD cannot be reached through a private endpoint,
so egress to it is always required.

The client secret is URL-encoded from the environment (via `jq env.*`) and the
token-request body is sent on **stdin**, so the secret never appears on argv.
Likewise the parameter value in `store` travels in the request body on stdin.
Every call checks the HTTP status (`%{http_code}`) and surfaces the Azure error
body on failure. Only the Azure public cloud endpoints are assumed.

The service principal needs the `Key Vault Secrets Officer` RBAC role on the vault
— see [`azure-rbac.md`](./azure-rbac.md). The `specs/requirements/` module can
assign that role to an existing service principal (and optionally create the
vault); the client secret goes to the agent directly, never through tofu.
