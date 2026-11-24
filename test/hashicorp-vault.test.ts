import { describe, expect, test } from "bun:test";
import {
  authMountOf,
  DEFAULT_PATH_PREFIX,
  hashicorpVault,
  validVaultPath,
} from "../src/providers/hashicorp-vault/index";
import { CANONICAL, fakeContext, fakeFetch, requestFor } from "./support";

const NOW = new Date("2026-11-02T10:00:00.000Z");
const ADDRESS = "https://vault.acme";
const PATH = `${DEFAULT_PATH_PREFIX}/${CANONICAL}`;
const loginThen =
  (route: Parameters<typeof fakeFetch>[0]): Parameters<typeof fakeFetch>[0] =>
  (method, url, body) =>
    url.includes("/auth/") ? { status: 200, body: { auth: { client_token: "hvs.token" } } } : route(method, url, body);

const open = async (
  route: Parameters<typeof fakeFetch>[0],
  extra: Record<string, unknown> = {},
  setup: Record<string, unknown> = { address: ADDRESS },
  env: Record<string, string> = { VAULT_USERNAME: "np", VAULT_PASSWORD: "pw" },
  readFile = async () => "jwt",
) => {
  const fake = fakeFetch(route);
  const provider = hashicorpVault({ clients: { fetch: fake.fetch, readFile }, env, now: () => NOW });
  const request = requestFor("hashicorp-vault", {
    ...extra,
    provider: { specification_slug: "hashicorp-vault", attributes: { setup } },
  });
  const { context } = fakeContext();
  return { session: await provider.open(request, context), request, calls: fake.calls };
};

