/**
 * HashiCorp Vault, KV v2. One secret per parameter at `<path prefix>/<canonical
 * path>` (the prefix `secret/data/nullplatform` unless configured), each store
 * a new version of it, which KV v2 keeps. The handle is the full KV path with
 * the version number, so a later change of prefix leaves old handles valid; an
 * Enterprise namespace is not in it, it prefixes every request's URL. The
 * worker logs in with a username and password from the environment, or with
 * the pod's service account token, and uses the client token it gets.
 */

import type { Context } from "@nullplatform/plugin";
import { handleOf, type ParameterRequest } from "../../context";
import { Failure } from "../../failure";
import { parsedObject, text, valueAt, type JsonObject } from "../../json";
import { canonicalPath } from "../../naming";
import { DONE, retrieveEach, type Provider, type RetrievedBatch, type Session } from "../../provider";
import { settingOf } from "../../settings";

export const SLUG = "hashicorp-vault";
export const DEFAULT_PATH_PREFIX = "secret/data/nullplatform";
export const DEFAULT_JWT_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token";
export const UPGRADE_WRITES = 5;
export const UPGRADE_RETRY_MS = 1000;

export interface VaultClients {
  fetch: typeof fetch;
  /** Reads the pod's service account token, for the kubernetes auth mode. */
  readFile: (path: string) => Promise<string>;
}

export interface VaultOptions {
  clients?: VaultClients;
  env?: Record<string, string | undefined>;
  now?: () => Date;
  sleep?: (ms: number) => Promise<void>;
}

interface Answer {
  status: number;
  body: JsonObject;
  text: string;
}

/** A path Vault accepts as configuration: its own characters, no `..` segment that could rewrite a request. */
export const validVaultPath = (value: string): boolean =>
  value === "" || (!value.includes("..") && /^[A-Za-z0-9._/-]+$/.test(value));

export const mountOf = (pathPrefix: string): string | undefined => {
  const prefix = `${pathPrefix}/`;
  const index = prefix.indexOf("/data/");
  return index > 0 ? prefix.slice(0, index) : undefined;
};

const isMissingRoute = (answer: Answer): boolean =>
  answer.status === 404 && answer.text.includes("no handler for route");

const isUpgrading = (answer: Answer): boolean => answer.text.includes("Upgrading from non-versioned to versioned data");

const trimSlashes = (value: string): string => value.replace(/^\/+/, "").replace(/\/+$/, "");

/** The stamp the bash wrote: RFC3339 at second precision. */
const stampOf = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, "Z");

export class VaultApi {
  constructor(
    private readonly fetchFn: typeof fetch,
    readonly address: string,
    readonly namespace: string,
  ) {}

  /** The URL of a path, the namespace first when there is one. */
  url(path: string, query = ""): string {
    return `${this.address}/v1/${this.namespace ? `${this.namespace}/` : ""}${path}${query}`;
  }

  async call(
    method: string,
    path: string,
    options: { token?: string; body?: unknown; query?: string } = {},
  ): Promise<Answer> {
    const headers: Record<string, string> = {};
    if (options.token) {
      headers["X-Vault-Token"] = options.token;
    }
    let response: Response;
    try {
      response = await this.fetchFn(this.url(path, options.query), {
        method,
        headers,
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        signal: AbortSignal.timeout(30_000),
      });
    } catch {
      return { status: 0, body: {}, text: "" };
    }
    const raw = await response.text();
    return { status: response.status, body: parsedObject(raw), text: raw };
  }
}

class VaultSession implements Session {
  constructor(
    private readonly api: VaultApi,
    private readonly token: string,
    private readonly pathPrefix: string,
    private readonly now: () => Date,
    private readonly context: Context,
    private readonly createMount: boolean,
    private readonly sleep: (ms: number) => Promise<void>,
  ) {}

  private networkFailure(what: string): Failure {
    return new Failure("VAULT_UNREACHABLE", {
      what: `${what} at ${this.api.address}`,
      causes: [`Network unreachable to ${this.api.address} (DNS / firewall / TLS)`],
      fixes: [`Test connectivity: curl -s ${this.api.address}/v1/sys/health`],
    });
  }

  async store(request: ParameterRequest) {
    // The prefix is part of the handle: retrieve and delete use it verbatim, whatever the prefix is then.
    const path = `${this.pathPrefix}/${canonicalPath(request)}`;
    const body = {
      data: {
        parameter_id: request.parameterId ? Number(request.parameterId) : null,
        value: request.value,
        stored_at: stampOf(this.now()),
        external_id: path,
      },
    };
    let answer = await this.write(path, body);
    if (this.createMount && isMissingRoute(answer)) {
      await this.createKvMount(this.mountToCreate());
      answer = await this.write(path, body);
      for (let writes = 1; writes < UPGRADE_WRITES && isUpgrading(answer); writes++) {
        await this.sleep(UPGRADE_RETRY_MS);
        answer = await this.write(path, body);
      }
    }
    if (answer.status < 200 || answer.status >= 300) {
      throw this.storeFailure(path, answer);
    }
    return { external_id: handleOf(path, text(valueAt(answer.body, "data.version"))), metadata: { vault_path: path } };
  }

