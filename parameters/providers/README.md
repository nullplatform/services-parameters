# Provider Contract

This directory contains all concrete provider implementations. Each subdirectory is one provider — fully self-contained.

The dispatch layer (`parameters/build_context` + `parameters/{store,retrieve,delete,notify}`) is provider-agnostic. It selects a provider at runtime from env vars `SECRET_PROVIDER` / `PARAMETER_PROVIDER` and sources the matching scripts.

**Adding a new provider is a strictly additive change**: drop a directory here that satisfies this contract. No edits to dispatch, build_context, workflows, or other providers are required. The parameters package has zero knowledge of any specific provider.

---

## Required layout

```
providers/<provider_name>/
├── fetch_configuration   # (optional) Fetch this provider's config from wherever it lives
├── setup                 # (optional) Validate config, prepare connection handles
├── store                 # (required) Persist a parameter value
├── retrieve              # (required) Read a value by external_id
├── delete                # (required) Idempotent delete by external_id
├── notify                # (optional) Per-provider notify hook (default is {"success":true})
└── docs/                 # (recommended) architecture.md, iam-policy.md, etc.
```

`<provider_name>` is the string users set in `SECRET_PROVIDER` / `PARAMETER_PROVIDER`. Use `snake_case` (e.g. `hashicorp-vault`, `azure-key-vault`, `aws-parameter-store`).

---

## Lifecycle of one workflow run

1. `entrypoint` cleans `NP_ACTION_CONTEXT`, exports `CONTEXT` (= notification body), routes to the right workflow YAML.
2. Workflow's `build_context` step:
   - Determines `PARAMETER_KIND` from workflow `configuration` or `$CONTEXT.secret`.
   - Resolves `ACTIVE_PROVIDER` from `SECRET_PROVIDER` or `PARAMETER_PROVIDER` env var.
   - Sources `providers/$ACTIVE_PROVIDER/fetch_configuration` if present.
   - Sources `providers/$ACTIVE_PROVIDER/setup` if present.
3. Workflow's operation step (`store`/`retrieve`/`delete`/`notify`) sources `providers/$ACTIVE_PROVIDER/<operation>` and produces the JSON response.

All steps share the same bash session — env vars set in any step are visible to the next.

---

## Environment available to your scripts

By the time any of your scripts runs, `build_context` has exported:

| Variable             | Description                                                     |
|----------------------|-----------------------------------------------------------------|
| `CONTEXT`            | JSON of the notification body (`.notification` of the action)   |
| `PARAMETER_KIND`     | `"secret"` or `"parameter"`                                     |
| `EXTERNAL_ID`        | Existing handle for retrieve/delete/notify; empty for store     |
| `PARAMETER_ID`       | nullplatform parameter ID                                       |
| `PARAMETER_VALUE`    | The value to store (only set for store)                         |
| `PARAMETER_NAME`     | Display name (e.g. `DB_PASSWORD`)                               |
| `PARAMETER_ENCODING` | Encoding of the value (e.g. `plain`, `base64`)                  |
| `PROVIDER_DIR`       | Absolute path to your provider directory                        |
| `PARAMETERS_ROOT`    | Absolute path to the parameters package root                    |
| `PROVIDER_CONFIG`    | (optional) JSON your `fetch_configuration` set — its shape is up to you |

The function `get_config_value` is already sourced — see usage below.

---

## `fetch_configuration` (optional)

Your provider's place to bring config in from the outside world. Sourced **once** at the start of every workflow run, before `setup`.

Free-form by design — each provider knows best how to fetch its own config. Examples:

- Call `np provider get --type <something>` and parse JSON
- `curl` a REST endpoint
- Read a file mounted by the runner
- Just rely on env vars (do nothing — omit the file)

Convention: if you produce a JSON blob with your config, export it as `PROVIDER_CONFIG`. Then `get_config_value --provider '.field'` reads from it directly:

```bash
#!/bin/bash
# providers/example/fetch_configuration
PROVIDER_CONFIG=$(np provider get --type my-thing --output json)
export PROVIDER_CONFIG
```

Then in `setup`:

```bash
ADDR=$(get_config_value --env MY_ADDR --provider '.address')
```

If you don't need provider config, just skip `fetch_configuration` entirely. Operations can use env vars directly:

```bash
ADDR="${MY_ADDR:-}"
[ -z "$ADDR" ] && { log error "❌ MY_ADDR not set"; exit 1; }
```

---

## `setup` (optional)

Sourced after `fetch_configuration`. Use it to:

1. Read provider-specific config (from env vars and/or `PROVIDER_CONFIG`).
2. Validate that all required fields are present. Fail fast with troubleshooting guidance if not.
3. Export connection handles (URLs, tokens, regions, prefixes) for the operation scripts.

Do **not** repeat credential validation inside `store`/`retrieve`/`delete`. That's the whole point of `setup`.

Example:

```bash
#!/bin/bash
# providers/hashicorp-vault/setup
VAULT_ADDR=$(get_config_value --env VAULT_ADDR --provider '.address')
VAULT_TOKEN=$(get_config_value --env VAULT_TOKEN --provider '.token')

[ -z "$VAULT_ADDR" ]  && { log error "❌ vault address missing"; exit 1; }
[ -z "$VAULT_TOKEN" ] && { log error "❌ vault token missing";   exit 1; }

export VAULT_ADDR VAULT_TOKEN
```

---

## Operation scripts

Each produces **JSON on stdout** and routes **error messages to stderr**. The platform parses stdout as the action result.

### `store` — required

Input env: `PARAMETER_VALUE`, `PARAMETER_ID`, `PARAMETER_KIND`, plus your `setup` exports.

Output:
```json
{
  "external_id": "<provider-generated handle>",
  "metadata":    { "...": "provider-specific" }
}
```

`external_id` becomes the canonical handle. `metadata` is opaque to nullplatform but useful for auditing.

### `retrieve` — required

Input env: `EXTERNAL_ID`, plus `setup` exports.

Output:
```json
{ "value": "<stored value>" }
```

If not found, return `{"value": "value not found"}` rather than erroring (precedent: existing vault/aws-secrets-manager impls).

### `delete` — required

Input env: `EXTERNAL_ID`, plus `setup` exports.

Output:
```json
{ "success": true }
```

Must be **idempotent**: re-deleting a missing handle is not an error.

### `notify` — optional

Input env: `EXTERNAL_ID`, `PARAMETER_ID`, plus `setup` exports.

Output:
```json
{ "success": true }
```

Omit the file if your provider has nothing to do — the dispatch returns the default ack.

---

## Conventions

- Start every script with `set -euo pipefail`.
- Use `log error "..."` for error messages — it routes to stderr automatically.
- Every error message must include `💡 Possible causes:` and `🔧 How to fix:` blocks.
- Never print anything to stdout other than the final JSON result. The platform reads stdout literally.
- Don't validate `PROVIDER_DIR`, `EXTERNAL_ID`, or other dispatch-exported vars — assume `build_context` produced valid state. Validate only your provider-specific config in `setup`.
- Each operation should be **idempotent where it makes sense** (delete always, retrieve when missing, store typically not — the platform enforces store idempotency at its layer).
