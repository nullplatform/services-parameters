# Changelog

Releases of this repository are cut by release-please and listed above this
point. Everything below is the history of
[nullplatform/parameters-provider](https://github.com/nullplatform/parameters-provider),
where this package lived until it moved here to ship as a worker image.

## parameters-provider, unreleased at the move

### Added

- Add support to manage (store, retrieve and delete) parameters from GCP Secret Manager, through the Secret Manager REST API with `curl` (no gcloud CLI to install at runtime) and native secret versions.
- Authenticate to GCP Secret Manager with the agent pod's GKE Workload Identity via the metadata server, so no key or secret is handed to the agent; `GCP_ACCESS_TOKEN` overrides it for runs outside GCP.
- Add the GCP Secret Manager install tofu module (`specs/install/`) built on the shared parameter-storage modules, plus a `specs/requirements/` module that grants the agent's Kubernetes service account (Workload Identity Federation principal) or extra members a least-privilege custom role (only the permissions the provider uses; a predefined role is optional) under an IAM condition scoped to the provider's secret name prefix.
- Support user-managed replication for GCP Secret Manager secrets (`replica_locations`) for data-residency requirements.
- Label GCP Secret Manager secrets with the parameter's NRN (`organization_id`/`organization`, `account_id`/`account`, `namespace_id`/`namespace`, `application_id`/`application` and, on scope-level values, `scope_id`/`scope`), following the platform tags of the nullplatform services, for filtering and cost reports.

### Fixed

- Fix the AWS provider deprecation warning when creating the AWS Parameter Store and Secrets Manager IAM requirements.
- Fix the architecture and configuration docs that described the Azure Key Vault provider as using the Azure CLI; it calls the Key Vault REST API with `curl`.

## [0.3.0] - 2026-07-27
### Added

- Add support to manage (store, retrieve and delete) parameters from Azure Key Vault.
- Add the Azure Key Vault install tofu module (`specs/install/`) built on the shared parameter-storage modules, plus a `specs/requirements/` module that assigns the Key Vault Secrets Officer RBAC role to an existing Azure AD service principal (bring-your-own; the client secret is never handled by tofu) and can optionally create the Key Vault itself (`key_vault.enable`, an independent toggle) with the RBAC authorization model and hardened defaults.
- Azure Key Vault store/retrieve/delete operate on secrets through the Key Vault REST API with `curl` (no Azure CLI to install at runtime), authenticating the service principal via an OAuth2 client-credentials token from `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID`.

### Fixed

- Fix HashiCorp Vault parameters not being retrievable after being stored on a Vault Enterprise namespace.
- Report a clear error when storing a parameter in HashiCorp Vault fails, instead of silently reporting success.

### Changed

- Configure the HashiCorp Vault namespace and KV path prefix as separate fields.

## [0.2.0] - 2026-07-14
### Added

- Add support to manage (store, retrieve and delete) parameters from HashiCorp Vault.

### Changed

- Read entity slugs from the notification payload and remove the remote calls to the nullplatform API.
- Refactor the AWS Parameter Store and Secrets Manager installation to build on reusable Terraform modules (`parameter_storage_definition`, `parameter_storage_configuration`, and the agent-association module) instead of a bundled local module, adding per-instance provider configuration and opt-in agent notification channels.

## [0.1.0] - 2026-07-03

### Added

- Add support to manage (store and retrieve) parameters from AWS Secret Manager and AWS Parameter store.
