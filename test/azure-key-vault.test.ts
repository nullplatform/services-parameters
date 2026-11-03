import { describe, expect, test } from "bun:test";
import { azureKeyVault, secretNameOf, type SecretsLike } from "../src/providers/azure-key-vault/index";
import { fakeContext, requestFor } from "./support";

const restError = (statusCode: number): Error => Object.assign(new Error(`HTTP ${statusCode}`), { statusCode });
const ENV = { AZURE_CLIENT_ID: "cid", AZURE_CLIENT_SECRET: "csec", AZURE_TENANT_ID: "tid" };

function fakeSecrets(behaviour: Partial<SecretsLike> & { purgeStatus?: number } = {}) {
  const calls: Array<{ method: string; args: unknown[] }> = [];
  const secrets: SecretsLike = {
    setSecret: async (name, value, options) => {
      calls.push({ method: "setSecret", args: [name, value, options] });
      return behaviour.setSecret
        ? behaviour.setSecret(name, value, options)
        : {
            properties: {
              id: `https://v.vault.azure.net/secrets/${name}/93a0b2eb12a64fa7b3acb18900a8d33d`,
              version: "93a0b2eb12a64fa7b3acb18900a8d33d",
            },
          };
    },
    getSecret: async (name, options) => {
      calls.push({ method: "getSecret", args: [name, options] });
      return behaviour.getSecret ? behaviour.getSecret(name, options) : { value: "s3cr3t" };
    },
    beginDeleteSecret: async (name) => {
      calls.push({ method: "beginDeleteSecret", args: [name] });
      return behaviour.beginDeleteSecret ? behaviour.beginDeleteSecret(name) : { pollUntilDone: async () => undefined };
    },
    purgeDeletedSecret: async (name) => {
      calls.push({ method: "purgeDeletedSecret", args: [name] });
      if (behaviour.purgeStatus) {
        throw restError(behaviour.purgeStatus);
      }
    },
  };
  return { secrets, calls };
}

const open = async (
  behaviour: Parameters<typeof fakeSecrets>[0] = {},
  extra: Record<string, unknown> = {},
  env: Record<string, string> = ENV,
  attributes: Record<string, unknown> = { setup: { vault_name: "kv-acme" } },
) => {
  const fake = fakeSecrets(behaviour);
  const urls: string[] = [];
  const provider = azureKeyVault({
    clients: {
      credential: () => ({ getToken: async () => null }),
      secrets: (url) => {
        urls.push(url);
        return fake.secrets;
      },
    },
    env,
  });
  const request = requestFor("azure-key-vault", {
    ...extra,
    provider: { specification_slug: "azure-key-vault", attributes },
  });
  const { context, lines } = fakeContext();
  return { session: await provider.open(request, context), request, calls: fake.calls, urls, lines };
};

