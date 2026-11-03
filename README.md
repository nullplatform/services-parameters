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

The package ships as two worker images built from this repository, the same
actions and the same backends in each:

| Runtime | Code | Image |
|---|---|---|
| **The worker**: TypeScript on bun and `@nullplatform/plugin` | `src/` | `agent-plugins/services/parameters:<version>`, `latest`, and `beta/…:test-<branch>-<sha>` from pull requests |
| **The bash package**: scripts on the `worker-bridge` | `parameters/` | `agent-plugins/services/parameters:<version>-bash` |

The worker is the runtime going forward: an action is one call to the backend's
API through its SDK, and `parameter:retrieve_batch` reads many values in one
call. The bash package is what ran before; it stays published for whoever pins
it and is not extended.

## Providers

| Provider | Backend | Worker client | Bash tool |
|---|---|---|---|
| `aws-secrets-manager` | AWS Secrets Manager | `@aws-sdk/client-secrets-manager` | `aws` CLI |
| `aws-parameter-store` | AWS SSM Parameter Store | `@aws-sdk/client-ssm` | `aws` CLI |
| `azure-key-vault` | Azure Key Vault | `@azure/keyvault-secrets`, `@azure/identity` | REST API, `curl` |
| `gcp-secret-manager` | Google Cloud Secret Manager | `google-auth-library`, the REST API | REST API, `curl` |
| `hashicorp-vault` | HashiCorp Vault KV v2 | its HTTP API | its HTTP API, `curl` |

## How it runs