  private async write(path: string, body: unknown): Promise<Answer> {
    const answer = await this.api.call("POST", path, { token: this.token, body });
    if (answer.status === 0) {
      throw this.networkFailure("Network error storing parameter in Vault");
    }
    return answer;
  }

  private get namespaceLabel(): string {
    return this.api.namespace || "<root>";
  }

  private enableCommand(mount: string): string {
    const namespace = this.api.namespace ? `-namespace=${this.api.namespace} ` : "";
    return `vault secrets enable ${namespace}-path=${mount} -version=2 kv`;
  }

  private mountToCreate(): string {
    const mount = mountOf(this.pathPrefix);
    if (mount === undefined) {
      throw new Failure("INVALID_PATH", {
        what: `Cannot derive the KV v2 mount from path_prefix '${this.pathPrefix}'`,
        causes: ["path_prefix has no /data/ segment, so the mount name is ambiguous"],
        fixes: ["Set .setup.path_prefix to the full <mount>/data/<subpath> (e.g. secret/data/nullplatform)"],
      });
    }
    return mount;
  }

  private async createKvMount(mount: string): Promise<void> {
    const answer = await this.api.call("POST", `sys/mounts/${mount}`, {
      token: this.token,
      body: { type: "kv", options: { version: "2" } },
    });
    if (answer.status === 0) {
      throw this.networkFailure("Network error creating the KV v2 mount in Vault");
    }
    if (answer.status >= 200 && answer.status < 300) {
      this.context.log.info(`✅ Created KV v2 mount '${mount}' in namespace ${this.namespaceLabel}`);
      return;
    }
    if (answer.status === 400 && answer.text.includes("path is already in use")) {
      return;
    }
    throw new Failure("MOUNT_FAILED", {
      what: `Failed to create KV v2 mount '${mount}' (HTTP ${answer.status})`,
      causes: [`The token lacks create/update on sys/mounts/${mount} in namespace ${this.namespaceLabel} (403)`],
      fixes: [
        `Grant the agent policy: path "sys/mounts/${mount}" { capabilities = ["create", "update"] }`,
        `Or enable it once and set .setup.create_mount=false: ${this.enableCommand(mount)}`,
      ],
      underlying: answer.text,
    });
  }

  private storeFailure(path: string, answer: Answer): Failure {
    const what = `Vault write failed with HTTP ${answer.status} at ${path}`;
    const mount = isMissingRoute(answer) ? mountOf(this.pathPrefix) : undefined;
    if (mount !== undefined) {
      return new Failure("STORE_FAILED", {
        what,
        causes: [
          `KV v2 mount '${mount}' does not exist in namespace ${this.namespaceLabel} (or path_prefix names the wrong mount)`,
        ],
        fixes: [
          `Set .setup.create_mount=true (the default) to let the agent create it (the token needs create/update on sys/mounts/${mount})`,
          `Or enable it: ${this.enableCommand(mount)}`,
          `List existing mounts: curl -s -H "X-Vault-Token: $VAULT_TOKEN" ${this.api.url("sys/internal/ui/mounts")}`,
        ],
        underlying: answer.text,
      });
    }
    if (isUpgrading(answer)) {
      return new Failure("STORE_FAILED", {
        what,
        causes: ["The KV v2 mount was just created and is still initializing"],
        fixes: ["Retry the operation in a few seconds"],
        underlying: answer.text,
      });
    }
    return new Failure("STORE_FAILED", {
      what,
      causes: [
        `The token lacks write permission on ${path} (403)`,
        `KV v2 mount in path_prefix (${this.pathPrefix}) does not exist (404)`,
        `Wrong Vault namespace (${this.namespaceLabel}): check .setup.namespace`,
        "path_prefix must be the full <mount>/data/<subpath> (404 if the mount/data segment is wrong)",
      ],
      fixes: [
        `Verify token: curl -s -H "X-Vault-Token: $VAULT_TOKEN" ${this.api.address}/v1/auth/token/lookup-self`,
        `Confirm the mount: curl -s -H "X-Vault-Token: $VAULT_TOKEN" ${this.api.url("sys/mounts")}`,
      ],
      underlying: answer.text,
    });
  }

