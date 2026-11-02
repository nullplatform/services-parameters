# Parameters — Architecture

A pluggable parameter and secret storage layer for nullplatform. The platform chooses the
provider for each parameter (`provider.specification_slug` in the notification) and sends that
provider's configuration along (`provider.attributes`), so a worker needs no configuration of
its own beyond the credentials in its environment.

## One worker per backend

Each backend is a provider under `src/providers/<slug>/` and ships as its own image,
`agent-plugins/services/parameters-<slug>`, built from the one `Dockerfile` with
`--build-arg PROVIDER=<slug>`: the provider's TypeScript compiled by bun into one binary with that
backend's client alone. The agent spawns the image named by the worker pin for the package
`parameters-<slug>` and dials it over gRPC; the `parameters` channel of that provider routes it
the `parameter:<action>` notifications of the parameters bound to it.

```
nullplatform ── parameter:<action> notification ──▶ agent ──▶ worker image of the provider
                                                               │
                                                               ▼
                       src/worker.ts   one raw route per action; reads the request (src/context.ts);
                                       refuses a parameter bound to another backend; opens the
                                       provider's session; answers what the operation returns
                                                               │
                                                               ▼
                       src/providers/<slug>/index.ts   open(): the configuration (src/settings.ts:
                                                       attributes, then environment, then default)
                                                       and the credentials; store / retrieve /
                                                       delete / notify against the backend's API
```

A failure (`src/failure.ts`) is the action's failure with a code and a message in the words the
bash printed: what went wrong, the likely causes, how to fix it, what the backend answered.

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
nullplatform keeps (`external_id`) is the canonical form, so a parameter can move between
backends.

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
`parameter_store`) at the parameter's NRN and dimensions, else a default variable. An assumed
role's credentials are kept in memory until a minute before they expire (`src/aws/role.ts`), one
STS call an hour instead of one per action.

## File tree

```
src/
├── worker.ts            the four routes and the dispatch
├── context.ts           ParameterRequest: what a notification carries
├── naming.ts            canonicalPath and the pieces each backend reshapes
├── settings.ts          settingOf: attributes > environment > default
├── failure.ts           Failure: a code and the bash's troubleshooting words
├── config.ts            what an image is to the agent (package name, version, sources)
├── aws/                 role resolution, assumed credentials, the SDK clients
├── samples/             one notification per action, the manifest's runs and the tests' start
└── providers/<slug>/    index.ts (the provider), main.ts (the image's entry)
test/                    one suite per module; each provider against a fake of its client
parameters/providers/<slug>/   Tofu install specs and docs of each backend
```
