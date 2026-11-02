import { describe, expect, test } from "bun:test";
import { run } from "@nullplatform/plugin/testing";
import type { Provider } from "../src/provider";
import deleteSample from "../src/samples/delete.json" with { type: "json" };
import notifySample from "../src/samples/notify.json" with { type: "json" };
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
  test("is the package the image names, with one route per action on the provider's channel", () => {
    const plugin = parametersWorker(echoProvider("aws-secrets-manager").provider, { package: { name: "parameters-aws-secrets-manager", version: "1.0.0" }, sources: ["service"] });
    expect(plugin.package).toMatchObject({ name: "parameters-aws-secrets-manager", version: "1.0.0" });
    expect(plugin.manifest().runs.map((entry) => entry.name)).toEqual(["parameter:store", "parameter:retrieve", "parameter:delete", "parameter:notify"]);
    const channel = plugin.manifest().components.find((component) => component.resource_type === "notification_channel")!.resource as { source: string[]; filters: unknown };
    expect(channel.source).toEqual(["service"]);
    expect(JSON.stringify(channel.filters)).toContain('"provider.specification_slug":"aws-secrets-manager"');
  });

  test("answers each action with what the provider returns, and notify with the default ack when the provider has none", async () => {
    const { provider, seen } = echoProvider("aws-secrets-manager");
    const plugin = parametersWorker(provider, { package: { name: "p", version: "0" }, sources: ["service"] });
    expect((await run(plugin, storeSample.notification)).data).toEqual({ external_id: "DB_PASSWORD-42#1", metadata: {} });
    expect((await run(plugin, retrieveSample.notification)).data).toEqual({ value: "value of organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/environment=production/DB_PASSWORD-42 at a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d" });
    expect((await run(plugin, deleteSample.notification)).data).toEqual({ success: true });
    expect((await run(plugin, notifySample.notification)).data).toEqual({ success: true });
    expect(seen).toEqual(["open aws-secrets-manager", "open aws-secrets-manager", "open aws-secrets-manager", "open aws-secrets-manager"]);
    const notifying = echoProvider("aws-secrets-manager", true);
    await run(parametersWorker(notifying.provider, { package: { name: "p", version: "0" }, sources: ["service"] }), notifySample.notification);
    expect(notifying.seen).toContain("notified");
  });

  test("a parameter bound to another backend is refused by name", async () => {
    const plugin = parametersWorker(echoProvider("hashicorp-vault").provider, { package: { name: "p", version: "0" }, sources: ["service"] });
    const result = await run(plugin, storeSample.notification);
    expect(result.success).toBe(false);
    expect(result.failure).toMatchObject({ code: "WRONG_PROVIDER", message: expect.stringContaining("bound to aws-secrets-manager") });
  });
});
