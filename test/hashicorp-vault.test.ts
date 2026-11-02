import { describe, expect, test } from "bun:test";
import { DEFAULT_PATH_PREFIX, hashicorpVault, validVaultPath } from "../src/providers/hashicorp-vault/index";
import { CANONICAL, fakeContext, fakeFetch, requestFor } from "./support";

const NOW = new Date("2026-11-02T10:00:00.000Z");
const ADDRESS = "https://vault.acme";
const PATH = `${DEFAULT_PATH_PREFIX}/${CANONICAL}`;
const loginThen = (route: Parameters<typeof fakeFetch>[0]): Parameters<typeof fakeFetch>[0] => (method, url, body) => (url.includes("/auth/") ? { status: 200, body: { auth: { client_token: "hvs.token" } } } : route(method, url, body));

const open = async (route: Parameters<typeof fakeFetch>[0], extra: Record<string, unknown> = {}, setup: Record<string, unknown> = { address: ADDRESS }, env: Record<string, string> = { VAULT_USERNAME: "np", VAULT_PASSWORD: "pw" }, readFile = async () => "jwt") => {
  const fake = fakeFetch(route);
  const provider = hashicorpVault({ clients: { fetch: fake.fetch, readFile }, env, now: () => NOW });
  const request = requestFor("hashicorp-vault", { ...extra, provider: { specification_slug: "hashicorp-vault", attributes: { setup } } });
  const { context } = fakeContext();
  return { session: await provider.open(request, context), request, calls: fake.calls };
};

describe("hashicorp-vault", () => {
  test("open validates the address, the namespace and the prefix, and logs in with userpass or the pod's token", async () => {
    await expect(open(() => undefined, {}, {})).rejects.toMatchObject({ code: "MISSING_ADDRESS" });
    await expect(open(() => undefined, {}, { address: ADDRESS, namespace: "../x" })).rejects.toMatchObject({ code: "INVALID_PATH" });
    await expect(open(() => undefined, {}, { address: ADDRESS }, {})).rejects.toMatchObject({ code: "MISSING_CREDENTIALS" });
    const userpass = await open(loginThen(() => undefined), {}, { address: ADDRESS, namespace: "/admin/ns/" });
    expect(userpass.calls[0]).toMatchObject({ method: "POST", url: `${ADDRESS}/v1/admin/ns/auth/userpass/login/np`, body: { password: "pw" } });
    const kubernetes = await open(loginThen(() => undefined), {}, { address: ADDRESS, auth_mode: "kubernetes", kubernetes_role: "np-agent" }, {});
    expect(kubernetes.calls[0]).toMatchObject({ url: `${ADDRESS}/v1/auth/kubernetes/login`, body: { role: "np-agent", jwt: "jwt" } });
    await expect(open(() => undefined, {}, { address: ADDRESS, auth_mode: "kubernetes" }, {})).rejects.toMatchObject({ code: "MISSING_ROLE" });
    await expect(open(() => undefined, {}, { address: ADDRESS, auth_mode: "ldap" })).rejects.toMatchObject({ code: "INVALID_AUTH_MODE" });
    await expect(open(() => ({ status: 400, body: { errors: ["invalid username or password"] } }))).rejects.toMatchObject({ code: "LOGIN_FAILED", message: expect.stringContaining("invalid username or password") });
    expect(validVaultPath("secret/data/np")).toBe(true);
    expect(validVaultPath("a b")).toBe(false);
  });

  test("store writes the envelope under the prefix with the token, and the handle is the full KV path with the version", async () => {
    const { session, request, calls } = await open(loginThen(() => ({ status: 200, body: { data: { version: 3 } } })));
    expect(await session.store(request)).toEqual({ external_id: `${PATH}#3`, metadata: { vault_path: PATH } });
    expect(calls[1]).toMatchObject({ method: "POST", url: `${ADDRESS}/v1/${PATH}`, headers: { "X-Vault-Token": "hvs.token" }, body: { data: { parameter_id: 42, value: "s3cr3t", stored_at: "2026-11-02T10:00:00Z", external_id: PATH } } });
    const refused = await open(loginThen(() => ({ status: 403, body: { errors: ["permission denied"] } })));
    await expect(refused.session.store(refused.request)).rejects.toMatchObject({ code: "STORE_FAILED", message: expect.stringContaining("HTTP 403") });
    const offline = await open(loginThen(() => undefined));
    await expect(offline.session.store(offline.request)).rejects.toMatchObject({ code: "VAULT_UNREACHABLE" });
  });

  test("retrieve reads the handle's path verbatim, at its version, under the namespace; 404 is NOT_FOUND", async () => {
    const { session, request, calls } = await open(loginThen(() => ({ status: 200, body: { data: { data: { value: "s3cr3t" } } } })), { external_id: `old/data/prefix/x-1#2` }, { address: ADDRESS, namespace: "admin/ns", path_prefix: "new/data/prefix" });
    expect(await session.retrieve(request)).toEqual({ value: "s3cr3t" });
    expect(calls[1]).toMatchObject({ method: "GET", url: `${ADDRESS}/v1/admin/ns/old/data/prefix/x-1?version=2` });
    const missing = await open(loginThen(() => ({ status: 404, body: { errors: [] } })), { external_id: PATH });
    await expect(missing.session.retrieve(missing.request)).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

  test("delete is idempotent on 404 and fails on anything else", async () => {
    const { session, request, calls } = await open(loginThen(() => ({ status: 204 })), { external_id: `${PATH}#3` });
    expect(await session.delete(request)).toEqual({ success: true });
    expect(calls[1]).toMatchObject({ method: "DELETE", url: `${ADDRESS}/v1/${PATH}` });
    const gone = await open(loginThen(() => ({ status: 404 })), { external_id: PATH });
    expect(await gone.session.delete(gone.request)).toEqual({ success: true });
    const refused = await open(loginThen(() => ({ status: 403, body: { errors: ["denied"] } })), { external_id: PATH });
    await expect(refused.session.delete(refused.request)).rejects.toMatchObject({ code: "DELETE_FAILED" });
  });
});
