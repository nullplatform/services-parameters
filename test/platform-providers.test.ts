import type { Api } from "@nullplatform/plugin";
import { beforeEach, describe, expect, test } from "bun:test";
import { REMEMBER_MS, betterProvider, dimensionFit, dimensionsQuery, forgetProviders, providerOf } from "../src/platform/providers";
import { fakeApi } from "./support";

const ACCOUNT = "organization=1:account=2";
const APPLICATION = `${ACCOUNT}:namespace=3:application=4`;

describe("a provider's fit to a request's dimensions", () => {
  test("counts what it matches and what the request never asked, and refuses a value that differs", () => {
    expect(dimensionFit({ id: "a", nrn: ACCOUNT, specification_id: "s" }, { environment: "prod" })).toEqual({ matched: 0, unasked: 0 });
    expect(dimensionFit({ id: "a", nrn: ACCOUNT, specification_id: "s", dimensions: { environment: "prod", country: "ar" } }, { environment: "prod" })).toEqual({ matched: 1, unasked: 1 });
    expect(dimensionFit({ id: "a", nrn: ACCOUNT, specification_id: "s", dimensions: { environment: "dev" } }, { environment: "prod" })).toBeUndefined();
    expect(dimensionsQuery({ environment: "prod", country: "ar" })).toBe("country:ar,environment:prod");
  });

  test("ranks the longer NRN, then the more matched, then the fewer unasked, then the lower id", () => {
    const row = (id: string, nrn: string, dimensions?: Record<string, string>) => ({ id, nrn, specification_id: "s", dimensions });
    const asked = { environment: "prod" };
    expect(betterProvider(row("a", ACCOUNT), row("b", APPLICATION), asked).id).toBe("b");
    expect(betterProvider(row("a", ACCOUNT, { environment: "prod" }), row("b", ACCOUNT), asked).id).toBe("a");
    expect(betterProvider(row("a", ACCOUNT, { country: "ar" }), row("b", ACCOUNT), asked).id).toBe("b");
    expect(betterProvider(row("b", ACCOUNT), row("a", ACCOUNT), asked).id).toBe("a");
  });
});

describe("the provider of a category over an NRN", () => {
  beforeEach(forgetProviders);

  test("asks the category, its specifications, the providers with their ascendants, and reads the winner whole", async () => {
    const { api, calls } = fakeApi([
      { nrn: ACCOUNT, attributes: { iam_role_arns: { arns: [{ selector: "parameter_store", arn: "arn:account" }] } } },
      { nrn: APPLICATION, attributes: { iam_role_arns: { arns: [{ selector: "parameter_store", arn: "arn:application" }] } } },
      { nrn: APPLICATION, dimensions: { environment: "dev" }, attributes: { iam_role_arns: { arns: [{ selector: "parameter_store", arn: "arn:dev" }] } } },
    ]);
    const provider = await providerOf(api as Api, "identity-access-control", APPLICATION, { environment: "prod" });
    expect(provider?.attributes).toEqual({ iam_role_arns: { arns: [{ selector: "parameter_store", arn: "arn:application" }] } });
    expect(calls).toEqual([
      'GET /category {"slug":"identity-access-control"}',
      `GET /provider_specification {"category":"c1","nrn":"${APPLICATION}"}`,
      `GET /provider {"nrn":"${APPLICATION}","specification_id":"s1","show_ascendants":true,"dimensions":"environment:prod"}`,
      "GET /provider/p2",
    ]);
  });

  test("sends no dimensions query for a request without them, and answers none when nothing is configured", async () => {
    const { api, calls } = fakeApi([{ nrn: ACCOUNT, attributes: { server: { url: "http://prometheus" } } }]);
    const provider = await providerOf(api as Api, "metrics", APPLICATION, {});
    expect(provider?.attributes).toEqual({ server: { url: "http://prometheus" } });
    expect(calls[2]).toBe(`GET /provider {"nrn":"${APPLICATION}","specification_id":"s1","show_ascendants":true}`);
    const none = fakeApi([]);
    forgetProviders();
    expect(await providerOf(none.api as Api, "metrics", APPLICATION, {})).toBeUndefined();
    expect(none.calls).toEqual(['GET /category {"slug":"metrics"}']);
  });

  test("answers none when the category has specifications but no provider fits", async () => {
    const { api } = fakeApi([{ nrn: ACCOUNT, dimensions: { environment: "dev" }, attributes: {} }]);
    expect(await providerOf(api as Api, "identity-access-control", APPLICATION, { environment: "prod" })).toBeUndefined();
    const empty = { ...fakeApi([{ nrn: ACCOUNT }]).api as Record<string, unknown>, provider_specification: { get: async () => ({ results: [] }) } };
    expect(await providerOf(empty as unknown as Api, "identity-access-control", APPLICATION, {})).toBeUndefined();
  });

  test("remembers a resolution for a minute, per category, NRN and dimensions, and forgets a failed one", async () => {
    let clock = 1_000;
    const now = () => clock;
    const { api, calls } = fakeApi([{ nrn: ACCOUNT, attributes: { server: { url: "http://prometheus" } } }]);
    await providerOf(api as Api, "metrics", APPLICATION, {}, now);
    await providerOf(api as Api, "metrics", APPLICATION, {}, now);
    expect(calls.length).toBe(4);
    await providerOf(api as Api, "metrics", APPLICATION, { environment: "prod" }, now);
    expect(calls.length).toBe(8);
    clock += REMEMBER_MS;
    await providerOf(api as Api, "metrics", APPLICATION, {}, now);
    expect(calls.length).toBe(12);
    const failing = { category: { get: async () => { throw new Error("down"); } } };
    await expect(providerOf(failing as unknown as Api, "metrics", ACCOUNT, {}, now)).rejects.toThrow("down");
    await expect(providerOf(failing as unknown as Api, "metrics", ACCOUNT, {}, now)).rejects.toThrow("down");
  });
});
