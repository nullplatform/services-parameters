import { describe, expect, test } from "bun:test";
import { run } from "@nullplatform/plugin/testing";
import type { Provider } from "../src/provider";
import deleteSample from "../src/samples/delete.json" with { type: "json" };
import notifySample from "../src/samples/notify.json" with { type: "json" };
import retrieveBatchSample from "../src/samples/retrieve-batch.json" with { type: "json" };
import retrieveSample from "../src/samples/retrieve.json" with { type: "json" };
import storeSample from "../src/samples/store.json" with { type: "json" };
import { parametersWorker } from "../src/worker";

/** A backend that answers in words, so the test sees what reached it. */
function echoProvider(slug: string, withNotify = false): { provider: Provider; seen: string[] } {
  const seen: string[] = [];
  const provider: Provider = {
    slug,
    async open(request) {
      seen.push(`open ${request.provider.slug}`);
      return {
        store: async (own) => ({ external_id: `${own.name}-${own.parameterId}#1`, metadata: {} }),
        retrieve: async (own) => ({ value: `value of ${own.externalId.path} at ${own.externalId.version}` }),
        delete: async () => ({ success: true as const }),
        ...(withNotify ? { notify: async () => { seen.push("notified"); return { success: true as const }; } } : {}),
      };
    },
  };
  return { provider, seen };
}

describe("the worker", () => {
  test("is the package the image names, with one route per action on a channel for every backend", () => {
    const plugin = parametersWorker([echoProvider("aws-secrets-manager").provider, echoProvider("hashicorp-vault").provider], { package: { name: "parameters", version: "1.0.0" }, sources: ["service"] });
    expect(plugin.package).toMatchObject({ name: "parameters", version: "1.0.0" });
    expect(plugin.manifest().runs.map((entry) => entry.name)).toEqual(["parameter:store", "parameter:retrieve", "parameter:delete", "parameter:notify", "parameter:retrieve_batch"]);
    const channel = plugin.manifest().components.find((component) => component.resource_type === "notification_channel")!.resource as { source: string[]; filters: unknown };
    expect(channel.source).toEqual(["service"]);
    expect(JSON.stringify(channel.filters)).toContain('"provider.specification_slug":"aws-secrets-manager"');
    expect(JSON.stringify(channel.filters)).toContain('"provider.specification_slug":"hashicorp-vault"');
  });

  test("answers each action with what the provider returns, and notify with the default ack when the provider has none", async () => {
    const { provider, seen } = echoProvider("aws-secrets-manager");
    const plugin = parametersWorker([provider], { package: { name: "p", version: "0" }, sources: ["service"] });
    expect((await run(plugin, storeSample.notification)).data).toEqual({ external_id: "DB_PASSWORD-42#1", metadata: {} });
    expect((await run(plugin, retrieveSample.notification)).data).toEqual({ value: "value of organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/environment=production/DB_PASSWORD-42 at a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d" });
    expect((await run(plugin, deleteSample.notification)).data).toEqual({ success: true });
    expect((await run(plugin, notifySample.notification)).data).toEqual({ success: true });
    expect(seen).toEqual(["open aws-secrets-manager", "open aws-secrets-manager", "open aws-secrets-manager", "open aws-secrets-manager"]);
    const notifying = echoProvider("aws-secrets-manager", true);
    await run(parametersWorker([notifying.provider], { package: { name: "p", version: "0" }, sources: ["service"] }), notifySample.notification);
    expect(notifying.seen).toContain("notified");
  });

  test("each request reaches the backend it names, in one worker", async () => {
    const secrets = echoProvider("aws-secrets-manager");
    const vault = echoProvider("hashicorp-vault");
    const plugin = parametersWorker([vault.provider, secrets.provider], { package: { name: "p", version: "0" }, sources: ["service"] });
    await run(plugin, storeSample.notification);
    await run(plugin, { ...storeSample.notification, provider: { ...storeSample.notification.provider, specification_slug: "hashicorp-vault" } });
    expect(secrets.seen).toEqual(["open aws-secrets-manager"]);
    expect(vault.seen).toEqual(["open hashicorp-vault"]);
  });

  test("a parameter bound to a backend the image does not carry is refused by name", async () => {
    const plugin = parametersWorker([echoProvider("hashicorp-vault").provider], { package: { name: "p", version: "0" }, sources: ["service"] });
    const result = await run(plugin, storeSample.notification);
    expect(result.success).toBe(false);
    expect(result.failure).toMatchObject({ code: "UNKNOWN_PROVIDER", message: expect.stringContaining("bound to aws-secrets-manager") });
  });
});

describe("a batch retrieve", () => {
  test("is refused as not implemented by a backend without a batch read, so the platform retrieves one by one", async () => {
    const { provider } = echoProvider("aws-secrets-manager");
    const plugin = parametersWorker([provider], { package: { name: "parameters", version: "1.0.0" }, sources: ["parameters"] });
    const answer = await run(plugin, retrieveBatchSample.notification);
    expect(answer.success).toBe(false);
    expect(answer.failure).toMatchObject({ code: "NOT_IMPLEMENTED" });
  });

  test("hands a backend with a batch read every value's request, the shared provider and entities on each", async () => {
    const seen: string[] = [];
    const provider: Provider = {
      slug: "aws-secrets-manager",
      async open(request) {
        seen.push(`open ${request.provider.slug} ${request.externalId.path}`);
        return {
          store: async () => ({ external_id: "", metadata: {} }),
          retrieve: async () => ({ value: "" }),
          delete: async () => ({ success: true as const }),
          retrieveBatch: async (requests) => ({ values: requests.map((own) => ({ external_id: `${own.externalId.path}#${own.externalId.version}`, value: `${own.kind} ${own.name} of ${own.entities.application}` })) }),
        };
      },
    };
    const plugin = parametersWorker([provider], { package: { name: "parameters", version: "1.0.0" }, sources: ["parameters"] });
    const answer = await run(plugin, retrieveBatchSample.notification);
    expect(answer.success).toBe(true);
    expect((answer.data as { values: unknown[] }).values).toEqual([
      { external_id: retrieveBatchSample.notification.values[0].external_id, value: "secret DB_PASSWORD of 321402625" },
      { external_id: retrieveBatchSample.notification.values[1].external_id, value: "secret API_TOKEN of 321402625" },
      { external_id: retrieveBatchSample.notification.values[2].external_id, value: "parameter LOG_LEVEL of 321402625" },
    ]);
    expect(seen).toEqual([`open aws-secrets-manager ${retrieveBatchSample.notification.values[0].external_id.split("#")[0]}`]);
    const empty = await run(plugin, { ...retrieveBatchSample.notification, values: [] });
    expect(empty.failure).toMatchObject({ code: "MISSING_VALUES" });
  });
});
