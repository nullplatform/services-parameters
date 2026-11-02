import type { Provider } from "../provider";
import { awsParameterStore, SLUG as AWS_PARAMETER_STORE } from "./aws-parameter-store";
import { awsSecretsManager, SLUG as AWS_SECRETS_MANAGER } from "./aws-secrets-manager";
import { azureKeyVault, SLUG as AZURE_KEY_VAULT } from "./azure-key-vault";
import { gcpSecretManager, SLUG as GCP_SECRET_MANAGER } from "./gcp-secret-manager";
import { hashicorpVault, SLUG as HASHICORP_VAULT } from "./hashicorp-vault";

export const PROVIDER_VARIABLE = "PARAMETERS_PROVIDER";

export const PROVIDERS: Record<string, () => Provider> = {
  [AWS_PARAMETER_STORE]: () => awsParameterStore(),
  [AWS_SECRETS_MANAGER]: () => awsSecretsManager(),
  [AZURE_KEY_VAULT]: () => azureKeyVault(),
  [GCP_SECRET_MANAGER]: () => gcpSecretManager(),
  [HASHICORP_VAULT]: () => hashicorpVault(),
};

export function providerOf(env: Record<string, string | undefined> = process.env): Provider {
  const slug = env[PROVIDER_VARIABLE] ?? "";
  const factory = PROVIDERS[slug];
  if (!factory) {
    throw new Error(`${PROVIDER_VARIABLE} must name one of ${Object.keys(PROVIDERS).join(", ")}, and it is "${slug}"`);
  }
  return factory();
}