A `parameters` notification channel of type `package-exec` makes the agent spawn
the package's worker image in its own pod and hand it every `parameter:<action>`
of the parameters bound to any of these providers. Each notification names its
provider in `provider.specification_slug` and carries that provider's
configuration in `provider.attributes`; the worker opens that provider and
answers what the operation returns. The channel comes from the
`parameter_storage_definition_agent_association` module in
[tofu-modules](https://github.com/nullplatform/tofu-modules) with
`worker_orchestrator = true`.

Which image the agent spawns is its worker pin for the package `parameters`:
the worker image, or the `-bash` tag of the same version. Both answer the same
actions with the same results and store under the same names, and the handle
nullplatform keeps (`external_id`) is the same canonical form, so an
installation can move from one to the other.

## Repository layout

```
.
├── Dockerfile               # the worker image: src/ compiled to one binary on alpine
├── src/                     # the worker
│   ├── main.ts              # the image's entry: the worker with every provider
│   ├── worker.ts            # the routes: parameter:store / retrieve / delete / notify / retrieve_batch
│   ├── context.ts           # the request a notification carries
│   ├── naming.ts            # the canonical path every backend's name is built from
│   ├── settings.ts          # provider attributes > environment > default
│   ├── failure.ts           # a failure in the bash's words: causes, fixes, the backend's answer
│   ├── json.ts              # reading a notification or a backend's answer without trusting its shape
│   ├── platform/            # the platform's provider of a category over an NRN, as the CLI resolves it
│   ├── aws/                 # the role to assume, its credentials kept until they expire
│   └── providers/           # index.ts (every provider) and <slug>/index.ts (each one)
├── test/                    # one suite per provider against a fake of its client
├── docs/                    # the worker: architecture, configuration, adding a provider
├── parameters/              # the bash package
│   ├── Dockerfile           # its image: worker-bridge + aws-cli + these scripts
│   ├── entrypoint           # action router (parameter:<action> → workflow)
│   ├── workflows/           # store / retrieve / delete / notify
│   ├── utils/               # build_context, dispatch, assume_role*, build_external_id, ...
│   ├── providers/<slug>/    # the backend's scripts, and the Tofu install specs & docs both runtimes share
│   ├── tests/               # BATS unit tests (mirror the source tree)
│   └── docs/                # the bash package: architecture, configuration, adding a provider
├── mise.toml                # run locally as a package (np package run)
├── Makefile                 # test targets (see Testing)
└── testing/                 # scope-testing framework (git submodule)
```

## Documentation

The worker:

- [Architecture](docs/architecture.md) — one image, the request flow, naming and versioning, the AWS identity
- [Configuration](docs/configuration.md) — what the notification carries, where each setting comes from, per-provider variables
- [Adding a provider](docs/adding_a_provider.md) — the `Provider` and `Session` contract and the steps to plug in a backend

The bash package:

- [Architecture](parameters/docs/architecture.md), [Configuration](parameters/docs/configuration.md), [Adding a provider](parameters/docs/adding_a_provider.md)
- [Provider contract](parameters/providers/README.md) — the `setup`/`store`/`retrieve`/`delete` scripts every provider implements

### Per-provider docs

The install specs and the docs under each provider's directory serve both runtimes.

| Provider | Architecture | IAM policy |
|---|---|---|
| AWS Secrets Manager | [architecture](parameters/providers/aws-secrets-manager/docs/architecture.md) | [iam-policy](parameters/providers/aws-secrets-manager/docs/iam-policy.md) |
| AWS Parameter Store | [architecture](parameters/providers/aws-parameter-store/docs/architecture.md) | [iam-policy](parameters/providers/aws-parameter-store/docs/iam-policy.md) |
| Azure Key Vault | [architecture](parameters/providers/azure-key-vault/docs/architecture.md) | — |
| GCP Secret Manager | [architecture](parameters/providers/gcp-secret-manager/docs/architecture.md) | [iam-policy](parameters/providers/gcp-secret-manager/docs/iam-policy.md) |
| HashiCorp Vault | [architecture](parameters/providers/hashicorp-vault/docs/architecture.md) | — |

## Testing

| Test Type | What it Tests | Location | Command |
|-----------|---------------|----------|---------|
| **Worker (bun)** | type-check, lint, format check, and the request, the canonical path, the settings chain, the role resolution and each provider against a fake of its client | `test/` | `make test-worker` (`bun run check`) |
| **Bash package (BATS)** | `entrypoint`, `utils/`, and each provider's `setup`/`store`/`retrieve`/`delete` scripts against mocked commands | `parameters/tests/{utils,providers}/` | `make test-bash` (`bats -r parameters/tests`) |
| **Tofu Tests** | Provider install specs (Terraform/OpenTofu modules) | `parameters/providers/<provider>/specs/**/*.tftest.hcl` | `make test-tofu` |
| **Integration Tests** | Full workflow execution against mocked backends | `parameters/tests/integration/` | `make test-integration` |

`make test-unit` runs the first two; `make test-all` everything.

The worker's tests need no network, no cloud and no credentials: the AWS
clients are faked at the command level (what was sent, what is answered), Key
Vault behind the SDK's client interface, Secret Manager and Vault behind
`fetch`. `bun install` once, then `bun run check`, or each gate on its own:

```bash
bun run typecheck
bun run lint
bun run format:check    # bun run format rewrites
bun test
```

The BATS tests source the shared assertions from the `testing/` submodule, and
the Tofu and integration runners are wired through it:

```bash
git submodule update --init --recursive
```

## Run locally as a package

`np package run` runs the package on your machine the way production does: a local
controlplane-agent that registers with the platform, spawns the worker image built from this
repository, and hands it every action routed to it, whatever backend each one names:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `parameters:dev`, the worker |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |
| `mise run build:bash-image` | | Builds `parameters-bash:dev`, the bash package, to run with `NP_WORKER_IMAGE=parameters-bash:dev` |

Prerequisites: **Docker** with host networking (Linux as is; on Docker Desktop enable *host
networking*), **[mise](https://mise.jdx.dev)** (`mise trust` once here), an **`NP_API_KEY`** for
the agent to register with, and `np` from the **alpha** channel, which carries `np package run`.

```bash
export NP_API_KEY=...
eval "$(aws configure export-credentials --format env)"   # cloud credentials as variables
np package run --log-level DEBUG   # Ctrl+C to stop
```

The agent is tagged `package:parameters` and `local:<your user>`. It receives an
action only when the service's notification channel selects those tags, so point a channel at
`local:<your user>` to route work to your machine.

> **Tags decide who gets the work.** Never start a local agent with tags a
> production channel selects: it would receive production actions.

`np package run` forwards your shell's environment to the agent container, minus what describes
your machine, and the `run` task passes the same variables to the worker through an
`NP_WORKER_RULES` entry. Every secret in your shell crosses too; pass `--no-forward-env` to
forward nothing.

| Variable | Default | Purpose |
|---|---|---|
| `NP_API_KEY` | required | The key the agent registers with (`--api-key` also sets it) |
| `NP_LOG_LEVEL` | `INFO` | Agent log level (`--log-level` also sets it) |
| `NP_WORKER_IMAGE` | `parameters:dev` | The image the agent spawns; `parameters-bash:dev` for the bash package |
| `NP_PACKAGE_SLUG` | `parameters` | The slug in the `package:<slug>` tag, when published under another slug |
| `NP_LOCAL_USER` | `$USER` | The value of the `local:<user>` tag |
| `NP_AGENT_IMAGE` | `controlplane-agent:latest` | The agent image; needs worker rules (0.11.1+) |

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| shellcheck | PR | every bash script |
| tests | PR | `tofu fmt`/`validate` of every provider spec; the worker's type-check, lint, format check and tests; the bash package's BATS tests and image build |
| trivy | PR | IaC misconfiguration scan, and both images scanned, to the Security tab |
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes the worker as `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` of the worker to ECR Public → nullplatform artifact → GitHub release; then `vX.Y.Z-bash`, the bash package's image, noted on the release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image (both Dockerfiles) and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/services/parameters:vX.Y.Z` | its release, once | pin an exact version of the worker |
| `agent-plugins/services/parameters:latest` | each release | follow the last released worker |
| `agent-plugins/services/parameters:vX.Y.Z-bash` | its release, once | pin the bash package at that version |
| `beta/agent-plugins/services/parameters:test-<branch>-<short sha>` | each push to a pull request of this repository | deploy a worker change to a test scope before merging it |

The bash image is one more tag of the release's repository, built from the same
commit: it has no `latest` and is not registered as an artifact, so the
artifact's newest revision is always the worker's. Pin it by tag or digest in
the agent's worker pin.

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Pull requests from this repository can assume the beta role (fork and bot pull requests are skipped), and the tag carries the commit SHA, so two pull requests never overwrite each other by accident. Nothing deletes beta tags: they are ephemeral by convention. Each beta is also registered as its own nullplatform oci_image artifact (the `beta/` repository, under `NP_ARTIFACT_NRN`), separate from the release artifact, so it can be deployed to a test scope from the platform.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and push to the image's `beta/` repository in ECR Public, which the dispatcher creates together with the production one.
