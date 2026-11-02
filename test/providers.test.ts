import { describe, expect, test } from "bun:test";
import { workerConfigOf } from "../src/config";
import { PROVIDERS, providerOf } from "../src/providers";

describe("the provider", () => {
  test("is the backend PARAMETERS_PROVIDER names, for every backend in the image", () => {
    expect(Object.keys(PROVIDERS).sort()).toEqual(["aws-parameter-store", "aws-secrets-manager", "azure-key-vault", "gcp-secret-manager", "hashicorp-vault"]);
    for (const slug of Object.keys(PROVIDERS)) {
      expect(providerOf({ PARAMETERS_PROVIDER: slug }).slug).toBe(slug);
    }
  });

  test("a missing or unknown PARAMETERS_PROVIDER is refused with the backends it can name", () => {
    expect(() => providerOf({})).toThrow('PARAMETERS_PROVIDER must name one of aws-parameter-store, aws-secrets-manager, azure-key-vault, gcp-secret-manager, hashicorp-vault, and it is ""');
    expect(() => providerOf({ PARAMETERS_PROVIDER: "mongodb" })).toThrow('and it is "mongodb"');
  });

  test("the package is parameters unless the image names another", () => {
    expect(workerConfigOf({}).package.name).toBe("parameters");
    expect(workerConfigOf({ NP_PACKAGE_NAME: "parameters-beta" }).package.name).toBe("parameters-beta");
  });
});
