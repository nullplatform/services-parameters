# Parameters Package — Architecture

A pluggable parameter and secret storage layer for nullplatform scopes. The provider for each parameter is chosen by the platform itself (via `provider.specification_id` in the notification payload), and the provider's configuration travels in the same payload.

---

## What problem this solves

nullplatform scopes need to persist parameter values somewhere. Different organizations want different backends:

- AWS-native: Secrets Manager and/or Parameter Store
- Azure-native: Key Vault
- Existing HashiCorp infrastructure: Vault
- Hybrid setups: any combination of the above

A monolithic scope tied to one backend forces fork-and-modify for every variation. This package inverts the relationship: the **dispatch layer is the package**, the **backends are pluggable modules** dropped into `providers/`.

The platform decides which provider handles each parameter and which configuration it uses. Operators register `parameters-storage` providers in nullplatform (one per backend they want to support — AWS Secrets Manager, Vault, etc.) with their region/address/etc. The notification payload then carries both the choice and its configuration to the agent. A single agent can serve parameters routed to multiple backends simultaneously without per-agent configuration.

---

## Layered design

```
┌────────────────────────────────────────────────────────────────┐
│  nullplatform sends action notification                        │
│  (NOTIFICATION_ACTION="parameter:<action>", NP_ACTION_CONTEXT) │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  parameters/entrypoint                                         │
│  - Clean NP_ACTION_CONTEXT, export CONTEXT (= .notification)   │
│  - Pick workflow: workflows/<action>.yaml                      │
│  - Honor OVERRIDES_PATH for consumer-side workflow overrides   │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  workflows/<action>.yaml                                       │
│  - Step 1: build_context                                       │
│  - Step 2: <action> (store / retrieve / delete / notify)       │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  parameters/utils/build_context                                │
│  - Parse CONTEXT → EXTERNAL_ID, PARAMETER_ID, PARAMETER_VALUE  │
│  - Derive PARAMETER_KIND from $CONTEXT.secret                  │
│  - Read $CONTEXT.provider.specification_id                     │
│  - np provider specification read --id <spec_id> → slug        │
│  - ACTIVE_PROVIDER = slug; PROVIDER_DIR = providers/$slug      │
│  - PROVIDER_CONFIG = $CONTEXT.provider.attributes              │
│  - Source providers/$ACTIVE_PROVIDER/setup                     │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  parameters/utils/dispatch  (unified dispatcher)               │
│  - Reads $ACTION (set by workflow `configuration:` block)      │
│  - source providers/$ACTIVE_PROVIDER/$ACTION                   │
│  - Special-case: ACTION=notify with no provider notify → ack   │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  providers/<active_provider>/<action>                          │
│  - Executes the actual backend call (curl, aws, az, ...)       │
│  - Writes JSON result to stdout                                │
└────────────────────────────────────────────────────────────────┘
```

The dispatch layer is **provider-agnostic**. It has zero knowledge of any specific provider's existence. Adding a new provider is strictly additive — no edits to `entrypoint`, `build_context`, `workflows/`, or other providers.

---

## Storage naming: human-friendliness principle

Every provider composes its storage path from the parameter's NRN entities (slugs + IDs), dimensions, and parameter name + ID. The principle is that an operator entering the storage layer manually (AWS console, Vault UI, az portal) must be able to find any secret by knowing the parameter's context, without consulting nullplatform's database.

The shared helper `parameters/utils/build_external_id` constructs the canonical form, fetching slugs from the np CLI in parallel:

```
<provider_prefix>/organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim_key>=<dim_value>...]/<parameter_name>-<parameter_id>
```

**Required entities** (always present, always in this order): `organization`, `account`, `namespace`, `application`.

**Optional entity**: `scope` — appears as a segment between `application` and dimensions, only when the parameter is bound to a specific deployment scope.

**Optional dimensions**: zero or more `key=value` segments, sorted alphabetically by key for determinism. A parameter without dimensions has no dimension segments in the path at all.

