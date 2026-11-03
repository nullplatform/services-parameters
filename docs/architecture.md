# Parameters — Architecture (the worker)

A pluggable parameter and secret storage layer for nullplatform. The platform chooses the
provider for each parameter (`provider.specification_slug` in the notification) and sends that
provider's configuration along (`provider.attributes`), so a worker needs no configuration of
its own beyond the credentials in its environment.

This is the TypeScript worker under `src/`. The bash package under `parameters/` is the same
package as scripts, run by the agents still on the legacy `exec` channel; its own architecture is
[parameters/docs/architecture.md](../parameters/docs/architecture.md).

## One worker image, every backend in one worker

Each backend is a provider under `src/providers/<slug>/`, and every provider ships in one image,
`agent-plugins/services/parameters`: the providers' TypeScript compiled by bun into one binary.
One worker serves them all: each request names its backend in `provider.specification_slug`,
and the worker opens that provider (`src/providers/index.ts`, `src/worker.ts`); a slug the image
does not carry is refused with `UNKNOWN_PROVIDER`. The agent spawns the image named by the worker
pin for the package `parameters` and dials it over gRPC; the `parameters` channel routes it the
`parameter:<action>` notifications of the parameters bound to any of those backends.

```
nullplatform ── parameter:<action> notification ──▶ agent ──▶ the worker's pod
                                                               │
                                                               ▼
                       src/worker.ts   one raw route per action; reads the request (src/context.ts);
                                       refuses a parameter bound to a backend the image lacks; opens
                                       the provider's session; answers what the operation returns
                                                               │
                                                               ▼
                       src/providers/<slug>/index.ts   open(): the configuration (src/settings.ts:
                                                       attributes, then environment, then default)
                                                       and the credentials; store / retrieve /
                                                       retrieveBatch / delete / notify against the
                                                       backend's API
```

A failure (`src/failure.ts`) is the action's failure with a code and a message in the words the
bash printed: what went wrong, the likely causes, how to fix it, what the backend answered.

### The batch read

`parameter:retrieve_batch` carries the shared metadata of one provider and entities with up to
50 `values`, each with its `external_id`. Secrets Manager answers it 20 secrets per
`BatchGetSecretValue` and Parameter Store 10 per `GetParameters`; Key Vault, Secret Manager and
Vault have no batch read and answer the values read in parallel, ten at a time
(`retrieveEach`, `src/provider.ts`). A value a batch could not read is read on its own; one that
still fails is left out, and the platform retrieves it with a single `parameter:retrieve`.

A client without the route fails the whole command, and the platform then retrieves every value
one by one, as it does after any failed batch: the bash package has no `retrieve_batch` workflow
and exits on it, an older worker image refuses it as `UNKNOWN` action. So the API can send batches
to every client; one without the route pays one failed round trip per batch and loses nothing.

## Storage naming: human-friendliness principle

Every provider composes its name from the parameter's NRN entities (slug and id), its
dimensions and its name and id, so an operator in the backend's own console finds any secret
knowing the parameter's context. `canonicalPath` (`src/naming.ts`) is the shared form:

```
organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim_key>=<dim_value>…]/<parameter_name>-<parameter_id>
```

The required entities come first in NRN order, `scope` only when the value is bound to one,
the dimensions sorted by key. Each backend applies its prefix and charset: Secrets Manager
`nullplatform/` + the path; Parameter Store `/nullplatform/` + the path with `=` as `_`; Secret
Manager `<prefix>__` + the path with `/` as `__` and `=` as `-`; Vault `<path prefix>/` + the
path, the prefix embedded in the handle; Key Vault a slug-free, dash-joined name from the
application, the scope, the dimensions and the parameter, to fit 127 characters. The handle
nullplatform keeps (`external_id`) is the canonical form, the same the bash package wrote, so a
parameter can move between backends and an installation from the bash package to the worker.

### Version in the handle

`external_id` is `<path>#<version_id>`, the version identifier the backend returned, verbatim:
a UUID from Secrets Manager, an integer from Parameter Store, Vault and Secret Manager, a hex
string from Key Vault. nullplatform sends the handle back on every operation; retrieve reads
that version through the backend's own mechanism, delete ignores the suffix and removes every
version.

## AWS identity

The AWS providers run as the agent (the pod's IRSA) unless a role is named: an override
variable (`SECRET_MANAGER_ASSUME_ROLE_ARN`, `PARAMETER_STORE_ASSUME_ROLE_ARN`), else the role the
platform's `identity-access-control` provider names for the selector (`secret_manager`,
`parameter_store`) at the parameter's NRN and dimensions, else a default variable. That provider
is resolved as the CLI's `np provider list --categories` resolves one (`src/platform/providers.ts`:
the category's specifications, the providers visible from the NRN with its ascendants, the best
fit by NRN length and dimensions) and remembered for a minute. An assumed role's credentials are
kept in memory until a minute before they expire (`src/aws/role.ts`), one STS call an hour
instead of one per action.

## File tree

```
src/
├── main.ts              the image's entry: the worker with every provider
├── worker.ts            the routes and the dispatch
├── context.ts           ParameterRequest: what a notification carries
├── naming.ts            canonicalPath and the pieces each backend reshapes
├── settings.ts          settingOf: attributes > environment > default
├── failure.ts           Failure: a code and the bash's troubleshooting words
├── json.ts              a notification's or a backend's JSON read without trusting its shape
├── config.ts            what an image is to the agent (package name, version, sources)
├── platform/            the platform's provider of a category over an NRN
├── aws/                 the SDK's clients, role resolution, assumed credentials
├── samples/             one notification per action, the manifest's runs and the tests' start
└── providers/           index.ts (every provider), <slug>/index.ts (each provider)
test/                    one suite per module; each provider against a fake of its client
parameters/providers/<slug>/   the bash scripts, and the Tofu install specs and docs of each backend
```
