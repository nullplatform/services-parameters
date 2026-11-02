# Configuration

How a worker decides it is the right one for a parameter and where each provider gets its
settings: all from the notification, plus credentials from the environment.

## What the notification carries

| Field | Purpose |
|---|---|
| `parameter_id`, `parameter_name`, `encoding` | the parameter |
| `value` | the value to persist (store only) |
| `external_id` | the handle, `<canonical path>#<version>` (retrieve, delete, notify) |
| `secret` | whether the parameter is a secret; Parameter Store stores a SecureString for one |
| `entities`, `value_entities` | the NRN's entities with their slugs; `value_entities` carries the scope for a scoped value |
| `dimensions`, `value_dimensions` | the parameter's dimensions, and the value's for a scoped value |
| **`provider.specification_slug`** | **which provider handles the parameter**; a worker refuses another provider's |
| **`provider.attributes`** | **that provider's configuration**, as registered in nullplatform |
| `provider.specification_id`, `provider.id`, `provider.nrn`, `provider.dimensions` | informational; `provider.dimensions` is the platform's and is never read |

## Where a setting comes from

`settingOf(attributes, env, { attribute, variable, fallback })`: the provider's attributes
first, the environment second, the default last. The environment wins only where the attribute
is missing, which lets a local run override the platform's configuration. Credentials are read
from the environment only, never from the attributes.

## Per-provider settings

| Provider | Attributes (`provider.attributes.setup`) | Environment |
|---|---|---|
| `aws-secrets-manager` | `kms_key_id` (optional) | `AWS_REGION` (required), `SECRET_MANAGER_ASSUME_ROLE_ARN`, `SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT` |
| `aws-parameter-store` | `kms_key_id` (optional), `tier` (`Standard`, `Advanced`, `Intelligent-Tiering`) | `AWS_REGION` (required), `PARAMETER_STORE_ASSUME_ROLE_ARN`, `PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT` |
| `azure-key-vault` | `vault_name` | `AZURE_KEY_VAULT_NAME`, and the service principal: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` |
| `gcp-secret-manager` | `project_id`, `name_prefix` (default `nullplatform`), `replica_locations` | `GCP_SECRET_MANAGER_PROJECT_ID`, `GCP_SECRET_MANAGER_NAME_PREFIX`, `GCP_SECRET_MANAGER_REPLICA_LOCATIONS`; `GCP_ACCESS_TOKEN` overrides the Workload Identity token |
| `hashicorp-vault` | `address`, `namespace`, `path_prefix` (default `secret/data/nullplatform`), `auth_mode` (`userpass`, `kubernetes`), `kubernetes_role` | `VAULT_ADDR`, `VAULT_NAMESPACE`, `VAULT_PATH_PREFIX`, `VAULT_AUTH_MODE`, `VAULT_K8S_ROLE`, `VAULT_K8S_JWT_PATH`; `VAULT_USERNAME`, `VAULT_PASSWORD` for userpass |

The name prefixes of the AWS backends are fixed (`nullplatform/`, `/nullplatform/`): one
namespace for every platform secret, so historical handles keep resolving.

## The image's own variables

| Variable | Default | Meaning |
|---|---|---|
| `NP_PACKAGE_NAME` | `parameters` | the package the agent's worker pin names |
| `NP_PACKAGE_VERSION` | `0.0.0` | the manifest's version |
| `NP_AGENT_SOURCES` | `service` | the notification sources the manifest's channel subscribes to |

## Local development

Run a provider's tests (`bun test`) against the fakes, or the worker itself against a real
backend with the variables above in the environment: `np package run`
(see the README), or one document through the SDK's exec protocol:

```bash
# The backend is the one the document names in provider.specification_slug:
# here hashicorp-vault, with the variables Vault's setup reads.
VAULT_ADDR=http://localhost:8200 VAULT_USERNAME=np VAULT_PASSWORD=pw \
NP_ACTION_CONTEXT="$(jq '.notification.provider.specification_slug = "hashicorp-vault"' src/samples/store.json)" bun src/main.ts
```
