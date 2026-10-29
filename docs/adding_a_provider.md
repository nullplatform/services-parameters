# Adding a New Provider

Step-by-step guide to add a new backend (e.g. Google Secret Manager, Doppler, 1Password Secrets Automation).

The parameters package is designed so that adding a provider is **strictly additive**. You drop a directory under `providers/`; nothing outside it changes.

---

## Core principles (read this before anything else)

Every provider in this package follows the same two cross-cutting principles. Your implementation MUST honor them; deviation is not a per-provider choice.

### 1. Naming is human-friendly and hierarchical

The storage path/name for every secret is composed from the parameter's context: account + namespace + application + (scope if present) + (dimensions if present) + parameter name + parameter id + revision. Both the entity slug AND id are included so the name is readable AND stable across renames.

All names are grouped under a `nullplatform` top-level prefix (default — operators can override via provider config). This is the IAM scoping anchor and the visual marker in the backend's console.

The shared helper `parameters/utils/build_external_id` constructs the canonical form. Your `store` calls it once at the top:

```
nullplatform/organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim_key>=<dim_value>...]/<parameter_name>-<parameter_id>
```

Two segments are conditional:

- **`scope` entity** is optional — appears only when the parameter is bound to a specific deployment scope, between `application` and dimensions.
- **Dimensions** are optional — a parameter may have zero, one, or many. Present dimensions are sorted alphabetically by key.

The required entities (`organization`, `account`, `namespace`, `application`) are always present in nullplatform's NRN, in that canonical order.

The principle: an operator who opens the backend's UI (AWS Console, Vault UI, Azure Portal) must be able to navigate to any secret by knowing the parameter's nullplatform context, without consulting the platform's database. The path tells the story.

If your backend has naming restrictions (e.g. Azure Key Vault disallows `/` and `=`), transform the canonical form deterministically inside your `store`/`retrieve`/`delete`. The `external_id` returned to nullplatform always uses the canonical (slash) form so it's portable across providers.

### 2. Versioning is mandatory and cost-aware

nullplatform parameter values are **immutable**. Every update to a `(parameter_id, NRN, dimensions)` tuple creates a new revision. nullplatform may ask you to retrieve a specific historical revision (e.g. to display in UI or to support restore — which is implemented as "read old revision + store as new revision").

Your provider MUST keep the version history. Two rules:

- **Don't lose old revisions on update**. If the backend has native versioning (AWS SM, Vault KV v2, AWS Parameter Store, Azure Key Vault all do), use it: append a new version to the same key. If the backend doesn't have native versioning, store revisions inside a single record (e.g. JSON list, append-only structure) — keep them in one logical entity to avoid cost explosion.
- **Never create a new top-level entity per revision** if the backend charges per entity. AWS Secrets Manager charges $0.40/secret/month regardless of version count; creating one secret per version would multiply cost linearly with update frequency. Native versioning is essentially free.

Version identity is encoded in the `external_id` returned by store:

```
<canonical_path>#<version_id>
```

Where `version_id` is the **literal native identifier the backend returns** — not invented, not normalized. AWS SM gives a UUID; Vault gives an integer; Parameter Store gives an integer; AKV gives a 32-char hex. Use whatever the backend hands you, verbatim.

Because nullplatform persists and re-sends `external_id` on every operation, the version reference round-trips automatically without any platform-side state. On `retrieve`, split on `#` to get both pieces; use the version via the backend's native lookup (e.g. `--version-id`, `?version=N`, `:N`, `--version`). On `delete`, ignore the version suffix — delete removes all revisions.

---

## What you need to know about the backend

Before you start, answer these questions:

| Question                                                | Why it matters                                  |
|---------------------------------------------------------|-------------------------------------------------|
| What CLI / API do you call?                             | Determines your tooling (curl, aws, az, gcloud) |
| How does authentication work?                           | Defines what `setup` validates                  |
| What's the naming convention for stored items?          | Defines your prefix + UUID scheme               |
| Does it have soft-delete?                               | Determines if `delete` needs a purge step       |
| Does it distinguish secret vs plain types at the API?   | Determines if `store` branches on PARAMETER_KIND |

---

## Step 1: Create the provider directory

```bash
mkdir -p parameters/providers/<provider_name>/docs
mkdir -p parameters/tests/providers/<provider_name>
```

`<provider_name>` must match the `slug` field of the `parameters-storage` provider specification you (or the platform admin) registered in nullplatform. The agent's `build_context` calls `np provider specification read --id <specification_id>`, reads `.slug`, and uses it to find your directory.

---

## Step 2: Write `setup`

Validate config and export connection handles. Don't repeat this in operation scripts — `setup` is the DRY anchor.

Config values can come from **two sources**, and `get_config_value` picks whichever is present (provider config wins, env fallback, defaults last):

