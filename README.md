# my-service

Template for new nullplatform `services-*` repositories: the CI every service repo needs and the minimal structure the agent runs. Everything specific to your service is yours to add.

## Start here

1. Replace `my-service` everywhere with your service slug (directory, `Dockerfile`, `mise.toml`, specs, `.github/workflows/*`):
   ```bash
   git mv my-service <slug>
   grep -rl my-service . --exclude-dir=.git | xargs perl -pi -e 's/my-service/<slug>/g'
   ```
   Then set the display name (`"name": "My Service"`) in `<slug>/specs/service-spec.json.tpl`, and its `selectors`
   (`category`, `sub_category`, `provider`) there and in `<slug>/specs/links/*.json.tpl` — the template's `Other` / `Other` / `AWS`
   is what the nullplatform catalog and the docs [Sample services](https://docs.nullplatform.com/docs/services/sample-services) page show.
   Keep the repository named `services-<slug>`: the docs catalog finds sample repositories by that prefix once they
   have a release. A one-line GitHub description is welcome (`gh repo edit nullplatform/<repo> --description "..."`).
   The release refuses to run while any template placeholder is left.
2. Add the **Public ECR** service to the application in nullplatform. It creates the ECR Public repository and the publisher role; then set the secret and variable in [Publishing](#publishing).
3. Write your steps in `<slug>/scripts/` and wire them in `<slug>/workflows/*.yaml`; define attributes in `<slug>/specs/`.
4. Merge to `main` with a `feat:` or `fix:` commit: release-please opens the release PR, and merging it publishes the image.

## Layout

```
my-service/
  entrypoint/   entrypoint (agent calls it), service and link (route an action to its workflow)
  workflows/    one YAML per action: create, update, delete, link, link-update, unlink
  scripts/      the steps the workflows run (example is a placeholder)
  specs/        service-spec.json.tpl and links/connect.json.tpl
  values.yaml   static configuration for the workflows
Dockerfile      worker image on the shared worker-bridge base
mise.toml       run it on your machine as a package (`np package run`)
```

A custom action slug `foo` runs `workflows/foo.yaml`.

## Run locally as a package

`np package run` runs this service on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. No cluster,
no publish. The two tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `my-service-worker:dev` |
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

The agent is tagged `package:my-service` and `local:<your user>`. It receives an
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
| `NP_PACKAGE_SLUG` | `my-service` | The slug in the `package:<slug>` tag, when published under another slug |
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
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → GitHub release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/services/<name>:vX.Y.Z` | its release, once | pin an exact version |
| `agent-plugins/services/<name>:latest` | each release | follow the last released version |
| `beta/agent-plugins/services/<name>:test-<branch>-<short sha>` | each push to a pull request of this repository | deploy a change to a test scope before merging it |

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Pull requests from this repository can assume the beta role (fork and bot pull requests are skipped), and the tag carries the commit SHA, so two pull requests never overwrite each other by accident. Nothing deletes beta tags: they are ephemeral by convention. Each beta is also registered as its own nullplatform oci_image artifact (the `beta/` repository, under `NP_ARTIFACT_NRN`), separate from the release artifact, so it can be deployed to a test scope from the platform.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and push to the image's `beta/` repository in ECR Public, which the dispatcher creates together with the production one. In this template repository neither workflow runs.
