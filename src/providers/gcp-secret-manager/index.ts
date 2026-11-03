/**
 * Google Cloud Secret Manager. One secret per parameter, its id the canonical
 * path flattened to Secret Manager's charset under the configured prefix
 * (`<prefix>__organization-acme-1__account-…`, `/` as `__`, `=` as `-`), each
 * store a new version of it: addVersion, and the secret created first when
 * it is the parameter's first store. The handle carries the version number;
 * delete removes the secret, final, since Secret Manager has no soft delete.
 * The identity is the pod's Workload Identity through the metadata server,
 * or GCP_ACCESS_TOKEN outside GCP.
 */

import { GoogleAuth } from "google-auth-library";
import type { Context } from "@nullplatform/plugin";
import { handleOf, type ParameterRequest } from "../../context";
import { Failure } from "../../failure";
import { canonicalPath } from "../../naming";
import { DONE, retrieveEach, type Provider, type RetrievedBatch, type Session } from "../../provider";
import { settingOf } from "../../settings";

export const SLUG = "gcp-secret-manager";
export const API_URL = "https://secretmanager.googleapis.com/v1";
export const SECRET_ID_MAX_LENGTH = 255;

export interface SecretManagerClients {
  /** An access token for the Secret Manager API, the pod's identity. */
  token: () => Promise<string>;
  fetch: typeof fetch;
}

export interface SecretManagerOptions {
  clients?: SecretManagerClients;
  env?: Record<string, string | undefined>;
}

/** The canonical path as a secret id: `/` as `__` keeps the hierarchy readable, `=` as `-`, anything else outside the charset `-`. */
export const secretIdOf = (prefix: string, path: string): string =>
  `${prefix}__${path
    .replace(/\//g, "__")
    .replace(/=/g, "-")
    .replace(/[^A-Za-z0-9_-]/g, "-")}`;

/** A prefix Secret Manager accepts, without the `__` that separates the id's segments. */
export const validPrefix = (prefix: string): boolean => /^[A-Za-z0-9_-]+$/.test(prefix) && !prefix.includes("__");

interface Answer {
  status: number;
  body: Record<string, any>;
}

const labelValue = (value: string): string =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .slice(0, 63);

/** The labels a created secret carries: the NRN's ids and slugs, the owner and the parameter id, none of them overridable by the payload. */
export function labelsOf(request: ParameterRequest): Record<string, string> {
  const labels: Record<string, string> = {};
  for (const entity of ["organization", "account", "namespace", "application", "scope"]) {
    const id = request.entities[entity];
    const slug = request.entities[`${entity}_slug`];
    if (id) {
      labels[`${entity}_id`] = labelValue(id);
    }
    if (slug) {
      labels[entity] = labelValue(slug);
    }
  }
  labels.managed_by = "nullplatform";
  if (request.parameterId) {
    labels.parameter_id = labelValue(request.parameterId);
  }
  return labels;
}

class SecretManagerSession implements Session {
  constructor(
    private readonly clients: SecretManagerClients,
    private readonly projectId: string,
    private readonly prefix: string,
    private readonly replicaLocations: string[],
    private readonly context: Context,
  ) {}