1. **`parameters-storage` provider in nullplatform** — values set when the provider is registered, sent to the agent in `$CONTEXT.provider.attributes`. Good for non-sensitive operational settings (region, name prefix, vault address, etc.).
2. **Environment variables on the agent** — set by the operator outside nullplatform. **Recommended for credentials, tokens, and any sensitive material** that should not be stored in nullplatform's database. This keeps ownership of sensitive data 100% on the operator side and lets them use their own protection mechanisms (secret stores, rotation, etc.).

```bash
#!/bin/bash
set -euo pipefail

# Read config (provider config wins, env fallback, defaults last)
MY_ENDPOINT=$(get_config_value --env MY_ENDPOINT --provider '.endpoint')
# Token: only env var — do NOT pass via provider config (keep credentials off-platform)
MY_TOKEN=$(get_config_value --env MY_TOKEN)
MY_PREFIX=$(get_config_value --env MY_PREFIX --provider '.prefix' --default 'nullplatform-')

if [ -z "$MY_ENDPOINT" ]; then
  log error "❌ <Backend> endpoint not configured"
  log error ""
  log error "💡 Possible causes:"
  log error "   • MY_ENDPOINT env var is not set"
  log error "   • .endpoint is missing in PROVIDER_CONFIG"
  log error ""
  log error "🔧 How to fix:"
  log error "   • Set MY_ENDPOINT=<value>"
  exit 1
fi

# Validate format / shape if relevant
# ...

export MY_ENDPOINT MY_TOKEN MY_PREFIX
```

---

## Step 3: Write the four operation scripts

### `store`

Generate a UUID, persist the value, return `{external_id, metadata}`.

```bash
#!/bin/bash
set -euo pipefail

EXTERNAL_ID=$(uuidgen 2>/dev/null || echo "$(openssl rand -hex 16 | sed 's/\(.{8}\)\(.{4}\)\(.{4}\)\(.{4}\)\(.{12}\)/\1-\2-\3-\4-\5/')")
NAME="${MY_PREFIX}${EXTERNAL_ID}"

if ! HANDLE=$(my_cli create --endpoint "$MY_ENDPOINT" --name "$NAME" --value "$PARAMETER_VALUE" 2>/dev/null); then
  log error "❌ Failed to store in <Backend>"
  log error ""
  log error "💡 Possible causes:"
  log error "   • <causes specific to the backend>"
  log error ""
  log error "🔧 How to fix:"
  log error "   • <commands to verify identity / connectivity>"
  exit 1
fi

jq -n \
  --arg external_id "$EXTERNAL_ID" \
  --arg handle "$HANDLE" \
  --arg name "$NAME" \
  '{external_id: $external_id, metadata: {handle: $handle, name: $name}}'
```

If your backend distinguishes types (like `aws-parameter-store` does with String/SecureString), branch on `PARAMETER_KIND` here.

### `retrieve`