describe("azure-key-vault", () => {
  test("the secret's name is the application, the scope, the dimensions and the parameter, dash-joined, slug-free", () => {
    expect(secretNameOf(requestFor("azure-key-vault"))).toBe(
      "application-321402625-DB_PASSWORD-42".replace("DB_PASSWORD", "DB-PASSWORD"),
    );
    const scoped = requestFor("azure-key-vault", {
      value_entities: { application: "4", scope: "5" },
      dimensions: { environment: "prod", country: "ar" },
    });
    expect(secretNameOf(scoped)).toBe("application-4-scope-5-country-ar-environment-prod-DB-PASSWORD-42");
  });

  test("open needs the vault name and the service principal's three variables", async () => {
    await expect(open({}, {}, ENV, {})).rejects.toMatchObject({ code: "MISSING_VAULT" });
    await expect(open({}, {}, { AZURE_CLIENT_ID: "cid" })).rejects.toMatchObject({ code: "MISSING_CREDENTIALS" });
    const { urls } = await open();
    expect(urls).toEqual(["https://kv-acme.vault.azure.net"]);
  });

  test("store sets the secret and the handle is its name with the version; a name over 127 characters is refused", async () => {
    const { session, request, calls } = await open();
    expect(await session.store(request)).toEqual({
      external_id: "application-321402625-DB-PASSWORD-42#93a0b2eb12a64fa7b3acb18900a8d33d",
      metadata: {
        azure_secret_id:
          "https://v.vault.azure.net/secrets/application-321402625-DB-PASSWORD-42/93a0b2eb12a64fa7b3acb18900a8d33d",
        secret_name: "application-321402625-DB-PASSWORD-42",
        vault_name: "kv-acme",
      },
    });
    expect(calls[0]).toEqual({
      method: "setSecret",
      args: ["application-321402625-DB-PASSWORD-42", "s3cr3t", { tags: { managed_by: "nullplatform" } }],
    });
    const long = await open({}, { parameter_name: "x".repeat(120) });
    await expect(long.session.store(long.request)).rejects.toMatchObject({ code: "NAME_TOO_LONG" });
    const refused = await open({
      setSecret: async () => {
        throw restError(403);
      },
    });
    await expect(refused.session.store(refused.request)).rejects.toMatchObject({ code: "STORE_FAILED" });
  });

  test("retrieve reads the handle's name at its version; 404 is NOT_FOUND", async () => {
    const { session, request, calls } = await open({}, { external_id: "application-4-DB-PASSWORD-42#abc" });
    expect(await session.retrieve(request)).toEqual({ value: "s3cr3t" });
    expect(calls[0]).toEqual({ method: "getSecret", args: ["application-4-DB-PASSWORD-42", { version: "abc" }] });
    const missing = await open(
      {
        getSecret: async () => {
          throw restError(404);
        },
      },
      { external_id: "application-4-DB-PASSWORD-42" },
    );
    await expect(missing.session.retrieve(missing.request)).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

  test("delete soft-deletes then purges; purge protection or a missing permission leaves the secret in the soft-delete window", async () => {
    const { session, request, calls } = await open({}, { external_id: "application-4-DB-PASSWORD-42#abc" });
    expect(await session.delete(request)).toEqual({ success: true });
    expect(calls.map((call) => call.method)).toEqual(["beginDeleteSecret", "purgeDeletedSecret"]);
    const protectedVault = await open({ purgeStatus: 409 }, { external_id: "application-4-DB-PASSWORD-42" });
    expect(await protectedVault.session.delete(protectedVault.request)).toEqual({ success: true });
    expect(protectedVault.lines.some((line) => line.startsWith("debug Purge protection"))).toBe(true);
    const noPurge = await open({ purgeStatus: 403 }, { external_id: "application-4-DB-PASSWORD-42" });
    await noPurge.session.delete(noPurge.request);
    expect(noPurge.lines.some((line) => line.startsWith("warn Purge permission missing"))).toBe(true);
    const gone = await open(
      {
        beginDeleteSecret: async () => {
          throw restError(404);
        },
      },
      { external_id: "application-4-DB-PASSWORD-42" },
    );
    expect(await gone.session.delete(gone.request)).toEqual({ success: true });
    const refused = await open(
      {
        beginDeleteSecret: async () => {
          throw restError(403);
        },
      },
      { external_id: "application-4-DB-PASSWORD-42" },
    );
    await expect(refused.session.delete(refused.request)).rejects.toMatchObject({ code: "DELETE_FAILED" });
  });
});

describe("a batch of Key Vault secrets", () => {
  test("reads the values in parallel through getSecret, and leaves out one the vault refuses", async () => {
    const { session, calls } = await open({
      getSecret: async (name) => {
        if (name.endsWith("API-TOKEN-43")) {
          throw restError(404);
        }
        return { value: `value of ${name}` };
      },
    });
    const handles = [
      "application-4-DB-PASSWORD-42#abc",
      "application-4-API-TOKEN-43#def",
      "application-4-LOG-LEVEL-44",
    ];
    const answer = await session.retrieveBatch!(
      handles.map((handle) => requestFor("azure-key-vault", { external_id: handle })),
    );
    expect(answer.values.sort((left, right) => left.external_id.localeCompare(right.external_id))).toEqual([
      { external_id: "application-4-DB-PASSWORD-42#abc", value: "value of application-4-DB-PASSWORD-42" },
      { external_id: "application-4-LOG-LEVEL-44", value: "value of application-4-LOG-LEVEL-44" },
    ]);
    expect(calls.filter((call) => call.method === "getSecret").length).toBe(3);
  });
});