  async retrieve(request: ParameterRequest) {
    const path = request.externalId.path;
    const version = request.externalId.version;
    const answer = await this.api.call("GET", path, {
      token: this.token,
      query: version ? `?version=${encodeURIComponent(version)}` : "",
    });
    if (answer.status === 0) {
      throw this.networkFailure("Network error calling Vault");
    }
    if (answer.status >= 200 && answer.status < 300) {
      return { value: text(valueAt(answer.body, "data.data.value")) };
    }
    if (answer.status === 404) {
      throw new Failure("NOT_FOUND", {
        what: `Secret at ${path} not found in Vault`,
        causes: [
          "The secret was manually deleted from Vault",
          "The external_id is stale",
          ...(version ? [`Requested version '${version}' was destroyed via Vault's metadata API`] : []),
        ],
        fixes: [
          `Verify: curl -s -H "X-Vault-Token: $VAULT_TOKEN" ${this.api.url(path)}`,
          "If genuinely missing, the parameter value needs to be re-stored",
        ],
      });
    }
    throw new Failure("RETRIEVE_FAILED", {
      what: `Vault GET failed with HTTP ${answer.status} at ${path}`,
      causes: ["The token lacks read permission (403)", "Server-side error (5xx)"],
      fixes: [`Verify token: curl -s -H "X-Vault-Token: $VAULT_TOKEN" ${this.api.address}/v1/auth/token/lookup-self`],
      underlying: answer.text,
    });
  }

  /** The backend has no batch read: a batch is its values read in parallel. */
  retrieveBatch(requests: ParameterRequest[]): Promise<RetrievedBatch> {
    return retrieveEach(this, requests, this.context.log);
  }

  async delete(request: ParameterRequest) {
    const path = request.externalId.path;
    const answer = await this.api.call("DELETE", path, { token: this.token });
    if (answer.status === 0) {
      throw this.networkFailure("Network error calling Vault");
    }
    if (answer.status === 404) {
      this.context.log.debug(`Secret at ${path} does not exist, treating delete as success`);
      return DONE;
    }
    if (answer.status < 200 || answer.status >= 300) {
      throw new Failure("DELETE_FAILED", {
        what: `Vault DELETE failed with HTTP ${answer.status} at ${path}`,
        causes: ["The token lacks delete permission at this path (403)", "Server-side error (5xx): check Vault logs"],
        fixes: [`Verify token: curl -s -H "X-Vault-Token: $VAULT_TOKEN" ${this.api.address}/v1/auth/token/lookup-self`],
        underlying: answer.text,
      });
    }
    return DONE;
  }
}

/** What a login needs besides the API: the provider's attributes, the environment the credentials are in, and the reader of the pod's token. */
export interface LoginOptions {
  attributes: Record<string, unknown>;
  env: Record<string, string | undefined>;
  clients: VaultClients;
}

/** Logs in as the configuration says and returns the client token. */
export async function login(api: VaultApi, mode: string, options: LoginOptions): Promise<string> {
  const { attributes, env, clients } = options;
  let path: string;
  let body: Record<string, string>;
  if (mode === "userpass") {
    const username = env.VAULT_USERNAME ?? "";
    const password = env.VAULT_PASSWORD ?? "";
    if (username === "") {
      throw new Failure("MISSING_CREDENTIALS", {
        what: "Vault username not configured",
        causes: ["VAULT_USERNAME env var is not set in the agent runtime"],
        fixes: ["Set VAULT_USERNAME=<your-user> in the agent environment"],
      });
    }
    if (password === "") {
      throw new Failure("MISSING_CREDENTIALS", {
        what: "Vault password not configured",
        causes: ["VAULT_PASSWORD env var is not set in the agent runtime"],
        fixes: [
          "Set VAULT_PASSWORD=<your-password> in the agent environment",
          "The password is sensitive: set via env, never via provider config",
        ],
      });
    }
    path = `auth/userpass/login/${encodeURIComponent(username)}`;
    body = { password };
  } else if (mode === "kubernetes") {
    const role = settingOf(attributes, env, { attribute: "setup.kubernetes_role", variable: "VAULT_K8S_ROLE" });
    const jwtPath = env.VAULT_K8S_JWT_PATH || DEFAULT_JWT_PATH;
    if (role === "") {
      throw new Failure("MISSING_ROLE", {
        what: "Vault Kubernetes role not configured",
        causes: [
          ".setup.kubernetes_role is missing in the provider config",
          "VAULT_K8S_ROLE env var is not set in the agent runtime",
        ],
        fixes: [
          "Set .setup.kubernetes_role to the Vault role bound to the agent's ServiceAccount",
          "See the provider README for the required Vault + cluster setup",
        ],
      });
    }
    let jwt: string;
    try {
      jwt = await clients.readFile(jwtPath);
    } catch {
      throw new Failure("MISSING_TOKEN", {
        what: `Kubernetes ServiceAccount token not readable at ${jwtPath}`,
        causes: [
          "The agent pod has automountServiceAccountToken disabled",
          "A custom projected-token path is used but VAULT_K8S_JWT_PATH is not set",
        ],
        fixes: [
          "Ensure the pod mounts its ServiceAccount token",
          "Or set VAULT_K8S_JWT_PATH to the projected token file",
        ],
      });
    }
    path = "auth/kubernetes/login";
    body = { role, jwt: jwt.trim() };
  } else {
    throw new Failure("INVALID_AUTH_MODE", {
      what: `Unknown Vault authentication mode '${mode}'`,
      causes: [".setup.auth_mode (or VAULT_AUTH_MODE) has an unsupported value"],
      fixes: ["Set auth_mode to one of: userpass, kubernetes"],
    });
  }
  const answer = await api.call("POST", path, { body });
  if (answer.status === 0) {
    throw new Failure("VAULT_UNREACHABLE", {
      what: `Failed to authenticate to Vault at ${api.address}`,
      causes: [`Network unreachable to ${api.address}`, "TLS handshake failure"],
      fixes: [`Test connectivity: curl -s ${api.address}/v1/sys/health`],
    });
  }
  const token = text(valueAt(answer.body, "auth.client_token"));
  if (token === "") {
    const errors = Array.isArray(answer.body.errors) ? answer.body.errors.join("; ") : "unknown error";
    throw new Failure("LOGIN_FAILED", {
      what: `Vault ${mode} login did not return a token`,
      causes:
        mode === "userpass"
          ? [
              "Wrong VAULT_USERNAME / VAULT_PASSWORD",
              "The userpass auth method is not enabled (vault auth enable userpass)",
            ]
          : [
              `The Vault role does not exist or does not bind this pod's ServiceAccount`,
              "The kubernetes auth method is not enabled or configured (vault auth enable kubernetes)",
            ],
      fixes: ["See the provider README for the required Vault + cluster setup"],
      underlying: `Vault error: ${errors}`,
    });
  }
  return token;
}

