<h2 align="center">
    <a href="https://nullplatform.com" target="blank_">
        <img height="100" alt="nullplatform" src="https://nullplatform.com/favicon/android-chrome-192x192.png" />
    </a>
    <br>
    <br>
    Parameters — pluggable parameter & secret storage for nullplatform scopes
    <br>
</h2>

A pluggable parameter and secret storage layer for nullplatform scopes. The
platform selects which backend handles each parameter (via the notification
payload), and the provider's configuration travels in that same payload — so a
single agent can serve parameters routed to multiple backends simultaneously,
with no per-agent configuration.

The **dispatch layer is the package**; the **backends are pluggable modules**
under `parameters/providers/`.

## Providers

| Provider | Backend |
|---|---|
| `aws-secrets-manager` | AWS Secrets Manager |
| `aws-parameter-store` | AWS SSM Parameter Store |
| `azure-key-vault` | Azure Key Vault |
| `gcp-secret-manager` | Google Cloud Secret Manager |
| `hashicorp-vault` | HashiCorp Vault (KV v2) |

## How it runs

The package ships as a worker image, `public.ecr.aws/nullplatform/agent-plugins/services/parameters`,
built on the shared `worker-bridge` base. A `parameters` notification channel of
type `package-exec` makes the agent spawn that worker in its own pod and run
`/app/pkg/parameters/entrypoint` there on every `parameter:<action>`, so parameter
reads no longer compete with the agent for CPU and memory. The image adds only
the AWS CLI: the Azure Key Vault, GCP Secret Manager and HashiCorp Vault
providers call their REST APIs with `curl`, which ships with the base.

