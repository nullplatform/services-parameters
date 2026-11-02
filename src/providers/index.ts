import type { Provider } from "../provider";
import { awsParameterStore, SLUG as AWS_PARAMETER_STORE } from "./aws-parameter-store";
import { awsSecretsManager, SLUG as AWS_SECRETS_MANAGER } from "./aws-secrets-manager";
import { azureKeyVault, SLUG as AZURE_KEY_VAULT } from "./azure-key-vault";
import { gcpSecretManager, SLUG as GCP_SECRET_MANAGER } from "./gcp-secret-manager";
import { hashicorpVault, SLUG as HASHICORP_VAULT } from "./hashicorp-vault";

/** Every backend the image carries, by the slug the platform names in `provider.specification_slug`. */
export const PROVIDERS: Record<string, () => Provider> = {
  [AWS_PARAMETER_STORE]: () => awsParameterStore(),
  [AWS_SECRETS_MANAGER]: () => awsSecretsManager(),
  [AZURE_KEY_VAULT]: () => azureKeyVault(),
  [GCP_SECRET_MANAGER]: () => gcpSecretManager(),
  [HASHICORP_VAULT]: () => hashicorpVault(),
};

/** One of each backend: the worker picks the one each request names. */
export function allProviders(): Provider[] {
  return Object.values(PROVIDERS).map((factory) => factory());
}
