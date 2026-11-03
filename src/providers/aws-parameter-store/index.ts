/**
 * AWS Systems Manager Parameter Store. One parameter per nullplatform
 * parameter under `/nullplatform/<canonical path>` with `=` as `_`, a
 * SecureString for a secret and a String otherwise, each store a new version
 * of it (PutParameter with Overwrite). The handle carries the version AWS
 * returns; retrieve reads `<name>:<version>`, delete removes every version.
 */

import {
  DeleteParameterCommand,
  GetParameterCommand,
  GetParametersCommand,
  PutParameterCommand,
  SSMClient,
  type ParameterTier,
} from "@aws-sdk/client-ssm";
import type { Context } from "@nullplatform/plugin";
import {
  clientOptions,
  errorNameOf,
  realAwsClients,
  type AwsAccess,
  type AwsClients,
  type Sender,
} from "../../aws/clients";
import { AssumedRoles, awsAccess, type RoleSelection } from "../../aws/role";
import { handleOf, type ParameterRequest } from "../../context";
import { Failure, messageOf } from "../../failure";
import { canonicalPath } from "../../naming";
import { chunks, DONE, retrieveEach, type Provider, type RetrievedBatch, type Session } from "../../provider";
import { settingOf } from "../../settings";

export const SLUG = "aws-parameter-store";
export const NAME_PREFIX = "/nullplatform/";
export const TIERS: readonly ParameterTier[] = ["Standard", "Advanced", "Intelligent-Tiering"];

const isTier = (value: string): value is ParameterTier => (TIERS as readonly string[]).includes(value);

const ROLE: RoleSelection = {
  selector: "parameter_store",
  overrideVariable: "PARAMETER_STORE_ASSUME_ROLE_ARN",
  defaultVariable: "PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT",
  sessionPrefix: "np-parameter-store",
};

export interface ParameterStoreClients extends AwsClients {
  ssm: (access: AwsAccess) => Sender;
}

export interface ParameterStoreOptions {
  clients?: ParameterStoreClients;
  env?: Record<string, string | undefined>;
}

/** SSM path segments allow `[A-Za-z0-9._-]`: the `=` that binds an entity becomes `_`; the handle keeps the canonical form. */
export const parameterNameOf = (path: string): string => `${NAME_PREFIX}${path.replace(/=/g, "_")}`;

/** How many parameters one GetParameters reads. */
export const BATCH_SIZE = 10;

/** The name SSM reads a parameter by: `<name>:<version>` when the handle names a version. */
const selectorOf = (name: string, version: string): string => (version ? `${name}:${version}` : name);

/** What Parameter Store answers, the fields read here. */
interface PutParameterAnswer {
  Version?: number;
}

interface GetParameterAnswer {
  Parameter?: { Value?: string };
}

interface BatchAnswer {
  Parameters?: Array<{ Name?: string; Version?: number; Value?: string }>;
}

class ParameterStoreSession implements Session {
  constructor(
    private readonly ssm: Sender,
    private readonly region: string,
    private readonly kmsKeyId: string,
    private readonly tier: ParameterTier,
    private readonly context: Context,
  ) {}

  async store(request: ParameterRequest) {
    const path = canonicalPath(request);
    const name = parameterNameOf(path);
    const type = request.kind === "secret" ? "SecureString" : "String";
    let result: PutParameterAnswer;
    try {
      result = await this.ssm.send<PutParameterAnswer>(
        new PutParameterCommand({
          Name: name,
          Value: request.value,
          Type: type,
          Tier: this.tier,
          Overwrite: true,
          ...(type === "SecureString" && this.kmsKeyId ? { KeyId: this.kmsKeyId } : {}),
        }),
      );
    } catch (error) {
      throw new Failure("STORE_FAILED", {
        what: "Failed to store parameter in AWS Parameter Store",
        causes: [
          `IAM principal lacks ssm:PutParameter for ${name}`,
          `Tier '${this.tier}' rejects this value size (Standard caps at 4KB)`,
          ...(type === "SecureString" && this.kmsKeyId ? [`IAM principal lacks kms:Encrypt on ${this.kmsKeyId}`] : []),
        ],
        fixes: [
          `Verify identity: aws sts get-caller-identity --region ${this.region}`,
          "For large values, set the tier to Advanced",
        ],
        underlying: messageOf(error),
      });
    }
    return {
      external_id: handleOf(path, result.Version === undefined ? "" : String(result.Version)),
      metadata: { parameter_name: name, region: this.region, type, tier: this.tier },
    };
  }