The channel comes from the `parameter_storage_definition_agent_association`
module in [tofu-modules](https://github.com/nullplatform/tofu-modules) with
`worker_orchestrator = true`. Without it the channel stays the legacy `exec`
one, where the agent clones the repository and runs the entrypoint in its own
container.

## Repository layout

```
.
├── Dockerfile               # worker image (worker-bridge + aws-cli)
├── mise.toml                # run locally as a package (np package run)
├── Makefile                 # test targets (see Testing)
├── testing/                 # scope-testing framework (git submodule)
├── docs/                    # architecture, configuration, adding a provider
└── parameters/
    ├── entrypoint           # action router (parameter:<action> → workflow)
    ├── workflows/           # store / retrieve / delete / notify
    ├── utils/               # build_context, dispatch, assume_role*, prefetch_np, ...
    ├── providers/           # one directory per backend (+ Tofu install specs & docs)
    └── tests/               # BATS unit tests (mirror the source tree)
```

## Documentation

Start here for how the package works end to end:

- [Architecture](docs/architecture.md) — layered design, request flow, and the dispatch model
- [Configuration](docs/configuration.md) — config resolution (payload → env → default) and per-provider variables
- [Adding a provider](docs/adding_a_provider.md) — how to plug in a new backend
- [Provider contract](parameters/providers/README.md) — the `setup`/`store`/`retrieve`/`delete` interface every provider implements

### Per-provider docs

| Provider | Architecture | IAM policy |
|---|---|---|
| AWS Secrets Manager | [architecture](parameters/providers/aws-secrets-manager/docs/architecture.md) | [iam-policy](parameters/providers/aws-secrets-manager/docs/iam-policy.md) |
| AWS Parameter Store | [architecture](parameters/providers/aws-parameter-store/docs/architecture.md) | [iam-policy](parameters/providers/aws-parameter-store/docs/iam-policy.md) |
| Azure Key Vault | [architecture](parameters/providers/azure-key-vault/docs/architecture.md) | — |
| GCP Secret Manager | [architecture](parameters/providers/gcp-secret-manager/docs/architecture.md) | [iam-policy](parameters/providers/gcp-secret-manager/docs/iam-policy.md) |
| HashiCorp Vault | [architecture](parameters/providers/hashicorp-vault/docs/architecture.md) | — |

## Testing

This module uses the testing framework defined in the
[scope-testing](https://github.com/nullplatform/scope-testing) repository, which
is included as a Git submodule. After cloning, initialize it with:

```bash
git submodule update --init --recursive
```

To add it from scratch (already wired in this repo):

```bash
git submodule add https://github.com/nullplatform/scope-testing.git testing
git submodule init && git submodule update
```

We use **three types of tests** to ensure quality at different levels:

| Test Type | What it Tests | Location | Command |
|-----------|---------------|----------|---------|
| **Unit Tests (BATS)** | `entrypoint`, `utils/`, and each provider's `setup`/`store`/`retrieve`/`delete` bash scripts | `parameters/tests/{utils,providers}/` | `make test-unit` |
| **Tofu Tests** | Provider install specs (Terraform/OpenTofu modules) | `parameters/providers/<provider>/specs/**/*.tftest.hcl` | `make test-tofu` |
| **Integration Tests** | Full workflow execution against mocked backends | `parameters/tests/integration/` | `make test-integration` |

> Unit tests are the active suite (187 tests). The Tofu and integration runners
> are wired through the submodule and ready to use as those suites are added.

### 1. Unit Tests (BATS)

Test bash scripts in isolation using mocked commands (`jq`, `aws`, `az`, `curl`,
`np`, ...). Tests mirror the source tree and source the shared assertions from
the `testing/` submodule.

**Location:** `parameters/tests/{utils,providers/<provider>}/<script>.bats`

**Run:** `make test-unit` (runs `bats -r parameters/tests`)

**Example files:**
- Util: [`parameters/tests/utils/build_context.bats`](parameters/tests/utils/build_context.bats)
- Util: [`parameters/tests/utils/prefetch_np.bats`](parameters/tests/utils/prefetch_np.bats)
- Provider: [`parameters/tests/providers/aws-secrets-manager/store.bats`](parameters/tests/providers/aws-secrets-manager/store.bats)

**Structure:**
```bash
#!/usr/bin/env bats

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$PROJECT_ROOT/testing/assertions.sh"
  # Mock external commands, set required env vars
}

@test "store: writes the secret and returns external_id" {
  run bash -c "source $PARAMETERS_DIR/providers/aws-secrets-manager/store"
  assert_equal "$status" "0"
  assert_contains "$output" '"external_id"'
}
```

### 2. Tofu Tests (OpenTofu/Terraform)

Test the provider install specs (the Terraform/OpenTofu modules operators run to
provision each backend) using `tofu test` with mock providers.

**Location:** `parameters/providers/<provider>/specs/**/*.tftest.hcl`

**Run:** `make test-tofu` or `make test-tofu MODULE=parameters`

### 3. Integration Tests (BATS)

Test complete workflows (store → retrieve → delete) end-to-end with mocked
external dependencies (LocalStack, Azure Mock, Smocker).

**Location:** `parameters/tests/integration/`

**Run:** `make test-integration` or `make test-integration VERBOSE=1`

### Running Tests

```bash
# Run all tests
make test-all

# Run specific test types
make test-unit              # BATS unit tests for bash scripts
make test-tofu              # OpenTofu module tests
make test-integration       # Full workflow integration tests

# Run with verbose output (integration only)
make test-integration VERBOSE=1
```

## Run locally as a package

`np package run` runs this package on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. No cluster,
no publish. The two tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `parameters-worker:dev` |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |

Prerequisites: **Docker** with host networking (Linux as is; on Docker Desktop
enable *host networking*), **[mise](https://mise.jdx.dev)** (`mise trust` once
here), an **`NP_API_KEY`** for the agent to register with, and `np` from the
**alpha** channel, which carries `np package run`:

```bash
curl -fsSL https://cli.nullplatform.com/install.sh | VERSION=alpha sh   # ~/.local/bin/np
np package run --help                                                   # must list --no-forward-env
```

```bash
export NP_API_KEY=...
eval "$(aws configure export-credentials --format env)"   # cloud credentials as variables
np package run --log-level DEBUG                          # Ctrl+C to stop
```

The agent is tagged `package:parameters` and `local:<your user>`. It receives an
action only when the service's notification channel selects those tags, so
point a channel at `local:<your user>` to route work to your machine.

> **Tags decide who gets the work.** Never start a local agent with tags a
> production channel selects: it would receive production actions.

`np package run` forwards your shell's environment to the agent container,
minus what describes your machine (`PATH`, `HOME`, `DOCKER_*`, `KUBECONFIG`,
`AWS_PROFILE` and the other file-pointing AWS variables), and the `run` task
passes the same variables to the worker through an `NP_WORKER_RULES` entry.
Every secret in your shell crosses too, and is readable with `docker inspect`;
pass `--no-forward-env` to forward nothing.

| Variable | Default | Purpose |
|---|---|---|
| `NP_API_KEY` | required | The key the agent registers with (`--api-key` also sets it) |
| `NP_LOG_LEVEL` | `INFO` | Agent log level (`--log-level` also sets it) |
| `NP_PACKAGE_SLUG` | `parameters` | The slug in the `package:<slug>` tag, when published under another slug |
| `NP_LOCAL_USER` | `$USER` | The value of the `local:<user>` tag |
| `NP_AGENT_IMAGE` | `controlplane-agent:latest` | The agent image; needs worker rules (0.11.1+) |

The local run never changes what the platform runs. To ship the change, merge
it: the release publishes the image and registers the artifact.

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| shellcheck | PR | every bash script |
| tests | PR | `tofu fmt`/`validate` of every provider spec and the BATS unit tests |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → GitHub release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/services/parameters:vX.Y.Z` | its release, once | pin an exact version |
| `agent-plugins/services/parameters:latest` | each release | follow the last released version |
| `beta/agent-plugins/services/parameters:test-<branch>-<short sha>` | each push to a pull request of this repository | deploy a change to a test scope before merging it |

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Pull requests from this repository can assume the beta role (fork and bot pull requests are skipped), and the tag carries the commit SHA, so two pull requests never overwrite each other by accident. Nothing deletes beta tags: they are ephemeral by convention. Each beta is also registered as its own nullplatform oci_image artifact (the `beta/` repository, under `NP_ARTIFACT_NRN`), separate from the release artifact, so it can be deployed to a test scope from the platform.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and push to the image's `beta/` repository in ECR Public, which the dispatcher creates together with the production one.
