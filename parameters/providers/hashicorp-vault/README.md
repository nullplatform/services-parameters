# HashiCorp Vault parameters provider

Stores nullplatform parameter values in HashiCorp Vault KV v2, using Vault's
native versioning. See [`docs/architecture.md`](./docs/architecture.md) for the
full lifecycle, storage layout, and versioning model.

## Configuration

Provider config (from the nullplatform provider specification):

| Field                  | Required            | Description                                                                 |
|------------------------|---------------------|-----------------------------------------------------------------------------|
| `setup.address`        | yes                 | Vault HTTP(S) endpoint, e.g. `https://vault.example.com:8200`.               |
| `setup.namespace`      | no (default root)   | Vault Enterprise namespace the parameters live under, e.g. `admin/eks-null-alfa-136`. Leave empty for the root namespace (Vault OSS). |
| `setup.path_prefix`    | no (default `secret/data/nullplatform`) | KV v2 path prefix (relative to the namespace) parameters are stored under. Must be the full `<mount>/data/<subpath>`. |
| `setup.auth_mode`      | yes (default `userpass`) | Authentication mode: `userpass` or `kubernetes`.                       |
| `setup.kubernetes_role`| when `kubernetes`   | Vault Kubernetes auth role bound to the agent's ServiceAccount.              |

`namespace` and `path_prefix` are **two independent axes**:

- **`setup.namespace`** (env: `VAULT_NAMESPACE`) — the Vault Enterprise namespace.
  It is applied as a URL prefix (`$VAULT_ADDR/v1/<namespace>/…`) on the login **and**
  on every store/retrieve/delete request. Empty means the root namespace, so
  non-Enterprise (Vault OSS) deployments simply leave it unset.
- **`setup.path_prefix`** (env: `VAULT_PATH_PREFIX`, default
  `secret/data/nullplatform`) — the KV v2 path prefix relative to the namespace. It
  must be the full `<mount>/data/<subpath>`: the mount name, then the KV v2 `data`
  segment, then an optional subpath. `store` embeds it in the `external_id`, so
  stored references survive a later `path_prefix` change.

The auth mounts are fixed to Vault's defaults (`auth/userpass`, `auth/kubernetes`).

### Vault Enterprise namespaces

On Vault Enterprise, credentials and roles are scoped to a namespace, so the login
must target that namespace or Vault returns **access denied**. Inside a namespace, a
KV v2 secret lives at `<namespace>/<mount>/data/<subpath>` — the mount name sits
between the namespace and `data`, which is why the two are configured separately.

| `setup.namespace`       | `setup.path_prefix`         | Full KV path used by store/retrieve       |
|-------------------------|-----------------------------|-------------------------------------------|
| *(empty — root)*        | `secret/data/nullplatform` *(default)* | `secret/data/nullplatform/…`   |
| *(empty — root)*        | `secret/data/team-x`        | `secret/data/team-x/…`                    |
| `admin/ns`              | `secret/data/nullplatform`  | `admin/ns/secret/data/nullplatform/…`     |
| `admin/team/sub`        | `kv/data/params`            | `admin/team/sub/kv/data/params/…`         |

> **Note:** changing `setup.namespace` after parameters exist is a migration, not a
> config tweak — the namespace is not embedded in the `external_id`, and Vault does
> not move secrets between namespaces. Point it at the namespace where the secrets
> already live.

> **Note:** the Vault policy examples below grant access to the default
> `secret/data/nullplatform/*` (and `secret/metadata/nullplatform/*`) paths. If you
> set a custom `setup.path_prefix`, adjust the policy paths to match it — the KV
> mount and the `metadata/` counterpart of your configured `data/` path. On Vault
> Enterprise, write the policy inside the configured `setup.namespace`.

## Authentication

`setup` exchanges the configured credentials/identity for a short-lived Vault
client token and exports it as `VAULT_TOKEN`; `store` / `retrieve` / `delete` then
use it via the `X-Vault-Token` header.

### Mode: `userpass`

The agent logs in with a username and password. Both are **sensitive** and are
read from environment variables in the agent runtime — never from provider config:

| Env var          | Description                       |
|------------------|-----------------------------------|
| `VAULT_USERNAME` | Vault `userpass` username.        |
| `VAULT_PASSWORD` | Vault `userpass` password.        |

Vault setup:

```sh
# Enable userpass (once per Vault)
vault auth enable userpass

# Policy granting read/write on the nullplatform namespace
vault policy write nullplatform-parameters - <<'EOF'
path "secret/data/nullplatform/*"     { capabilities = ["create", "update", "read"] }
path "secret/metadata/nullplatform/*" { capabilities = ["read", "delete", "list"] }
EOF

# Create the user and bind the policy
vault write auth/userpass/users/<username> \
  password="<password>" \
  token_policies="nullplatform-parameters"
```

Set `VAULT_USERNAME` / `VAULT_PASSWORD` in the agent Helm installation (as secret
env vars).

### Mode: `kubernetes`

The agent authenticates with its **Kubernetes ServiceAccount identity** — there
are no secrets to configure. It reads the projected ServiceAccount token (default
path `/var/run/secrets/kubernetes.io/serviceaccount/token`, overridable via
`VAULT_K8S_JWT_PATH`) and exchanges it for a Vault token bound to `kubernetes_role`.

#### 1. Vault setup

```sh
# Enable the kubernetes auth method (once per Vault)
vault auth enable kubernetes

# Point Vault at the cluster's API server. When Vault runs inside the cluster it
# can use its own ServiceAccount token and the in-cluster CA:
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

# Policy granting read/write on the nullplatform namespace
vault policy write nullplatform-parameters - <<'EOF'
path "secret/data/nullplatform/*"     { capabilities = ["create", "update", "read"] }
path "secret/metadata/nullplatform/*" { capabilities = ["read", "delete", "list"] }
EOF

# Role binding the agent's ServiceAccount (name + namespace) to the policy.
# The role name here must match setup.kubernetes_role.
vault write auth/kubernetes/role/nullplatform-agent \
  bound_service_account_names="<agent-serviceaccount>" \
  bound_service_account_namespaces="<agent-namespace>" \
  token_policies="nullplatform-parameters" \
  ttl="1h"
```

#### 2. Cluster setup

The in-cluster resources Vault's kubernetes auth needs are provisioned by the
Terraform module in [`specs/requirements/`](./specs/requirements/) — it applies
`.yaml` templates for the agent ServiceAccount and the token-reviewer
ServiceAccount + its `system:auth-delegator` ClusterRoleBinding:

```sh
cd specs/requirements
cp terraform.tfvars.example terraform.tfvars   # edit agent namespace + SA name
tofu init && tofu apply
```

> The manifests are applied with `kubernetes_manifest`, which reaches the cluster
> API at **plan** time (server-side dry-run), not just apply. Make sure the target
> cluster is reachable and pin the context with `kube_config_context` — this module
> creates a cluster-wide `ClusterRoleBinding`.

Its outputs (`agent_service_account`, `token_reviewer_service_account`) give the
names/namespaces to plug into the Vault role bindings and the `token_reviewer_jwt`
above. The agent pod must run with that ServiceAccount and mount its token
(`serviceAccountName: <agent-serviceaccount>`, `automountServiceAccountToken: true`).

Then set `setup.auth_mode = kubernetes` and `setup.kubernetes_role = nullplatform-agent`
in the provider config (see [`specs/install/`](./specs/install/)). No credential
env vars are needed in this mode.

## Installation

The provider specification and per-instance configs are installed with the
Terraform in [`specs/install/`](./specs/install/), which builds on the shared
`parameter_storage_definition` / `parameter_storage_configuration` modules
(same structure as the AWS providers). For the `kubernetes` auth mode, apply
[`specs/requirements/`](./specs/requirements/) first (see above).

## Troubleshooting

`setup` fails fast with actionable messages when the address or credentials are
missing, and when the login endpoint returns no token (wrong credentials, role
not bound to the ServiceAccount, or the auth method not enabled). Re-read the
error output — it names the exact env var / config field / Vault command to check.
