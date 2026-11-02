import { describe, expect, test } from "bun:test";
import { workerConfigOf } from "../src/config";
import { allProviders, PROVIDERS } from "../src/providers";

describe("the providers", () => {
  test("the image carries every backend, each under the slug the platform names", () => {
    expect(Object.keys(PROVIDERS).sort()).toEqual(["aws-parameter-store", "aws-secrets-manager", "azure-key-vault", "gcp-secret-manager", "hashicorp-vault"]);
    expect(allProviders().map((provider) => provider.slug).sort()).toEqual(Object.keys(PROVIDERS).sort());
  });

  test("the package is parameters unless the image names another", () => {
    expect(workerConfigOf({}).package.name).toBe("parameters");
    expect(workerConfigOf({ NP_PACKAGE_NAME: "parameters-beta" }).package.name).toBe("parameters-beta");
  });
});
