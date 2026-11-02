/**
 * Azure Key Vault. One secret per parameter, named from the application, the
 * scope, the dimensions and the parameter (`application-<id>-scope-<id>-<dim>-
 * <value>-<name>-<id>`, Key Vault's own charset, at most 127 characters; the
 * slugs are left out to fit), each store a new version of it. The handle is
 * that name with the version Key Vault returns; delete soft-deletes and then
 * purges, best effort, so the name is free again.
 */

import { ClientSecretCredential, type TokenCredential } from "@azure/identity";
import { SecretClient } from "@azure/keyvault-secrets";
import type { Context } from "@nullplatform/plugin";
import { handleOf, type ParameterRequest } from "../../context";
import { Failure, messageOf } from "../../failure";
import { dimensionSegments, parameterSegment } from "../../naming";
import { DONE, retrieveEach, type Provider, type RetrievedBatch, type Session } from "../../provider";
import { settingOf } from "../../settings";

export const SLUG = "azure-key-vault";
export const NAME_MAX_LENGTH = 127;

/** What the provider needs of a Key Vault client; the SDK's `SecretClient` is one. */
export interface SecretsLike {
  setSecret(name: string, value: string, options: { tags: Record<string, string> }): Promise<{ properties: { id?: string; version?: string } }>;
  getSecret(name: string, options?: { version?: string }): Promise<{ value?: string }>;
  beginDeleteSecret(name: string): Promise<{ pollUntilDone(): Promise<unknown> }>;
  purgeDeletedSecret(name: string): Promise<void>;
}

export interface KeyVaultClients {
  credential: (tenantId: string, clientId: string, clientSecret: string) => TokenCredential;
  secrets: (vaultUrl: string, credential: TokenCredential) => SecretsLike;
}

export interface KeyVaultOptions {
  clients?: KeyVaultClients;
  env?: Record<string, string | undefined>;
}

const sanitize = (value: string): string => value.replace(/[^A-Za-z0-9-]/g, "-");

/** The secret's name: the application, the scope when the value is scoped, the dimensions as `key-value`, then `<name>-<id>`, dash-joined. */
export function secretNameOf(request: ParameterRequest): string {
  const entities = ["application", "scope"].filter((entity) => request.entities[entity]).map((entity) => `${entity}-${sanitize(request.entities[entity])}`);
  const dimensions = dimensionSegments(request.dimensions).map((segment) => sanitize(segment.replace("=", "-")));
  return [...entities, ...dimensions, ...parameterSegment(request, sanitize)].join("-");
}

const statusOf = (error: unknown): number | undefined => (error && typeof error === "object" && "statusCode" in error ? Number((error as { statusCode: unknown }).statusCode) : undefined);

class KeyVaultSession implements Session {
  constructor(
    private readonly secrets: SecretsLike,
    private readonly vaultName: string,
    private readonly vaultUrl: string,
    private readonly context: Context,
  ) {}

  async store(request: ParameterRequest) {
    const name = secretNameOf(request);
    if (name.length > NAME_MAX_LENGTH) {
      throw new Failure("NAME_TOO_LONG", { what: `Secret name exceeds Azure Key Vault's ${NAME_MAX_LENGTH}-character limit (got ${name.length})`, causes: [`The name is the entity path (NRN ids + dimensions + parameter): ${name}`], fixes: ["Shorten the parameter name, or reduce the number of dimensions", "Deeply-nested scopes with many/long dimensions can exceed the limit"] });
    }
    let stored: { properties: { id?: string; version?: string } };
    try {
      stored = await this.secrets.setSecret(name, request.value, { tags: { managed_by: "nullplatform" } });
    } catch (error) {
      throw new Failure("STORE_FAILED", { what: `Failed to store secret in Azure Key Vault '${this.vaultName}'`, causes: [`The service principal lacks Set permission on ${this.vaultName}`, "The vault firewall blocks the caller, or the token expired"], fixes: ["Confirm the SP has the Key Vault Secrets Officer role on the vault"], underlying: messageOf(error) });
    }
    const version = stored.properties.version ?? (stored.properties.id ?? "").split("/").pop() ?? "";
    return { external_id: handleOf(name, version), metadata: { azure_secret_id: stored.properties.id ?? "", secret_name: name, vault_name: this.vaultName } };
  }