  private async call(method: string, url: string, body?: unknown): Promise<Answer> {
    const headers: Record<string, string> = { Authorization: `Bearer ${await this.clients.token()}` };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    let response: Response;
    try {
      response = await this.clients.fetch(url, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(30_000),
      });
    } catch {
      return { status: 0, body: {} };
    }
    const text = await response.text();
    let parsed: Record<string, any> = {};
    try {
      parsed = text ? (JSON.parse(text) as Record<string, any>) : {};
    } catch {
      parsed = {};
    }
    return { status: response.status, body: parsed };
  }

  private underlying(answer: Answer): string {
    return answer.status === 0
      ? "could not connect to secretmanager.googleapis.com: no HTTP response (DNS or network egress)"
      : String(answer.body?.error?.message ?? "unknown error");
  }

  private get secretsUrl(): string {
    return `${API_URL}/projects/${this.projectId}/secrets`;
  }

  async store(request: ParameterRequest) {
    const path = canonicalPath(request);
    const secretId = secretIdOf(this.prefix, path);
    if (secretId.length > SECRET_ID_MAX_LENGTH) {
      throw new Failure("NAME_TOO_LONG", {
        what: `Secret id exceeds GCP Secret Manager's ${SECRET_ID_MAX_LENGTH}-character limit (got ${secretId.length})`,
        causes: [`The id is the entity path (slugs + ids + dimensions + parameter): ${secretId}`],
        fixes: [
          "Shorten the parameter name, or reduce the number of dimensions",
          "Or use a shorter name_prefix in the provider config",
        ],
      });
    }
    const versionBody = { payload: { data: Buffer.from(request.value, "utf8").toString("base64") } };
    let added = await this.call("POST", `${this.secretsUrl}/${secretId}:addVersion`, versionBody);
    if (added.status === 404) {
      this.context.log.debug(`Secret '${secretId}' does not exist yet; creating it`);
      const replication =
        this.replicaLocations.length > 0
          ? { userManaged: { replicas: this.replicaLocations.map((location) => ({ location })) } }
          : { automatic: {} };
      const created = await this.call("POST", `${this.secretsUrl}?secretId=${encodeURIComponent(secretId)}`, {
        replication,
        labels: labelsOf(request),
      });
      // 409: a concurrent store created it between the two calls, which is fine.
      if (created.status !== 200 && created.status !== 409) {
        throw new Failure("STORE_FAILED", {
          what: `Failed to create secret '${secretId}' in GCP project '${this.projectId}' (HTTP ${created.status})`,
          causes: [
            "The agent identity lacks secretmanager.secrets.create on the project",
            "A replica location in the provider config is not a valid region",
          ],
          fixes: ["Grant the agent principal access as in docs/iam-policy.md"],
          underlying: this.underlying(created),
        });
      }
      added = await this.call("POST", `${this.secretsUrl}/${secretId}:addVersion`, versionBody);
    }
    if (added.status !== 200) {
      throw new Failure("STORE_FAILED", {
        what: `Failed to add a version to secret '${secretId}' in GCP project '${this.projectId}' (HTTP ${added.status})`,
        causes: [
          "The agent identity lacks secretmanager.versions.add on the secret",
          `The Secret Manager API is not enabled on '${this.projectId}'`,
          "The value exceeds Secret Manager's 64 KiB payload limit",
          "The access token expired",
        ],
        fixes: [
          "Grant the agent principal access as in docs/iam-policy.md",
          `Enable the API: gcloud services enable secretmanager.googleapis.com --project ${this.projectId}`,
        ],
        underlying: this.underlying(added),
      });
    }
    const versionName = String(added.body.name ?? "");
    return {
      external_id: handleOf(path, versionName.split("/").pop() ?? ""),
      metadata: { secret_id: secretId, version_name: versionName, project_id: this.projectId },
    };
  }

  async retrieve(request: ParameterRequest) {
    const secretId = secretIdOf(this.prefix, request.externalId.path);
    const version = request.externalId.version || "latest";
    // The version is a URL segment: only a version number or `latest` may address it.
    if (!/^\d+$/.test(version) && version !== "latest") {
      throw new Failure("INVALID_VERSION", {
        what: `Invalid secret version '${version}' in external_id for '${secretId}'`,
        causes: ["The external_id version suffix (after '#') was altered or is not from this provider"],
        fixes: [
          "The suffix must be a Secret Manager version number (e.g. '#3') or 'latest'",
          "Re-store the parameter value to get a fresh external_id",
        ],
      });
    }
    const answer = await this.call("GET", `${this.secretsUrl}/${secretId}/versions/${version}:access`);
    if (answer.status === 200) {
      const data = answer.body?.payload?.data;
      if (typeof data !== "string") {
        throw new Failure("RETRIEVE_FAILED", {
          what: `Secret Manager returned no payload for '${secretId}' (version ${version})`,
          causes: ["The access response is malformed or was truncated by a proxy"],
          fixes: [`Verify: gcloud secrets versions access ${version} --secret ${secretId} --project ${this.projectId}`],
        });
      }
      return { value: Buffer.from(data, "base64").toString("utf8") };
    }
    if (answer.status === 404) {
      throw new Failure("NOT_FOUND", {
        what: `Secret '${secretId}' (version ${version}) not found in GCP project '${this.projectId}'`,
        causes: [
          "The secret was manually deleted from Secret Manager",
          "The external_id is stale",
          ...(request.externalId.version
            ? [`Requested version '${request.externalId.version}' does not exist on the secret`]
            : []),
        ],
        fixes: [
          `Verify: gcloud secrets versions list ${secretId} --project ${this.projectId}`,
          "If genuinely missing, the parameter value needs to be re-stored",
        ],
      });
    }
    throw new Failure("RETRIEVE_FAILED", {
      what: `Failed to retrieve secret '${secretId}' (version ${version}) from GCP project '${this.projectId}' (HTTP ${answer.status})`,
      causes: [
        "The agent identity lacks secretmanager.versions.access on the secret",
        "The requested version is disabled or destroyed (HTTP 400 FAILED_PRECONDITION)",
        "The access token expired",
      ],
      fixes: [
        "Grant the agent principal access as in docs/iam-policy.md",
        `Check the version state: gcloud secrets versions describe ${version} --secret ${secretId} --project ${this.projectId}`,
      ],
      underlying: this.underlying(answer),
    });
  }

  /** The backend has no batch read: a batch is its values read in parallel. */
  retrieveBatch(requests: ParameterRequest[]): Promise<RetrievedBatch> {
    return retrieveEach(this, requests, this.context.log);
  }

  async delete(request: ParameterRequest) {
    const secretId = secretIdOf(this.prefix, request.externalId.path);
    const answer = await this.call("DELETE", `${this.secretsUrl}/${secretId}`);
    if (answer.status === 200) {
      return DONE;
    }
    if (answer.status === 404) {
      this.context.log.debug(`Secret '${secretId}' does not exist, treating delete as idempotent success`);
      return DONE;
    }
    throw new Failure("DELETE_FAILED", {
      what: `Failed to delete secret '${secretId}' from GCP project '${this.projectId}' (HTTP ${answer.status})`,
      causes: ["The agent identity lacks secretmanager.secrets.delete on the secret", "The access token expired"],
      fixes: ["Grant the agent principal access as in docs/iam-policy.md"],
      underlying: this.underlying(answer),
    });
  }
}