Read the value and return `{value}`. On any failure — including "not found" — exit non-zero with troubleshooting. Do NOT return a sentinel value like "value not found" as if it were a real value; that would be a misleading payload (the platform would treat the literal string as the parameter's value).

If the backend distinguishes "not found" from other errors, include that distinction in the troubleshooting message so the platform can categorize. Both still exit non-zero.

```bash
#!/bin/bash
set -euo pipefail

NAME="${MY_PREFIX}${EXTERNAL_ID_PATH}"  # use _PATH (canonical, no version suffix)

err_file=$(mktemp)
if VALUE=$(my_cli get --endpoint "$MY_ENDPOINT" --name "$NAME" 2>"$err_file"); then
  rm -f "$err_file"
  jq -n --arg value "$VALUE" '{value: $value}'
else
  err=$(cat "$err_file")
  rm -f "$err_file"
  if echo "$err" | grep -q "<backend's not-found error code>"; then
    log error "❌ Secret '$NAME' not found in <Backend>"
    log error ""
    log error "💡 Possible causes:"
    log error "   • The secret was manually deleted from the backend"
    log error "   • The external_id is stale"
    log error ""
    log error "🔧 How to fix:"
    log error "   • Verify: my_cli describe --name $NAME"
    exit 1
  else
    log error "❌ Failed to retrieve from <Backend>"
    log error ""
    log error "💡 Possible causes:"
    log error "   • <auth / network / permission causes>"
    log error ""
    log error "🔧 How to fix:"
    log error "   • <verification commands>"
    log error "Underlying error: $err"
    exit 1
  fi
fi
```

### `delete`

Idempotent — re-deleting a missing resource is success. But **only "not found" is suppressed**; any other failure (permission denied, network error, server error) MUST propagate as exit 1 with troubleshooting. Reporting success when the work didn't actually happen leads to "client thinks it's deleted but it's still there" bugs.

```bash
#!/bin/bash
set -euo pipefail

NAME="${MY_PREFIX}${EXTERNAL_ID_PATH}"  # delete removes ALL versions; ignore version suffix

err_file=$(mktemp)
if my_cli delete --endpoint "$MY_ENDPOINT" --name "$NAME" >/dev/null 2>"$err_file"; then
  rm -f "$err_file"
  echo '{
  "success": true
}'
else
  err=$(cat "$err_file")
  rm -f "$err_file"
  if echo "$err" | grep -q "<backend's not-found error code>"; then
    log debug "Resource '$NAME' does not exist, treating delete as idempotent success"
    echo '{
  "success": true
}'
  else
    log error "❌ Failed to delete '$NAME' from <Backend>"
    log error ""
    log error "💡 Possible causes:"
    log error "   • <auth / network / permission causes>"
    log error ""
    log error "🔧 How to fix:"
    log error "   • <verification commands>"
    log error "Underlying error: $err"
    exit 1
  fi
fi
```

### `notify` (optional)

Skip the file unless your backend needs a per-notify side effect. The dispatch returns the default `{success: true}` if `notify` doesn't exist.

---

## Step 5: Write tests

Mirror the source structure under `parameters/tests/providers/<provider_name>/`:

```
tests/providers/<provider_name>/
├── setup.bats       # Config resolution, validation, error paths
├── store.bats       # JSON output shape, CLI args, error paths
├── retrieve.bats    # Hit case, miss case, CLI args
└── delete.bats      # Always-success, CLI args, idempotency
```

Use the patterns from existing providers (`hashicorp-vault`, `aws-secrets-manager`, `aws-parameter-store`, `azure-key-vault`):

- Mock the backend CLI as a script in `$BATS_TEST_TMPDIR/bin/`, export PATH to find it.
- Capture CLI args to a log file, assert on them.
- Mock `uuidgen` for deterministic `external_id` in store tests.
- Use the `DEPS="source $PARAMETERS_DIR/utils/log"` pattern to make `log` available in `bash -c` subshells.

Aim for at least these scenarios per provider:

| Script    | Required tests                                                              |
|-----------|-----------------------------------------------------------------------------|
| setup     | Missing required config fails with troubleshooting; PROVIDER_CONFIG wins over env; defaults applied |
| store     | Output JSON shape; external_id includes path + #version suffix; first store uses create, subsequent uses native versioning API; failure paths exit non-zero with troubleshooting |
| retrieve  | Hit returns value; not-found exits non-zero with troubleshooting; with-version targets historical revision; auth/network errors exit non-zero |
| delete    | Returns `{success: true}` on success; not-found is treated as success (idempotent); other errors propagate as exit 1 with troubleshooting |

---

## Step 6: Write the docs

Add at least `parameters/providers/<provider_name>/docs/architecture.md` describing:

- Storage layout (naming, prefix, encryption model)
- Cost model
- Authentication
- Any quirks (soft-delete, regions, multi-tenant constraints)

If the backend needs IAM-style permissions (AWS, GCP), add `iam-policy.md` with a least-privilege example using placeholders for accounts/regions/keys.

---

## Step 7: Wire it up

1. Register a `parameters-storage` provider in nullplatform with `slug: <provider_name>` and the schema for your provider's config attributes (use a `.json.tpl` file as the spec — see existing providers for examples).
2. Bind parameters in nullplatform to that provider specification.

Done. The agent receives `provider.specification_id` and `provider.attributes` in every notification for those parameters; `build_context` resolves the slug, finds your directory, and dispatches.

---

## Checklist

Before considering a new provider complete:

- [ ] Naming follows the human-friendly hierarchical convention (entity slug-id + dimensions + parameter name-id), under the `nullplatform/` prefix
- [ ] `store` uses `build_external_id` to compose the canonical path
- [ ] `store` returns `external_id = <canonical_path>#<version_id>` with the native backend version identifier (not invented)
- [ ] Versioning uses the backend's native mechanism (not new top-level entities per revision)
- [ ] `setup` validates config and exits with troubleshooting on missing fields
- [ ] `store` outputs `{external_id, metadata}` JSON
- [ ] `retrieve` outputs `{value}` on success; **exits non-zero on not-found with clear troubleshooting** (no "value not found" sentinel)
- [ ] `retrieve` honors `EXTERNAL_ID_VERSION` to target historical revisions
- [ ] `delete` outputs `{success: true}` on success and on not-found (idempotent); **exits non-zero on any other error** (no `|| true` blanket suppression)
- [ ] Scripts use `set -euo pipefail`
- [ ] Errors go to stderr via `log error "..."`
- [ ] No stdout output other than the final JSON
- [ ] Every error has `💡 Possible causes:` and `🔧 How to fix:` blocks
- [ ] BATS tests cover setup error paths, store output shape (incl. version suffix), retrieve hit + not-found-error + auth-error, delete success + not-found-idempotent + other-error-propagation
- [ ] `architecture.md` documents storage layout, versioning behavior, and the native version_id format
- [ ] If the backend has IAM, `iam-policy.md` shows least-privilege scoping
- [ ] A `<provider_name>_configuration.json.tpl` exists with the `parameters-storage` category and the schema for the provider's config attributes
