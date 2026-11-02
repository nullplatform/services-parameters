/**
 * AWS Secrets Manager. One secret per parameter under `nullplatform/<canonical
 * path>`, each store a new version of it (CreateSecret the first time,
 * PutSecretValue after), so the history stays inside one secret and costs one.
 * A batch reads up to 20 secrets per BatchGetSecretValue, which answers the
 * current version of each: a handle naming another version, or a secret the
 * batch could not read, is read on its own; one that still fails is left out,
 * and the platform retrieves it one by one.
 * The handle carries the VersionId AWS returns; retrieve reads that version,
 * delete removes the secret with every version at once.
 */

import { BatchGetSecretValueCommand, CreateSecretCommand, DeleteSecretCommand, GetSecretValueCommand, PutSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import type { Context } from "@nullplatform/plugin";
import { assumedRolesOf, clientOptions, realAwsClients, type AwsClients } from "../../aws/clients";
import { awsAccess, type AwsAccess, type RoleSelection, type Sender } from "../../aws/role";
import { handleOf, type ParameterRequest } from "../../context";
import { Failure, messageOf } from "../../failure";
import { canonicalPath } from "../../naming";
import { chunks, DONE, retrieveEach, type Provider, type RetrievedBatch, type Session } from "../../provider";
import { settingOf } from "../../settings";

export const SLUG = "aws-secrets-manager";
export const NAME_PREFIX = "nullplatform/";

const ROLE: RoleSelection = { selector: "secret_manager", overrideVariable: "SECRET_MANAGER_ASSUME_ROLE_ARN", defaultVariable: "SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT", sessionPrefix: "np-secret-manager" };

export interface SecretsManagerClients extends AwsClients {
  secrets: (access: AwsAccess) => Sender;
}

export interface SecretsManagerOptions {
  clients?: SecretsManagerClients;
  env?: Record<string, string | undefined>;
  now?: () => Date;
}

const errorName = (error: unknown): string => (error instanceof Error ? error.name : "");

/** The envelope a secret holds, as the bash wrote it. */
/** How many secrets one BatchGetSecretValue reads. */
export const BATCH_SIZE = 20;

interface BatchAnswer {
  SecretValues?: Array<{ Name?: string; VersionId?: string; SecretString?: string }>;
  Errors?: Array<{ SecretId?: string; ErrorCode?: string; Message?: string }>;
}

export const envelopeOf = (request: ParameterRequest, path: string, storedAt: Date): string => JSON.stringify({ parameter_id: request.parameterId ? Number(request.parameterId) : null, value: request.value, stored_at: storedAt.toISOString().replace(/\.\d{3}Z$/, "Z"), external_id: path });

class SecretsManagerSession implements Session {
  constructor(
    private readonly secrets: Sender,
    private readonly region: string,
    private readonly kmsKeyId: string,
    private readonly now: () => Date,
    private readonly context: Context,
  ) {}

  async store(request: ParameterRequest) {
    const path = canonicalPath(request);
    const name = `${NAME_PREFIX}${path}`;
    const secretString = envelopeOf(request, path, this.now());
    let result: { ARN?: string; VersionId?: string };
    try {
      result = await this.secrets.send(new CreateSecretCommand({ Name: name, SecretString: secretString, ...(this.kmsKeyId ? { KmsKeyId: this.kmsKeyId } : {}) }));
    } catch (error) {
      if (errorName(error) !== "ResourceExistsException") {
        throw new Failure("STORE_FAILED", { what: "Failed to store parameter in AWS Secrets Manager", causes: ["IAM principal lacks secretsmanager:CreateSecret on this resource", `Region '${this.region}' unreachable or wrong`], fixes: [`Verify identity: aws sts get-caller-identity --region ${this.region}`], underlying: messageOf(error) });
      }
      this.context.log.debug(`Secret '${name}' exists; adding new version (history preserved by AWS SM)`);
      try {
        result = await this.secrets.send(new PutSecretValueCommand({ SecretId: name, SecretString: secretString }));
      } catch (again) {
        throw new Failure("STORE_FAILED", { what: `Failed to add new version to secret '${name}'`, causes: ["IAM principal lacks secretsmanager:PutSecretValue on this resource", "Secret is in a deletion-pending state"], fixes: [`Verify identity: aws sts get-caller-identity --region ${this.region}`], underlying: messageOf(again) });
      }
    }
    return { external_id: handleOf(path, result.VersionId ?? ""), metadata: { secret_arn: result.ARN ?? "", secret_name: name, region: this.region } };
  }

  async retrieve(request: ParameterRequest) {
    const name = `${NAME_PREFIX}${request.externalId.path}`;
    const version = request.externalId.version;
    let answer: { SecretString?: string };
    try {
      answer = await this.secrets.send(new GetSecretValueCommand({ SecretId: name, ...(version ? { VersionId: version } : {}) }));
    } catch (error) {
      if (errorName(error) === "ResourceNotFoundException") {
        throw new Failure("NOT_FOUND", { what: `Secret '${name}' not found in AWS Secrets Manager`, causes: ["The secret was manually deleted from AWS", ...(version ? [`Requested version '${version}' was pruned (AWS SM auto-removes oldest unlabeled versions past 100)`] : [])], fixes: [`Verify the secret exists: aws secretsmanager describe-secret --secret-id ${name}`, "If genuinely missing, the parameter value needs to be re-stored"] });
      }
      throw new Failure("RETRIEVE_FAILED", { what: `Failed to retrieve secret '${name}' from AWS Secrets Manager`, causes: ["IAM principal lacks secretsmanager:GetSecretValue", "KMS key permission missing (kms:Decrypt) for CMK-encrypted secrets", `Region '${this.region}' unreachable`, ...(version ? [`Requested version '${version}' does not exist for this secret`] : [])], fixes: [`Verify identity: aws sts get-caller-identity --region ${this.region}`], underlying: messageOf(error) });
    }
    return { value: valueOf(answer.SecretString ?? "") };
  }

  async retrieveBatch(requests: ParameterRequest[]): Promise<RetrievedBatch> {
    const byName = new Map(requests.map((request) => [`${NAME_PREFIX}${request.externalId.path}`, request]));
    const values: RetrievedBatch["values"] = [];
    const alone: ParameterRequest[] = [];
    await Promise.all(
      chunks([...byName.keys()], BATCH_SIZE).map(async (names) => {
        let answer: BatchAnswer;
        try {
          answer = await this.secrets.send(new BatchGetSecretValueCommand({ SecretIdList: names }));
        } catch (error) {
          this.context.log.warn(`batch read of ${names.length} secrets failed, reading them one by one: ${messageOf(error)}`);
          alone.push(...names.map((name) => byName.get(name) as ParameterRequest));
          return;
        }
        const read = new Set<string>();
        for (const secret of answer.SecretValues ?? []) {
          const request = secret.Name === undefined ? undefined : byName.get(secret.Name);
          if (!request) {
            continue;
          }
          read.add(secret.Name as string);
          if (request.externalId.version && secret.VersionId !== request.externalId.version) {
            alone.push(request);
            continue;
          }
          values.push({ external_id: handleOf(request.externalId.path, request.externalId.version), value: valueOf(secret.SecretString ?? "") });
        }
        alone.push(...names.filter((name) => !read.has(name)).map((name) => byName.get(name) as ParameterRequest));
      }),
    );
    values.push(...(await retrieveEach(this, alone, this.context.log)).values);
    return { values };
  }

  async delete(request: ParameterRequest) {
    const name = `${NAME_PREFIX}${request.externalId.path}`;
    try {
      await this.secrets.send(new DeleteSecretCommand({ SecretId: name, ForceDeleteWithoutRecovery: true }));
    } catch (error) {
      if (errorName(error) !== "ResourceNotFoundException") {
        throw new Failure("DELETE_FAILED", { what: `Failed to delete secret '${name}' in AWS Secrets Manager`, causes: ["IAM principal lacks secretsmanager:DeleteSecret on this resource", `Region '${this.region}' unreachable or wrong`, "AWS API throttling"], fixes: [`Verify identity: aws sts get-caller-identity --region ${this.region}`, "Check IAM policy: aws iam simulate-principal-policy --action-names secretsmanager:DeleteSecret"], underlying: messageOf(error) });
      }
      this.context.log.debug(`Secret '${name}' does not exist, treating delete as success`);
    }
    return DONE;
  }
}

/** The value inside the envelope; a secret stored without one is its text. */
function valueOf(secretString: string): string {
  try {
    const parsed = JSON.parse(secretString) as { value?: unknown };
    return parsed && typeof parsed === "object" && parsed.value !== undefined ? String(parsed.value) : "";
  } catch {
    return "";
  }
}

export function awsSecretsManager(options: SecretsManagerOptions = {}): Provider {
  const clients = options.clients ?? { ...realAwsClients, secrets: (access) => new SecretsManagerClient(clientOptions(access)) };
  const env = options.env ?? process.env;
  const roles = assumedRolesOf(clients);
  const now = options.now ?? (() => new Date());
  return {
    slug: SLUG,
    async open(request, context) {
      const access = await awsAccess({ context, request, env, selection: ROLE, roles });
      const kmsKeyId = settingOf(request.provider.attributes, env, { attribute: "setup.kms_key_id" });
      return new SecretsManagerSession(clients.secrets(access), access.region, kmsKeyId, now, context);
    },
  };
}
