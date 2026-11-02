# Adding a provider

A backend is one folder under `src/providers/<slug>/` and one image. Nothing outside it changes
but the CI matrices and the install specs.

## Principles every provider honors

1. **Naming is human-friendly and hierarchical.** Build the backend's name from
   `canonicalPath(request)` (`src/naming.ts`), reshaped to the backend's charset, under a
   `nullplatform` prefix. The handle returned to nullplatform is the canonical form.
2. **Versioning is the backend's.** Each store is a new version of the same secret (never a new
   top-level entity per version); the handle is `<path>#<version id>` with the backend's native
   identifier, verbatim. Retrieve reads the version the handle names; delete removes every version.
3. **Failures are in plain words.** Throw a `Failure(code, { what, causes, fixes, underlying })`
   (`src/failure.ts`). A missing secret on retrieve is `NOT_FOUND`, never a sentinel value. A
   missing secret on delete is success; any other error fails.
4. **Credentials from the environment only.** Settings come through `settingOf`
   (`src/settings.ts`), credentials never through the provider's attributes.
5. **The client is injectable.** The factory takes `{ clients?, env? }` so the tests hand a fake
   of the backend's client (or of `fetch`) and the worker runs with no network.

## Steps

1. **`src/providers/<slug>/index.ts`**: export `SLUG` and a factory returning a `Provider`
   (`src/provider.ts`): `open(request, context)` validates the settings and authenticates once,
   returning a `Session` with `store`, `retrieve`, `delete` and, when the backend has something
   to do on it, `notify`.
2. **`src/providers/index.ts`**: add `[SLUG]: () => <factory>()` to `PROVIDERS`, so `PARAMETERS_PROVIDER=<slug>` selects it.
3. **`test/<slug>.test.ts`**: with the helpers in `test/support.ts`, cover the settings' errors,
   store on a new and an existing secret (the handle's version), retrieve at a version, retrieve
   not found, delete, delete of a missing secret, and a refused backend call.
4. **Install specs and docs** under `parameters/providers/<slug>/`: `specs/install` with the
   `parameters-storage` configuration template (its `slug` is `<slug>`), `specs/requirements`,
   and `docs/architecture.md` (storage layout, versioning, the version id's format) plus an IAM or
   RBAC note where the backend has one.
5. **Wire it up**: register the `parameters-storage` provider specification in nullplatform and
   pin the package `parameters` with `PARAMETERS_PROVIDER=<slug>` in the worker's `env`.
