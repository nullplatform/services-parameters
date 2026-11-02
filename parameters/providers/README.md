# Provider contract

A provider is one folder under `src/providers/`, with its install specs and docs here under
`parameters/providers/<slug>/`. The dispatch (`src/worker.ts`) knows no provider: it reads the
request from the notification, checks the parameter is bound to this worker's backend, opens
the provider's session and answers what the operation returns.

```ts
export interface Provider {
  slug: string;                                                 // the provider specification's slug
  open(request: ParameterRequest, context: Context): Promise<Session>;   // validate the configuration, authenticate (the bash's `setup`)
}

export interface Session {
  store(request): Promise<{ external_id: string; metadata: Record<string, unknown> }>;
  retrieve(request): Promise<{ value: string }>;
  delete(request): Promise<{ success: true }>;
  notify?(request): Promise<{ success: true }>;                // optional; the default ack otherwise
}
```

## What a provider gets

`ParameterRequest` (`src/context.ts`): the parameter (`parameterId`, `name`, `value` on store,
`encoding`, `kind`: `secret` or `parameter`), `externalId` split into `path` and `version`, the
`provider` (`slug`, `specificationId`, `attributes`: the configuration registered in nullplatform,
sent with every notification), the `entities` with their slugs (`value_entities` for a scoped
value, else `entities`), `dimensions` and `valueDimensions`.

`canonicalPath(request)` (`src/naming.ts`) is the path every backend's name is built from:

```
organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim>=<value>…]/<name>-<id>
```

`settingOf(attributes, env, { attribute, variable, fallback })` (`src/settings.ts`) resolves a
setting: the provider's attributes first, the environment second, the default last. Credentials
come from the environment only, never from the attributes.

## What a provider answers

- `store`: `external_id` is `<canonical path>#<version>` with the backend's own version
  identifier, verbatim; `metadata` whatever is useful for auditing.
- `retrieve`: `{ value }`; a missing secret is a failure with code `NOT_FOUND`, never a sentinel value.
- `delete`: `{ success: true }`, also when the secret is already gone; any other error fails.
- A failure is a `Failure` (`src/failure.ts`): a code, what went wrong, the likely causes, how to
  fix it and what the backend said, in the words the bash printed.

## Adding one

1. `src/providers/<slug>/index.ts` exporting `SLUG` and a factory `<name>(options?)` that takes
   the backend's client (or a fake) and the environment, added to `PROVIDERS` in
   `src/providers/index.ts`.
2. `test/<slug>.test.ts` against a fake of the client: configuration errors, store with and without
   an existing secret, retrieve at a version and not found, delete and its idempotency.
3. `parameters/providers/<slug>/specs/` (the install specs with the configuration template, slug =
   `<slug>`) and `docs/`.
4. Nothing in CI: the one image carries every provider, and each request names
   the one it goes to.