  async retrieve(request: ParameterRequest) {
    const name = request.externalId.path;
    const version = request.externalId.version;
    try {
      const secret = await this.secrets.getSecret(name, version ? { version } : undefined);
      return { value: secret.value ?? "" };
    } catch (error) {
      if (statusOf(error) === 404) {
        throw new Failure("NOT_FOUND", { what: `Secret '${name}' not found in Azure Key Vault '${this.vaultName}'`, causes: ["The secret was manually deleted (and possibly purged) from AKV", "The external_id is stale", ...(version ? [`Requested version '${version}' was purged from AKV`] : [])], fixes: [`Verify: GET ${this.vaultUrl}/secrets/${name}?api-version=7.4`, "If genuinely missing, the parameter value needs to be re-stored"] });
      }
      throw new Failure("RETRIEVE_FAILED", { what: `Failed to retrieve secret '${name}' from Azure Key Vault '${this.vaultName}'`, causes: [`The service principal lacks Get permission on vault ${this.vaultName}`, "The vault firewall blocks the caller, or the token expired"], fixes: ["Confirm the SP has the Key Vault Secrets Officer role on the vault"], underlying: messageOf(error) });
    }
  }

  /** The backend has no batch read: a batch is its values read in parallel. */
  retrieveBatch(requests: ParameterRequest[]): Promise<RetrievedBatch> {
    return retrieveEach(this, requests, this.context.log);
  }

  async delete(request: ParameterRequest) {
    const name = request.externalId.path;
    try {
      const deletion = await this.secrets.beginDeleteSecret(name);
      await deletion.pollUntilDone();
    } catch (error) {
      if (statusOf(error) === 404) {
        this.context.log.debug(`Secret '${name}' does not exist, treating delete as success`);
        return DONE;
      }
      throw new Failure("DELETE_FAILED", { what: `Failed to delete secret '${name}' from Azure Key Vault '${this.vaultName}'`, causes: [`The service principal lacks Delete permission on vault ${this.vaultName}`, "The vault firewall blocks the caller, or the token expired"], fixes: ["Confirm the SP has the Key Vault Secrets Officer role on the vault"], underlying: messageOf(error) });
    }
    await this.purge(name);
    return DONE;
  }

  /** Frees the name and ends retention billing; a vault with purge protection keeps the secret in its soft-delete window, which is not a failure. */
  private async purge(name: string): Promise<void> {
    try {
      await this.secrets.purgeDeletedSecret(name);
    } catch (error) {
      const status = statusOf(error);
      if (status === 404) {
        return;
      }
      if (status === 409) {
        this.context.log.debug(`Purge protection enabled on '${this.vaultName}'; secret remains in the soft-delete window until retention expiry`);
        return;
      }
      if (status === 403) {
        this.context.log.warn(`Purge permission missing on '${this.vaultName}': secret remains in soft-delete window`);
        return;
      }
      this.context.log.warn(`Purge failed (secret remains in soft-delete window): ${messageOf(error)}`);
    }
  }
}

export function azureKeyVault(options: KeyVaultOptions = {}): Provider {
  const clients = options.clients ?? { credential: (tenantId, clientId, clientSecret) => new ClientSecretCredential(tenantId, clientId, clientSecret), secrets: (vaultUrl, credential) => new SecretClient(vaultUrl, credential) };
  const env = options.env ?? process.env;
  return {
    slug: SLUG,
    async open(request, context) {
      const vaultName = settingOf(request.provider.attributes, env, { attribute: "setup.vault_name", variable: "AZURE_KEY_VAULT_NAME" });
      if (vaultName === "") {
        throw new Failure("MISSING_VAULT", { what: "Azure Key Vault name not configured", causes: ["AZURE_KEY_VAULT_NAME env var is not set", ".vault_name is missing in the azure-key-vault provider config"], fixes: ["Set AZURE_KEY_VAULT_NAME=<your-vault-name>", "Or set .vault_name in the provider config attributes"] });
      }
      // The service principal's credentials are sensitive: the environment only, never the provider's attributes.
      const { AZURE_CLIENT_ID: clientId, AZURE_CLIENT_SECRET: clientSecret, AZURE_TENANT_ID: tenantId } = env;
      if (!clientId || !clientSecret || !tenantId) {
        throw new Failure("MISSING_CREDENTIALS", { what: "Azure service principal credentials not configured", causes: ["AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID are not all set in the agent runtime"], fixes: ["Set all three env vars (the client secret is sensitive: env only, never provider config)"] });
      }
      const vaultUrl = `https://${vaultName}.vault.azure.net`;
      return new KeyVaultSession(clients.secrets(vaultUrl, clients.credential(tenantId, clientId, clientSecret)), vaultName, vaultUrl, context);
    },
  };
}
