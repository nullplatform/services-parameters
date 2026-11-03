import { describe, expect, test } from "bun:test";
import { externalIdOf, handleOf, nrnOf, requestOf } from "../src/context";
import { Failure, troubleMessage } from "../src/failure";
import { canonicalPath, sanitizeForPath } from "../src/naming";
import { settingOf } from "../src/settings";
import { CANONICAL, requestFor } from "./support";

describe("the request", () => {
  test("reads the parameter, its handle split at the version, the provider and its attributes", () => {
    const request = requestFor("hashicorp-vault", {
      external_id: "secret/data/nullplatform/x/y-1#3",
      value: "v",
      provider: {
        specification_slug: "hashicorp-vault",
        specification_id: "id-1",
        attributes: { setup: { address: "https://vault" } },
      },
    });
    expect(request).toMatchObject({
      kind: "secret",
      parameterId: "42",
      name: "DB_PASSWORD",
      value: "v",
      externalId: { path: "secret/data/nullplatform/x/y-1", version: "3" },
      provider: {
        slug: "hashicorp-vault",
        specificationId: "id-1",
        attributes: { setup: { address: "https://vault" } },
      },
    });
    expect(externalIdOf("no-version")).toEqual({ path: "no-version", version: "" });
    expect(handleOf("p", "")).toBe("p");
    expect(handleOf("p", "7")).toBe("p#7");
  });

  test("a scoped value's entities and dimensions win over the parameter's, and the NRN carries the scope", () => {
    const request = requestFor("aws-secrets-manager", {
      value_entities: {
        organization: "1",
        organization_slug: "o",
        account: "2",
        account_slug: "a",
        namespace: "3",
        namespace_slug: "n",
        application: "4",
        application_slug: "p",
        scope: "5",
        scope_slug: "s",
      },
      dimensions: { environment: "prod" },
      value_dimensions: { environment: "prod", country: "ar" },
    });
    expect(request.entities.scope).toBe("5");
    expect(nrnOf(request)).toBe("organization=1:account=2:namespace=3:application=4:scope=5");
    expect(request.valueDimensions).toEqual({ environment: "prod", country: "ar" });
    expect(canonicalPath(request)).toBe(
      "organization=o-1/account=a-2/namespace=n-3/application=p-4/scope=s-5/environment=prod/DB_PASSWORD-42",
    );
  });

  test("a payload naming no provider is refused", () => {
    expect(() => requestOf({ action: "parameter:store" })).toThrow(
      expect.objectContaining({ code: "MISSING_PROVIDER" }),
    );
  });
});

describe("the canonical path", () => {
  test("is the entities in NRN order, the dimensions sorted, then the parameter's name and id", () => {
    expect(canonicalPath(requestFor("x"))).toBe(CANONICAL);
    expect(canonicalPath(requestFor("x", { dimensions: { environment: "production", country: "ar" } }))).toBe(
      CANONICAL.replace("/DB_PASSWORD-42", "/country=ar/environment=production/DB_PASSWORD-42"),
    );
    expect(canonicalPath(requestFor("x", { parameter_name: "a b/c" }))).toContain("/a_b_c-42");
    expect(canonicalPath(requestFor("x", { parameter_name: null }))).toContain("/42");
    expect(sanitizeForPath("ok.name_1-x")).toBe("ok.name_1-x");
  });
});

describe("a setting", () => {
  const attributes = { setup: { kms_key_id: "alias/x", replica_locations: ["a", "b"], empty: "" } };
  test("comes from the provider's attributes first, the environment second, the default last", () => {
    expect(settingOf(attributes, { KMS: "env" }, { attribute: "setup.kms_key_id", variable: "KMS" })).toBe("alias/x");
    expect(settingOf(attributes, { KMS: "env" }, { attribute: "setup.missing", variable: "KMS", fallback: "d" })).toBe(
      "env",
    );
    expect(settingOf(attributes, {}, { attribute: "setup.empty", variable: "KMS", fallback: "d" })).toBe("d");
    expect(settingOf(attributes, {}, { attribute: "setup.replica_locations" })).toBe("a,b");
    expect(settingOf(attributes, {}, { variable: "NOPE" })).toBe("");
  });
});

describe("a failure", () => {
  test("reads as the bash printed it: the problem, the causes, the fixes, the backend's words", () => {
    const failure = new Failure("X", { what: "It broke", causes: ["a", "b"], fixes: ["do c"], underlying: "boom" });
    expect(failure.code).toBe("X");
    expect(failure.message).toBe(
      "❌ It broke\n\n💡 Possible causes:\n   • a\n   • b\n\n🔧 How to fix:\n   • do c\nUnderlying error: boom",
    );
    expect(troubleMessage({ what: "Only this" })).toBe("❌ Only this");
  });
});