export function hashicorpVault(options: VaultOptions = {}): Provider {
  const clients = options.clients ?? { fetch, readFile: (path: string) => Bun.file(path).text() };
  const env = options.env ?? process.env;
  const now = options.now ?? (() => new Date());
  const sleep = options.sleep ?? ((ms: number) => Bun.sleep(ms));
  return {
    slug: SLUG,
    async open(request, context) {
      const { attributes } = request.provider;
      const address = settingOf(attributes, env, { attribute: "setup.address", variable: "VAULT_ADDR" });
      const mode = settingOf(attributes, env, {
        attribute: "setup.auth_mode",
        variable: "VAULT_AUTH_MODE",
        fallback: "userpass",
      });
      const namespace = trimSlashes(
        settingOf(attributes, env, { attribute: "setup.namespace", variable: "VAULT_NAMESPACE" }),
      );
      const pathPrefix = settingOf(attributes, env, {
        attribute: "setup.path_prefix",
        variable: "VAULT_PATH_PREFIX",
        fallback: DEFAULT_PATH_PREFIX,
      }).replace(/\/+$/, "");
      const createMount = settingOf(attributes, env, {
        attribute: "setup.create_mount",
        variable: "VAULT_CREATE_MOUNT",
        fallback: "true",
      });
      for (const [name, value] of [
        ["namespace", namespace],
        ["path_prefix", pathPrefix],
      ] as const) {
        if (!validVaultPath(value)) {
          throw new Failure("INVALID_PATH", {
            what: `Invalid Vault ${name}: '${value}'`,
            causes: [`.setup.${name} contains characters outside [A-Za-z0-9._/-] or a '..' segment`],
            fixes: ["Use only letters, digits, '.', '_', '-' and '/' path separators"],
          });
        }
      }
      if (createMount !== "true" && createMount !== "false") {
        throw new Failure("INVALID_CREATE_MOUNT", {
          what: `Invalid Vault create_mount: '${createMount}'`,
          causes: [".setup.create_mount or VAULT_CREATE_MOUNT is not a boolean"],
          fixes: ["Set it to true or false"],
        });
      }
      if (address === "") {
        throw new Failure("MISSING_ADDRESS", {
          what: "Vault address not configured",
          causes: [
            "VAULT_ADDR env var is not set in the workflow runtime",
            ".address is missing in the hashicorp-vault provider config",
          ],
          fixes: ["Set VAULT_ADDR=https://your-vault-host", "Or set .address in the provider config attributes"],
        });
      }
      const api = new VaultApi(clients.fetch, address.replace(/\/+$/, ""), namespace);
      const token = await login(api, mode, { attributes, env, clients });
      return new VaultSession(api, token, pathPrefix, now, context, createMount === "true", sleep);
    },
  };
}
