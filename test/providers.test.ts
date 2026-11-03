import { describe, expect, test } from "bun:test";
import { workerConfigOf } from "../src/config";
import { allProviders } from "../src/providers";

describe("the providers", () => {
  test("the image carries every backend, each under the slug the platform names", () => {
    expect(allProviders().map((provider) => provider.slug)).toEqual([
      "aws-parameter-store",
      "aws-secrets-manager",
      "azure-key-vault",
      "gcp-secret-manager",
      "hashicorp-vault",
    ]);
  });

  test("the package is parameters unless the image names another", () => {
    expect(workerConfigOf({}).package.name).toBe("parameters");
    expect(workerConfigOf({ NP_PACKAGE_NAME: "parameters-beta" }).package.name).toBe("parameters-beta");
    expect(workerConfigOf({}).sources).toEqual(["parameters"]);
    expect(workerConfigOf({ NP_AGENT_SOURCES: "service, parameters" }).sources).toEqual(["service", "parameters"]);
  });
});