  async retrieve(request: ParameterRequest) {
    const name = parameterNameOf(request.externalId.path);
    const version = request.externalId.version;
    let answer: GetParameterAnswer;
    try {
      answer = await this.ssm.send<GetParameterAnswer>(
        new GetParameterCommand({ Name: selectorOf(name, version), WithDecryption: true }),
      );
    } catch (error) {
      if (errorNameOf(error) === "ParameterNotFound" || errorNameOf(error) === "ParameterVersionNotFound") {
        throw new Failure("NOT_FOUND", {
          what: `Parameter '${name}' not found in AWS Parameter Store`,
          causes: [
            "The parameter was manually deleted from AWS SSM",
            "The external_id is stale",
            ...(version ? [`Requested version '${version}' is outside Parameter Store's retention window`] : []),
          ],
          fixes: [
            `Verify: aws ssm describe-parameters --filters Key=Name,Values=${name} --region ${this.region}`,
            "If genuinely missing, the parameter value needs to be re-stored",
          ],
        });
      }
      throw new Failure("RETRIEVE_FAILED", {
        what: `Failed to retrieve parameter '${name}' from AWS Parameter Store`,
        causes: [
          "IAM principal lacks ssm:GetParameter on this resource",
          "KMS key permission missing (kms:Decrypt) for SecureString",
          `Region '${this.region}' unreachable`,
        ],
        fixes: [`Verify identity: aws sts get-caller-identity --region ${this.region}`],
        underlying: messageOf(error),
      });
    }
    return { value: answer.Parameter?.Value ?? "" };
  }

  /** A batch reads up to BATCH_SIZE parameters per GetParameters, each at the version its handle names; one the call could not read, or answered at another version, is read alone, and one that still fails is left out. */
  async retrieveBatch(requests: ParameterRequest[]): Promise<RetrievedBatch> {
    const byName = new Map(requests.map((request) => [parameterNameOf(request.externalId.path), request]));
    const values: RetrievedBatch["values"] = [];
    const alone: ParameterRequest[] = [];
    await Promise.all(
      chunks([...byName], BATCH_SIZE).map(async (group) => {
        const names = group.map(([name, request]) => selectorOf(name, request.externalId.version));
        let answer: BatchAnswer;
        try {
          answer = await this.ssm.send<BatchAnswer>(new GetParametersCommand({ Names: names, WithDecryption: true }));
        } catch (error) {
          this.context.log.warn(
            `batch read of ${names.length} parameters failed, reading them one by one: ${messageOf(error)}`,
          );
          alone.push(...group.map(([, request]) => request));
          return;
        }
        const read = new Set<string>();
        for (const parameter of answer.Parameters ?? []) {
          const name = parameter.Name ?? "";
          const request = byName.get(name);
          if (!request) {
            continue;
          }
          read.add(name);
          if (request.externalId.version && String(parameter.Version ?? "") !== request.externalId.version) {
            alone.push(request);
            continue;
          }
          values.push({
            external_id: handleOf(request.externalId.path, request.externalId.version),
            value: parameter.Value ?? "",
          });
        }
        alone.push(...group.filter(([name]) => !read.has(name)).map(([, request]) => request));
      }),
    );
    values.push(...(await retrieveEach(this, alone, this.context.log)).values);
    return { values };
  }

  async delete(request: ParameterRequest) {
    const name = parameterNameOf(request.externalId.path);
    try {
      await this.ssm.send(new DeleteParameterCommand({ Name: name }));
    } catch (error) {
      if (errorNameOf(error) !== "ParameterNotFound") {
        throw new Failure("DELETE_FAILED", {
          what: `Failed to delete parameter '${name}' in AWS Parameter Store`,
          causes: [
            "IAM principal lacks ssm:DeleteParameter on this resource",
            `Region '${this.region}' unreachable or wrong`,
          ],
          fixes: [`Verify identity: aws sts get-caller-identity --region ${this.region}`],
          underlying: messageOf(error),
        });
      }
      this.context.log.debug(`Parameter '${name}' does not exist, treating delete as success`);
    }
    return DONE;
  }
}

export function awsParameterStore(options: ParameterStoreOptions = {}): Provider {
  const clients = options.clients ?? { ...realAwsClients, ssm: (access) => new SSMClient(clientOptions(access)) };
  const env = options.env ?? process.env;
  const roles = new AssumedRoles(clients.sts);
  return {
    slug: SLUG,
    async open(request, context) {
      const access = await awsAccess({ context, request, env, selection: ROLE, roles });
      const kmsKeyId = settingOf(request.provider.attributes, env, { attribute: "setup.kms_key_id" });
      const tier = settingOf(request.provider.attributes, env, { attribute: "setup.tier", fallback: "Standard" });
      if (!isTier(tier)) {
        throw new Failure("INVALID_TIER", {
          what: `Invalid tier '${tier}'`,
          fixes: [`Set the tier to one of: ${TIERS.join(", ")}`],
        });
      }
      return new ParameterStoreSession(clients.ssm(access), access.region, kmsKeyId, tier, context);
    },
  };
}