describe("hashicorp-vault", () => {
  test("open validates the address, the namespace and the prefix, and logs in with userpass or the pod's token", async () => {
    await expect(open(() => undefined, {}, {})).rejects.toMatchObject({ code: "MISSING_ADDRESS" });
    await expect(open(() => undefined, {}, { address: ADDRESS, namespace: "../x" })).rejects.toMatchObject({
      code: "INVALID_PATH",
    });
    await expect(open(() => undefined, {}, { address: ADDRESS }, {})).rejects.toMatchObject({
      code: "MISSING_CREDENTIALS",
    });
    const userpass = await open(
      loginThen(() => undefined),
      {},
      { address: ADDRESS, namespace: "/admin/ns/" },
    );
    expect(userpass.calls[0]).toMatchObject({
      method: "POST",
      url: `${ADDRESS}/v1/admin/ns/auth/userpass/login/np`,
      body: { password: "pw" },
    });
    const kubernetes = await open(
      loginThen(() => undefined),
      {},
      { address: ADDRESS, auth_mode: "kubernetes", kubernetes_role: "np-agent" },
      {},
    );
    expect(kubernetes.calls[0]).toMatchObject({
      url: `${ADDRESS}/v1/auth/kubernetes/login`,
      body: { role: "np-agent", jwt: "jwt" },
    });
    await expect(open(() => undefined, {}, { address: ADDRESS, auth_mode: "kubernetes" }, {})).rejects.toMatchObject({
      code: "MISSING_ROLE",
    });
    await expect(open(() => undefined, {}, { address: ADDRESS, auth_mode: "ldap" })).rejects.toMatchObject({
      code: "INVALID_AUTH_MODE",
    });
    await expect(
      open(() => ({ status: 400, body: { errors: ["invalid username or password"] } })),
    ).rejects.toMatchObject({ code: "LOGIN_FAILED", message: expect.stringContaining("invalid username or password") });
    await expect(open(() => ({ status: 403, body: {} }))).rejects.toMatchObject({
      code: "LOGIN_FAILED",
      message: expect.stringContaining("auth/userpass"),
    });
    expect(validVaultPath("secret/data/np")).toBe(true);
    expect(validVaultPath("a b")).toBe(false);
  });

  test("auth_path picks the login mount, from the attributes or VAULT_AUTH_PATH, under the namespace", async () => {
    const kubernetes = await open(
      loginThen(() => undefined),
      {},
      {
        address: ADDRESS,
        namespace: "admin",
        auth_mode: "kubernetes",
        kubernetes_role: "np-agent",
        auth_path: "/auth/kubernetes-aks-prod/",
      },
      {},
    );
    expect(kubernetes.calls[0]).toMatchObject({
      url: `${ADDRESS}/v1/admin/auth/kubernetes-aks-prod/login`,
      body: { role: "np-agent", jwt: "jwt" },
    });
    const userpass = await open(
      loginThen(() => undefined),
      {},
      { address: ADDRESS },
      { VAULT_USERNAME: "np", VAULT_PASSWORD: "pw", VAULT_AUTH_PATH: "team/userpass" },
    );
    expect(userpass.calls[0]).toMatchObject({ url: `${ADDRESS}/v1/auth/team/userpass/login/np` });
    await expect(
      open(() => ({ status: 400, body: { errors: [] } }), {}, { address: ADDRESS, auth_path: "kubernetes-aks-prod" }),
    ).rejects.toMatchObject({
      code: "LOGIN_FAILED",
      message: expect.stringContaining("auth/kubernetes-aks-prod"),
    });
  });

  test("the login logs its mount, and a failed one names it in the causes with the raw body capped", async () => {
    const fake = fakeFetch(() => ({ status: 403, body: "x".repeat(1000) }));
    const provider = hashicorpVault({ clients: { fetch: fake.fetch, readFile: async () => "jwt" }, env: {} });
    const request = requestFor("hashicorp-vault", {
      provider: {
        specification_slug: "hashicorp-vault",
        attributes: {
          setup: { address: ADDRESS, auth_mode: "kubernetes", kubernetes_role: "np-agent", auth_path: "k8s-prod" },
        },
      },
    });
    const { context, lines } = fakeContext();
    const failure = await provider.open(request, context).catch((error: Error) => error);
    expect(lines).toContain("info Vault kubernetes login via mount auth/k8s-prod");
    expect(failure).toMatchObject({ code: "LOGIN_FAILED" });
    const message = (failure as Error).message;
    expect(message).toContain("No kubernetes auth method is enabled at auth/k8s-prod");
    expect(message).toContain("The mount at auth/k8s-prod does not validate this cluster's tokens");
    expect(message).toContain("x".repeat(150));
    expect(message).not.toContain("x".repeat(201));
  });

  test("an invalid auth_path fails before any call, and a bad auth_mode is still reported as such", async () => {
    for (const authPath of ["auth/", "auth", "/", "a//b", "../x", "a/./b", ".hidden", "a b", "a?b"]) {
      const fake = fakeFetch(() => undefined);
      const provider = hashicorpVault({ clients: { fetch: fake.fetch, readFile: async () => "jwt" }, env: {} });
      const request = requestFor("hashicorp-vault", {
        provider: {
          specification_slug: "hashicorp-vault",
          attributes: { setup: { address: ADDRESS, auth_path: authPath } },
        },
      });
      await expect(provider.open(request, fakeContext().context)).rejects.toMatchObject({ code: "INVALID_PATH" });
      expect(fake.calls).toHaveLength(0);
    }
    expect(authMountOf("")).toBe("");
    expect(authMountOf("auth/kubernetes-x")).toBe("kubernetes-x");
    expect(authMountOf("team/k8s.v2")).toBe("team/k8s.v2");
    expect(authMountOf("auth/auth/x")).toBe("auth/x");
    await expect(
      open(() => undefined, {}, { address: ADDRESS, auth_mode: "ldap", auth_path: "kubernetes-x" }),
    ).rejects.toMatchObject({ code: "INVALID_AUTH_MODE" });
  });

  test("store writes the envelope under the prefix with the token, and the handle is the full KV path with the version", async () => {
    const { session, request, calls } = await open(loginThen(() => ({ status: 200, body: { data: { version: 3 } } })));
    expect(await session.store(request)).toEqual({ external_id: `${PATH}#3`, metadata: { vault_path: PATH } });
    expect(calls[1]).toMatchObject({
      method: "POST",
      url: `${ADDRESS}/v1/${PATH}`,
      headers: { "X-Vault-Token": "hvs.token" },
      body: { data: { parameter_id: 42, value: "s3cr3t", stored_at: "2026-11-02T10:00:00Z", external_id: PATH } },
    });
    const refused = await open(loginThen(() => ({ status: 403, body: { errors: ["permission denied"] } })));
    await expect(refused.session.store(refused.request)).rejects.toMatchObject({
      code: "STORE_FAILED",
      message: expect.stringContaining("HTTP 403"),
    });
    const offline = await open(loginThen(() => undefined));
    await expect(offline.session.store(offline.request)).rejects.toMatchObject({ code: "VAULT_UNREACHABLE" });
  });

  test("retrieve reads the handle's path verbatim, at its version, under the namespace; 404 is NOT_FOUND", async () => {
    const { session, request, calls } = await open(
      loginThen(() => ({ status: 200, body: { data: { data: { value: "s3cr3t" } } } })),
      { external_id: `old/data/prefix/x-1#2` },
      { address: ADDRESS, namespace: "admin/ns", path_prefix: "new/data/prefix" },
    );
    expect(await session.retrieve(request)).toEqual({ value: "s3cr3t" });
    expect(calls[1]).toMatchObject({ method: "GET", url: `${ADDRESS}/v1/admin/ns/old/data/prefix/x-1?version=2` });
    const missing = await open(
      loginThen(() => ({ status: 404, body: { errors: [] } })),
      { external_id: PATH },
    );
    await expect(missing.session.retrieve(missing.request)).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

  test("delete is idempotent on 404 and fails on anything else", async () => {
    const { session, request, calls } = await open(
      loginThen(() => ({ status: 204 })),
      { external_id: `${PATH}#3` },
    );
    expect(await session.delete(request)).toEqual({ success: true });
    expect(calls[1]).toMatchObject({ method: "DELETE", url: `${ADDRESS}/v1/${PATH}` });
    const gone = await open(
      loginThen(() => ({ status: 404 })),
      { external_id: PATH },
    );
    expect(await gone.session.delete(gone.request)).toEqual({ success: true });
    const refused = await open(
      loginThen(() => ({ status: 403, body: { errors: ["denied"] } })),
      { external_id: PATH },
    );
    await expect(refused.session.delete(refused.request)).rejects.toMatchObject({ code: "DELETE_FAILED" });
  });
});

describe("a batch of Vault secrets", () => {
  test("reads the values in parallel at their versions, and leaves out one Vault has not got", async () => {
    const route: Parameters<typeof fakeFetch>[0] = (method, url) =>
      url.includes("/b-2?")
        ? { status: 404, body: { errors: [] } }
        : { status: 200, body: { data: { data: { value: `value at ${url.split("/v1/")[1]}` } } } };
    const { session, calls } = await open(loginThen(route), { external_id: `${PATH}#1` });
    const handles = ["prefix/a-1#1", "prefix/b-2#1", "prefix/c-3"];
    const answer = await session.retrieveBatch!(
      handles.map((handle) => requestFor("hashicorp-vault", { external_id: handle })),
    );
    expect(answer.values.sort((left, right) => left.external_id.localeCompare(right.external_id))).toEqual([
      { external_id: "prefix/a-1#1", value: "value at prefix/a-1?version=1" },
      { external_id: "prefix/c-3", value: "value at prefix/c-3" },
    ]);
    expect(calls.filter((call) => call.method === "GET").length).toBe(3);
  });
});
