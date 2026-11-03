# Adding a provider (the worker)

A backend is one folder under `src/providers/<slug>/`, one entry in the list of providers, one
test file and its install specs. Nothing else changes: the worker image carries every provider,
and each request names the one it goes to. New backends go to the worker only; the bash package
under `parameters/` is not extended (its own guide is
[parameters/docs/adding_a_provider.md](../parameters/docs/adding_a_provider.md)).

## The contract

The dispatch (`src/worker.ts`) knows no provider: it reads the request from the notification,
opens the session of the provider the request names and answers what the operation returns.

```ts
// src/provider.ts
export interface Provider {
  slug: string;                                                       // the provider specification's slug
  open(request: ParameterRequest, context: Context): Promise<Session>; // validate the configuration, authenticate (the bash's `setup`)
}

export interface Session {
  store(request): Promise<{ external_id: string; metadata: Record<string, unknown> }>;
  retrieve(request): Promise<{ value: string }>;
  retrieveBatch?(requests): Promise<{ values: Array<{ external_id: string; value: string }> }>; // optional; NOT_IMPLEMENTED otherwise
  delete(request): Promise<{ success: true }>;
  notify?(request): Promise<{ success: true }>;                      // optional; the default ack otherwise
}
```

### What a provider gets

`ParameterRequest` (`src/context.ts`): the parameter (`parameterId`, `name`, `value` on store,
`encoding`, `kind`: `secret` or `parameter`), `externalId` split into `path` and `version`, the
`provider` (`slug`, `specificationId`, `attributes`: the configuration registered in nullplatform,
sent with every notification), the `entities` with their slugs (`value_entities` for a scoped
value, else `entities`), `dimensions` and `valueDimensions`. `context` is the SDK's: `log`,
`api` (the platform), `signal`.

`canonicalPath(request)` (`src/naming.ts`) is the path every backend's name is built from:

```
organization=<slug>-<id>/account=<slug>-<id>/namespace=<slug>-<id>/application=<slug>-<id>[/scope=<slug>-<id>][/<dim>=<value>…]/<name>-<id>
```

`settingOf(attributes, env, { attribute, variable, fallback })` (`src/settings.ts`) resolves a
setting: the provider's attributes first, the environment second, the default last. Credentials
come from the environment only, never from the attributes.

### What a provider answers

- `store`: `external_id` is `<canonical path>#<version>` with the backend's own version
  identifier, verbatim (`handleOf`, `src/context.ts`); `metadata` whatever is useful for auditing.
- `retrieve`: `{ value }`; a missing secret is a failure with code `NOT_FOUND`, never a sentinel value.
- `retrieveBatch`: the values that could be read, each under the handle it was asked by; one
  left out is retrieved by the platform on its own. A backend with a batch read uses it in
  chunks (`chunks`, `src/provider.ts`) and reads what the batch refused one by one; a backend
  without one answers `retrieveEach(this, requests, this.context.log)`, or leaves the method out.
  A client with no route at all (the bash package, an older image) fails the command, and the
  platform retrieves one by one, as after any failed batch: nothing breaks on an old client.
- `delete`: `{ success: true }`, also when the secret is already gone; any other error fails.
- A failure is a `Failure` (`src/failure.ts`): a code, what went wrong, the likely causes, how to
  fix it and what the backend said, in the words the bash printed.

## Principles every provider honors

1. **Naming is human-friendly and hierarchical.** Build the backend's name from
   `canonicalPath(request)`, reshaped to the backend's charset, under a `nullplatform` prefix.
   The handle returned to nullplatform is the canonical form.
2. **Versioning is the backend's.** Each store is a new version of the same secret (never a new
   top-level entity per version); the handle is `<path>#<version id>` with the backend's native
   identifier, verbatim. Retrieve reads the version the handle names; delete removes every version.
3. **Failures are in plain words.** Throw a `Failure(code, { what, causes, fixes, underlying })`.
   A missing secret on retrieve is `NOT_FOUND`; a missing secret on delete is success; any other
   error fails.
4. **Credentials from the environment only.** Settings come through `settingOf`, credentials
   never through the provider's attributes.
5. **The client is injectable.** The factory takes `{ clients?, env? }` so the tests hand a fake
   of the backend's client (or of `fetch`) and the worker runs with no network.
6. **What comes from outside is read without trusting its shape.** A backend's JSON body goes
   through `src/json.ts` (`parsedObject`, `valueAt`, `text`), never through `any`.

## Steps

1. **`src/providers/<slug>/index.ts`**: export `SLUG` and a factory `<name>(options?)` returning a
   `Provider`: `open(request, context)` validates the settings and authenticates once, returning
   a `Session`. Keep the file in the order the others follow: the header comment (what one secret
   is in the backend, how it is versioned, how the worker authenticates), imports, constants, the
   clients and options interfaces, the naming helpers, the session class, the auth helpers, the
   factory.
2. **`src/providers/index.ts`**: add the factory to `allProviders`, so the worker serves the
   requests that name `<slug>`.
3. **`test/<slug>.test.ts`**: with the helpers in `test/support.ts`, cover the settings' errors,
   store on a new and an existing secret (the handle's version), retrieve at a version, retrieve
   not found, delete, delete of a missing secret, a refused backend call, and the batch read
   when the backend has one. `bun run check` must pass: type-check, lint, format, tests.
4. **Install specs and docs** under `parameters/providers/<slug>/`: `specs/install` with the
   `parameters-storage` configuration template (its `slug` is `<slug>`), `specs/requirements`,
   and `docs/architecture.md` (storage layout, versioning, the version id's format) plus an IAM or
   RBAC note where the backend has one.
5. **Wire it up**: register the `parameters-storage` provider specification in nullplatform; the
   worker serves it once the image that carries it is deployed.