/** The pod's identity: the token the metadata server gives the Workload Identity, or the one given outright. */
export function workloadToken(env: Record<string, string | undefined>): () => Promise<string> {
  const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });
  return async () => {
    if (env.GCP_ACCESS_TOKEN) {
      return env.GCP_ACCESS_TOKEN;
    }
    let token: string | null | undefined;
    try {
      token = await auth.getAccessToken();
    } catch (error) {
      throw new Failure("NO_TOKEN", {
        what: "Could not obtain a GCP access token",
        causes: [
          "The agent is not running on GKE/GCE, so there is no metadata server",
          "Workload Identity is not enabled on the cluster or the node pool",
          "The agent's Kubernetes service account has no IAM access to Secret Manager",
        ],
        fixes: [
          "Run the agent on GKE with Workload Identity and grant its KSA principal access (see docs/iam-policy.md)",
          "Outside GCP, export GCP_ACCESS_TOKEN in the agent environment",
        ],
        underlying: error instanceof Error ? error.message : String(error),
      });
    }
    if (!token) {
      throw new Failure("NO_TOKEN", {
        what: "The metadata server returned no access_token",
        fixes: ["Confirm Workload Identity is enabled on the node pool (GKE_METADATA mode)"],
      });
    }
    return token;
  };
}

export function gcpSecretManager(options: SecretManagerOptions = {}): Provider {
  const env = options.env ?? process.env;
  const clients = options.clients ?? { token: workloadToken(env), fetch };
  return {
    slug: SLUG,
    async open(request, context) {
      const projectId = settingOf(request.provider.attributes, env, {
        attribute: "setup.project_id",
        variable: "GCP_SECRET_MANAGER_PROJECT_ID",
      });
      if (projectId === "") {
        throw new Failure("MISSING_PROJECT", {
          what: "GCP Secret Manager project not configured",
          causes: [
            "GCP_SECRET_MANAGER_PROJECT_ID env var is not set",
            ".setup.project_id is missing in the gcp-secret-manager provider config",
          ],
          fixes: [
            "Set GCP_SECRET_MANAGER_PROJECT_ID=<your-project-id>",
            "Or set .setup.project_id in the provider config attributes",
          ],
        });
      }
      const prefix = settingOf(request.provider.attributes, env, {
        attribute: "setup.name_prefix",
        variable: "GCP_SECRET_MANAGER_NAME_PREFIX",
        fallback: "nullplatform",
      });
      if (!validPrefix(prefix)) {
        throw new Failure("INVALID_PREFIX", {
          what: `Invalid GCP Secret Manager name prefix '${prefix}'`,
          causes: ["The prefix contains characters Secret Manager does not allow in secret ids"],
          fixes: ["Use only letters, digits, '_' and '-', without '__' (default: nullplatform)"],
        });
      }
      const replicaLocations = settingOf(request.provider.attributes, env, {
        attribute: "setup.replica_locations",
        variable: "GCP_SECRET_MANAGER_REPLICA_LOCATIONS",
      })
        .split(",")
        .map((location) => location.trim())
        .filter(Boolean);
      return new SecretManagerSession(clients, projectId, prefix, replicaLocations, context);
    },
  };
}