Each provider applies the prefix (default `nullplatform/`) and any backend-specific sanitization (Azure Key Vault flattens slashes and equals to dashes, GCP Secret Manager maps slashes to `__` and equals to `-`; everyone else uses the canonical form). The canonical `external_id` returned to nullplatform is the same across all providers, which makes parameter migration between backends mechanically possible.

### Version encoding in external_id

The `external_id` also carries the version identifier as a suffix:

```
<canonical_path>#<version_id>
```

The `version_id` is **the native version identifier returned by each backend** — no normalization, no invention. Each provider copies it verbatim from the backend's response. The format varies per backend:

| Provider             | Version ID format               | Example                                          |
|----------------------|----------------------------------|--------------------------------------------------|
| `aws-secrets-manager` | UUID v4 (from `VersionId`)       | `a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d`           |
| `hashicorp-vault`    | Integer (from `.data.version`)   | `3`                                              |
| `aws-parameter-store`    | Integer (from `.Version`)        | `7`                                              |
| `azure-key-vault`    | 32-char hex (URL last segment)   | `93a0b2eb12a64fa7b3acb18900a8d33d`               |
| `gcp-secret-manager` | Integer (version name last segment) | `3`                                           |

Because nullplatform already persists and re-sends `external_id` on every operation, this versioning works without any platform-side changes. On `retrieve`, the dispatcher's `build_context` splits the suffix; provider scripts use it to target a specific historical version via the backend's native version-fetching mechanism (`--version-id`, `?version=N`, `:N`, `--version`).

---

## How the provider is chosen

For each parameter, nullplatform stores which provider should handle it. That choice travels with every notification as `provider.specification_id` — a UUID pointing to a "provider specification" entity in nullplatform.

`build_context` resolves this UUID into a slug using the np CLI:

```
np provider specification read --id <specification_id> --format json
→ { "slug": "aws-secrets-manager", ... }
```

The slug becomes `ACTIVE_PROVIDER`, which must match a directory under `parameters/providers/`. The match is exact, case-sensitive.

The provider's configuration travels in the same payload at `provider.attributes`. `build_context` exports it as `PROVIDER_CONFIG` (a JSON string). Each provider's `setup` reads from `PROVIDER_CONFIG` via `get_config_value --provider '.field'` to extract specific fields (region, kms_key_id, etc.).

The provider's configuration is registered upfront as a `parameters-storage` provider in nullplatform. The platform then attaches that configuration to each parameter via `provider.specification_id`. A single agent can serve parameters routed to multiple backends at the same time, without per-agent configuration.

---

## File tree

```
parameters/
├── entrypoint              # Action router (the only loose script — entry point)
├── workflows/              # 4 YAMLs (one per action), each sets ACTION via configuration
├── utils/                  # All shared scripts live here
│   ├── build_context       # Resolves ACTIVE_PROVIDER from spec_id, sources setup
│   ├── build_external_id   # Composes <path>#<version> via parallel np slug fetches
│   ├── dispatch            # Unified action dispatcher (reads $ACTION)
│   ├── get_config_value    # Priority: provider config > env > default
│   └── log                 # All levels route to stderr
├── providers/
│   ├── README.md           # Contract every provider must satisfy
│   ├── hashicorp-vault/    # HTTP API
│   ├── aws-secrets-manager/ # aws CLI
│   ├── aws-parameter-store/    # aws CLI (only kind-branching provider)
│   ├── azure-key-vault/    # REST API (curl)
│   └── gcp-secret-manager/ # REST API (curl), Workload Identity
├── tests/                  # BATS — mirrors source structure
└── docs/                   # This file, configuration.md, adding_a_provider.md
```

See `parameters/providers/README.md` for the provider contract spec.
See `configuration.md` for the payload shape and how `PROVIDER_CONFIG` is structured.
See `adding_a_provider.md` to drop in a new backend.
