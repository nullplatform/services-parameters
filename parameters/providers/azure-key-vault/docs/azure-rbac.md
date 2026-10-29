# Azure RBAC

Minimum Azure permissions for `parameters/providers/azure-key-vault/`. The agent
authenticates as an Azure AD **service principal** (client id + secret) and
operates on secrets in a specific Key Vault. Scope the role assignment to the
vault so the service principal cannot reach any secret outside this provider's
domain.

This provider assumes the vault uses the **Azure RBAC** authorization model
(`rbac_authorization_enabled = true`), not the legacy access-policy model.

---

## Required data actions

| Data action                                          | Used by    | Why                                                    |
|------------------------------------------------------|------------|--------------------------------------------------------|
| `Microsoft.KeyVault/vaults/secrets/setSecret/action` | `store`    | Creates the secret / adds a new version                |
| `Microsoft.KeyVault/vaults/secrets/getSecret/action` | `retrieve` | Reads the current (or a specific historical) version   |
| `Microsoft.KeyVault/vaults/secrets/delete`           | `delete`   | Soft-deletes the secret                                |
| `Microsoft.KeyVault/vaults/secrets/purge/action`     | `delete`   | Purges the soft-deleted secret to release the name     |

---

## Recommended role

The built-in **`Key Vault Secrets Officer`** role covers every data action above
(get, list, set, delete, recover, backup, restore, purge). Assign it scoped to
the vault:

```bash
az role assignment create \
  --assignee "<service-principal-object-id>" \
  --role "Key Vault Secrets Officer" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault-name>"
```

`Key Vault Secrets User` is **not** enough — it grants only get/list, so `store`
and `delete` would fail. Do not grant vault-management roles (e.g.
`Key Vault Administrator`); the agent only needs the secrets data plane.

### Purge

`delete` does a best-effort purge (`DELETE /deletedsecrets/<name>`) after the soft-delete. The
`purge/action` is included in `Key Vault Secrets Officer`. If you deliberately
withhold purge, the provider downgrades the purge failure to a warning and the
secret remains in the soft-delete window until Azure auto-cleans it at retention
expiry (see `architecture.md`).

---

## Granting the service principal (`specs/requirements/`)

The `specs/requirements/` tofu module grants an **existing** service principal
`Key Vault Secrets Officer` over one or more vaults. It does NOT create the
service principal or handle its client secret — you bring your own (e.g. the
client's existing SP). Set `service_principal.enable = true` and pass the SP's
`client_id`; the module resolves its object id and assigns the role, scoped per
vault. Its outputs:

| Output                        | Purpose                                                        |
|-------------------------------|----------------------------------------------------------------|
| `service_principal_object_id` | The RBAC principal the role assignment targets (informational) |
| `tenant_id`                   | Agent env var `AZURE_TENANT_ID`                                |
| `vault_id` / `vault_uri`      | The Key Vault created by the module (see below)                |

The service principal's `client_id` / `client_secret` / `tenant_id` are wired into
the agent as `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID`
**directly** — the secret never passes through this module or its tofu state. The
`setup` script runs the OAuth2 client-credentials flow against Azure AD with
`curl` (no Azure CLI) and exports a short-lived bearer token that
`store`/`retrieve`/`delete` use against the Key Vault REST API.

### Creating the vault (optional)

The same module can also create the Key Vault itself — set `key_vault.enable = true`
and pass `name`, `resource_group_name`, and `location`. It is created with the
Azure RBAC authorization model (`rbac_authorization_enabled = true`, which this
provider requires) and hardened data-plane defaults (purge protection on, 90-day
soft-delete). The `key_vault` and `service_principal` blocks are **independent
toggles** — create only the vault, only the role assignment, or both; when both
are enabled the created vault is added to the SP's RBAC scope automatically.
**`key_vault.name` MUST match the runtime provider config `vault_name`** (and
`AZURE_KEY_VAULT_NAME`) — the two are coupled by name, not by reference, so a
mismatch means the agent authenticates but reads the wrong vault.

Applying this module requires the tofu caller to have Azure AD **directory read**
permission on the service principal (to resolve its object id), `Owner` /
`User Access Administrator` on the vault scope to create role assignments, and
`Contributor` on the vault's resource group when `key_vault.enable = true`, plus a
subscription (`ARM_SUBSCRIPTION_ID`) for the `azurerm` provider.

---

## Security notes

- **The client secret never touches tofu.** This module only assigns the role (by
  the SP's object id); the client secret is supplied to the agent directly as
  `AZURE_CLIENT_SECRET`, so it is not written to tofu state. Rotate it at the
  service principal, independently of tofu.
- **Secret kept off argv.** The client secret is URL-encoded from the environment
  and the token-request body is sent to `curl` on stdin, so — unlike the old
  `az login --password` — the secret never appears on the process's argv. The
  short-lived bearer token does travel in an `Authorization` header (on argv) for
  the vault calls; scope pod PID-namespace isolation accordingly and do not enable
  `shareProcessNamespace` on the agent pod.
- **Least privilege.** Assign only `Key Vault Secrets Officer` scoped per vault
  (as this module does). Do not grant vault-management roles.
