import type { Provider } from "../provider";
import { awsParameterStore } from "./aws-parameter-store";
import { awsSecretsManager } from "./aws-secrets-manager";
import { azureKeyVault } from "./azure-key-vault";
import { gcpSecretManager } from "./gcp-secret-manager";
import { hashicorpVault } from "./hashicorp-vault";

/** One of every backend the image carries; the worker picks the one each request names in `provider.specification_slug`. */
export const allProviders = (): Provider[] => [
  awsParameterStore(),
  awsSecretsManager(),
  azureKeyVault(),
  gcpSecretManager(),
  hashicorpVault(),
];
