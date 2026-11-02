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

The **dispatch is the worker** (`src/worker.ts`); the **backends are providers** under
`src/providers/`, one image each.

## Providers

| Provider | Backend |
|---|---|
| `aws-secrets-manager` | AWS Secrets Manager (`@aws-sdk/client-secrets-manager`) |
| `aws-parameter-store` | AWS SSM Parameter Store (`@aws-sdk/client-ssm`) |
| `azure-key-vault` | Azure Key Vault (`@azure/keyvault-secrets`, `@azure/identity`) |
| `gcp-secret-manager` | Google Cloud Secret Manager (`google-auth-library`, the REST API) |
| `hashicorp-vault` | HashiCorp Vault KV v2 (its HTTP API) |

## How it runs

Every backend ships in one worker image,
`public.ecr.aws/nullplatform/agent-plugins/services/parameters`: the providers' TypeScript, on
bun and `@nullplatform/plugin`, compiled to one binary with every backend's client (the AWS SDK,
the Azure SDK, Google's auth library; Vault over its HTTP API). `PARAMETERS_PROVIDER` in the
worker's environment names the backend it serves, set on the agent's worker pin. A `parameters`
notification channel, of type `package-exec`, makes the agent spawn that worker in its own pod
and hand it every `parameter:<action>` of the parameters bound to that provider. No bash, no `jq`, no CLI: an action is a call to the backend's API.

The channel comes from the `parameter_storage_definition_agent_association` module in
[tofu-modules](https://github.com/nullplatform/tofu-modules) with `worker_orchestrator = true`.

## Repository layout

```
.
├── Dockerfile               # the worker image, every provider in it
├── mise.toml                # run a provider locally as a package (np package run)
├── Makefile                 # test targets (see Testing)
├── testing/                 # scope-testing framework (git submodule)
├── docs/                    # architecture, configuration, adding a provider
├── src/
│   ├── main.ts              # the image's entry: the provider PARAMETERS_PROVIDER names
│   ├── worker.ts            # the four routes: parameter:store / retrieve / delete / notify
│   ├── context.ts           # the request a notification carries
│   ├── naming.ts            # the canonical path every backend's name is built from
│   ├── settings.ts          # provider attributes > environment > default
│   ├── failure.ts           # a failure in the bash's words: causes, fixes, the backend's answer
│   ├── aws/                 # the role to assume, its credentials kept until they expire
│   └── providers/           # index.ts (the provider per slug) and <slug>/index.ts (each provider)
├── test/                    # one suite per provider against a fake of its client
└── parameters/providers/<slug>/   # Tofu install specs and docs of each backend
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

| Test Type | What it Tests | Location | Command |
|-----------|---------------|----------|---------|
| **Worker tests (bun)** | the request, the canonical path, the settings chain, the role resolution and each provider against a fake of its client | `test/` | `make test-unit` (`bun test`) |
| **Tofu Tests** | Provider install specs (Terraform/OpenTofu modules) | `parameters/providers/<provider>/specs/**/*.tftest.hcl` | `make test-tofu` |
| **Integration Tests** | Full workflow execution against mocked backends | `parameters/tests/integration/` | `make test-integration` |

The worker's tests need no network, no cloud and no credentials: the AWS clients are faked at
the command level (what was sent, what is answered), Key Vault behind the SDK's client
interface, Secret Manager and Vault behind `fetch`. `bun install` once, then:

```bash
bun test
bunx tsc --noEmit -p .
```

The Tofu and integration runners are wired through the `testing/` submodule
(`git submodule update --init --recursive`).

## Run locally as a package

`np package run` runs the worker on your machine the way production does: a local
controlplane-agent that registers with the platform, spawns the worker image built from this
repo, and hands it every action routed to it. `PROVIDER` names the backend the worker serves
(`aws-secrets-manager` by default), passed to it as `PARAMETERS_PROVIDER`:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `parameters:dev` |
| `PROVIDER=hashicorp-vault np package run` | `mise run run` | Builds the image, then starts the local agent |

Prerequisites: **Docker** with host networking (Linux as is; on Docker Desktop enable *host
networking*), **[mise](https://mise.jdx.dev)** (`mise trust` once here), an **`NP_API_KEY`** for
the agent to register with, and `np` from the **alpha** channel, which carries `np package run`.

```bash
export NP_API_KEY=...
eval "$(aws configure export-credentials --format env)"   # cloud credentials as variables
PROVIDER=aws-secrets-manager np package run --log-level DEBUG   # Ctrl+C to stop
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
| `PROVIDER` | `aws-secrets-manager` | The backend the worker serves (its `PARAMETERS_PROVIDER`) |
| `NP_API_KEY` | required | The key the agent registers with (`--api-key` also sets it) |
| `NP_LOG_LEVEL` | `INFO` | Agent log level (`--log-level` also sets it) |
| `NP_PACKAGE_SLUG` | `parameters` | The slug in the `package:<slug>` tag, when published under another slug |
| `NP_LOCAL_USER` | `$USER` | The value of the `local:<user>` tag |
| `NP_AGENT_IMAGE` | `controlplane-agent:latest` | The agent image; needs worker rules (0.11.1+) |

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| shellcheck | PR | every bash script |
| tests | PR | `tofu fmt`/`validate` of every provider spec, and the worker's tests and type-check |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` of the image to ECR Public → nullplatform artifacts → GitHub release |
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
