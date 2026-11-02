import { describe, expect, test } from "bun:test";
import { API_URL, gcpSecretManager, labelsOf, secretIdOf, validPrefix } from "../src/providers/gcp-secret-manager/index";
import { CANONICAL, fakeContext, fakeFetch, requestFor } from "./support";

const SECRET_ID = secretIdOf("nullplatform", CANONICAL);
const SECRETS = `${API_URL}/projects/acme-prod/secrets`;
const ATTRIBUTES = { setup: { project_id: "acme-prod" } };

const open = async (route: Parameters<typeof fakeFetch>[0], extra: Record<string, unknown> = {}, attributes: Record<string, unknown> = ATTRIBUTES) => {
  const fake = fakeFetch(route);
  const provider = gcpSecretManager({ clients: { token: async () => "tok", fetch: fake.fetch }, env: {} });
  const request = requestFor("gcp-secret-manager", { ...extra, provider: { specification_slug: "gcp-secret-manager", attributes } });
  const { context } = fakeContext();
  return { session: await provider.open(request, context), request, calls: fake.calls };
};

describe("gcp-secret-manager", () => {
  test("the secret id flattens the canonical path under the prefix, and the prefix must fit Secret Manager's charset", () => {
    expect(SECRET_ID).toBe("nullplatform__organization-acme-1255165411__account-prod-95118862__namespace-billing-37094320__application-api-321402625__DB_PASSWORD-42");
    expect(validPrefix("np-1_x")).toBe(true);
    expect(validPrefix("np__x")).toBe(false);
    expect(validPrefix("np/x")).toBe(false);
  });

  test("open needs the project and a valid prefix", async () => {
    await expect(open(() => undefined, {}, {})).rejects.toMatchObject({ code: "MISSING_PROJECT" });
    await expect(open(() => undefined, {}, { setup: { project_id: "p", name_prefix: "a__b" } })).rejects.toMatchObject({ code: "INVALID_PREFIX" });
  });

  test("store adds a version, creating the secret with its labels and replication on the first store", async () => {
    let exists = false;
    const { session, request, calls } = await open((method, url) => {
      if (url.endsWith(":addVersion")) {
        return exists ? { status: 200, body: { name: `projects/1/secrets/${SECRET_ID}/versions/1` } } : { status: 404, body: { error: { message: "not found" } } };
      }
      if (method === "POST" && url.startsWith(`${SECRETS}?secretId=`)) {
        exists = true;
        return { status: 200, body: {} };
      }
      return undefined;
    }, {}, { setup: { project_id: "acme-prod", replica_locations: ["europe-west1"] } });
    expect(await session.store(request)).toEqual({ external_id: `${CANONICAL}#1`, metadata: { secret_id: SECRET_ID, version_name: `projects/1/secrets/${SECRET_ID}/versions/1`, project_id: "acme-prod" } });
    expect(calls.map((call) => call.method)).toEqual(["POST", "POST", "POST"]);
    expect(calls[0].body).toEqual({ payload: { data: Buffer.from("s3cr3t").toString("base64") } });
    expect(calls[0].headers.Authorization).toBe("Bearer tok");
    expect(calls[1].body).toEqual({ replication: { userManaged: { replicas: [{ location: "europe-west1" }] } }, labels: labelsOf(request) });
    expect(labelsOf(request)).toEqual({ organization_id: "1255165411", organization: "acme", account_id: "95118862", account: "prod", namespace_id: "37094320", namespace: "billing", application_id: "321402625", application: "api", managed_by: "nullplatform", parameter_id: "42" });
  });

  test("a second store only adds a version; a create refused for anything but a race fails", async () => {
    const { session, request, calls } = await open(() => ({ status: 200, body: { name: "projects/1/secrets/x/versions/7" } }));
    expect((await session.store(request)).external_id).toBe(`${CANONICAL}#7`);
    expect(calls).toHaveLength(1);
    const refused = await open((method, url) => (url.endsWith(":addVersion") ? { status: 404 } : { status: 403, body: { error: { message: "denied" } } }));
    await expect(refused.session.store(refused.request)).rejects.toMatchObject({ code: "STORE_FAILED", message: expect.stringContaining("denied") });
    const raced = await open((method, url) => (url.endsWith(":addVersion") ? { status: 200, body: { name: "projects/1/secrets/x/versions/2" } } : { status: 409 }));
    expect((await raced.session.store(raced.request)).external_id).toBe(`${CANONICAL}#2`);
  });

  test("retrieve accesses the version or latest and decodes the payload; an altered version is refused; 404 is NOT_FOUND", async () => {
    const { session, request, calls } = await open(() => ({ status: 200, body: { payload: { data: Buffer.from("v\n").toString("base64") } } }), { external_id: `${CANONICAL}#3` });
    expect(await session.retrieve(request)).toEqual({ value: "v\n" });
    expect(calls[0].url).toBe(`${SECRETS}/${SECRET_ID}/versions/3:access`);
    const latest = await open(() => ({ status: 200, body: { payload: { data: "" } } }), { external_id: CANONICAL });
    await latest.session.retrieve(latest.request);
    expect(latest.calls[0].url).toBe(`${SECRETS}/${SECRET_ID}/versions/latest:access`);
    const altered = await open(() => undefined, { external_id: `${CANONICAL}#../x` });
    await expect(altered.session.retrieve(altered.request)).rejects.toMatchObject({ code: "INVALID_VERSION" });
    const missing = await open(() => ({ status: 404 }), { external_id: `${CANONICAL}#3` });
    await expect(missing.session.retrieve(missing.request)).rejects.toMatchObject({ code: "NOT_FOUND" });
    const offline = await open(() => undefined, { external_id: CANONICAL });
    await expect(offline.session.retrieve(offline.request)).rejects.toMatchObject({ code: "RETRIEVE_FAILED", message: expect.stringContaining("no HTTP response") });
  });

  test("delete is final and idempotent", async () => {
    const { session, request, calls } = await open(() => ({ status: 200 }), { external_id: `${CANONICAL}#3` });
    expect(await session.delete(request)).toEqual({ success: true });
    expect(calls[0]).toMatchObject({ method: "DELETE", url: `${SECRETS}/${SECRET_ID}` });
    const gone = await open(() => ({ status: 404 }), { external_id: CANONICAL });
    expect(await gone.session.delete(gone.request)).toEqual({ success: true });
    const refused = await open(() => ({ status: 403 }), { external_id: CANONICAL });
    await expect(refused.session.delete(refused.request)).rejects.toMatchObject({ code: "DELETE_FAILED" });
  });
});
