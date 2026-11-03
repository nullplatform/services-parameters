/**
 * Which AWS identity an operation runs as. The agent's own credentials (the
 * pod's IRSA) unless a role is to be assumed: an operator's override variable
 * first, then the role the platform's IAM provider names for the selector at
 * the parameter's NRN and dimensions, then a default variable. An assumed
 * role's credentials are kept until shortly before they expire, so one STS
 * call serves the actions of the next hour, as the bash's file cache did.
 */

import type { AwsCredentialIdentity } from "@aws-sdk/types";
import type { Context, Logger } from "@nullplatform/plugin";
import { nrnOf, type ParameterRequest } from "../context";
import { Failure, messageOf } from "../failure";
import { providerOf } from "../platform/providers";

/** A client the SDK's commands are sent through; a test fakes it. */
export interface Sender {
  send(command: unknown): Promise<any>;
}

export interface RoleSelection {
  /** The key under the IAM provider's `iam_role_arns.arns[]`. */
  selector: string;
  /** The variable that overrides the lookup with an ARN. */
  overrideVariable: string;
  /** The variable consulted when nothing else names a role. */
  defaultVariable: string;
  /** The STS session name's prefix. */
  sessionPrefix: string;
}

export interface AwsAccess {
  region: string;
  /** The assumed role's credentials; none runs as the agent. */
  credentials?: AwsCredentialIdentity;
}

/** The ARN the IAM provider's attributes name for `selector`; "" when none. */
export function arnForSelector(attributes: Record<string, unknown>, selector: string): string {
  const roles =
    (attributes.iam_role_arns as { arns?: Array<{ selector?: string; arn?: string }> } | undefined)?.arns ?? [];
  return roles.find((role) => role.selector === selector)?.arn ?? "";
}

/** The ARN to assume, "" to run as the agent: the override, else the provider's, else the default. */
export function resolveRoleArn(input: {
  override?: string;
  attributes: Record<string, unknown>;
  selector: string;
  fallback?: string;
}): string {
  return input.override || arnForSelector(input.attributes, input.selector) || input.fallback || "";
}

/** The IAM provider's attributes over the request's NRN and dimensions, as the platform resolves them; {} when there is none or the lookup fails. */
export async function iamAttributesOf(context: Context, request: ParameterRequest): Promise<Record<string, unknown>> {
  try {
    const provider = await providerOf(context.api, "identity-access-control", nrnOf(request), request.valueDimensions);
    return provider?.attributes ?? {};
  } catch (error) {
    context.log.warn(`IAM provider lookup failed: ${messageOf(error)}`);
    return {};
  }
}

interface Assumed {
  credentials: AwsCredentialIdentity;
  expiresAt: number;
}

const REFRESH_MARGIN_MS = 60_000;
const DEFAULT_LIFETIME_MS = 3_540_000;

/** Assumed roles' credentials, one STS call per role until a minute before they expire. */
export class AssumedRoles {
  private readonly held = new Map<string, Assumed>();

  constructor(
    private readonly sts: (region: string) => Sender,
    private readonly assumeRole: new (input: { RoleArn: string; RoleSessionName: string }) => unknown,
    private readonly now: () => number = Date.now,
  ) {}

  async credentialsFor(arn: string, sessionName: string, region: string, log: Logger): Promise<AwsCredentialIdentity> {
    const known = this.held.get(arn);
    if (known && known.expiresAt - this.now() > REFRESH_MARGIN_MS) {
      log.debug(`sts: ${arn} still valid for ${Math.round((known.expiresAt - this.now()) / 1000)}s`);
      return known.credentials;
    }
    log.info(`Assuming role ${arn}`);
    let answer: {
      Credentials?: {
        AccessKeyId?: string;
        SecretAccessKey?: string;
        SessionToken?: string;
        Expiration?: Date | string;
      };
    };
    try {
      answer = await this.sts(region).send(new this.assumeRole({ RoleArn: arn, RoleSessionName: sessionName }));
    } catch (error) {
      throw new Failure("ASSUME_ROLE_FAILED", {
        what: `sts:AssumeRole failed for ${arn}`,
        causes: [
          "The agent's role is not allowed to sts:AssumeRole the target role",
          "The target role does not exist or does not trust the agent role",
        ],
        underlying: messageOf(error),
      });
    }
    const got = answer.Credentials ?? {};
    if (!got.AccessKeyId || !got.SecretAccessKey || !got.SessionToken) {
      throw new Failure("ASSUME_ROLE_FAILED", { what: `sts:AssumeRole returned incomplete credentials for ${arn}` });
    }
    const expiration = got.Expiration ? new Date(got.Expiration).getTime() : Number.NaN;
    const expiresAt =
      Number.isFinite(expiration) && expiration > this.now() ? expiration : this.now() + DEFAULT_LIFETIME_MS;
    const credentials = {
      accessKeyId: got.AccessKeyId,
      secretAccessKey: got.SecretAccessKey,
      sessionToken: got.SessionToken,
    };
    this.held.set(arn, { credentials, expiresAt });
    log.info("Role assumed");
    return credentials;
  }
}

export interface AccessOptions {
  context: Context;
  request: ParameterRequest;
  env: Record<string, string | undefined>;
  selection: RoleSelection;
  roles: AssumedRoles;
}

/** The region and, when a role is named for the request, that role's credentials. */
export async function awsAccess(options: AccessOptions): Promise<AwsAccess> {
  const { env, request, selection } = options;
  const region = env.AWS_REGION ?? "";
  if (region === "") {
    throw new Failure("MISSING_REGION", { what: "AWS_REGION must be set by the agent runtime" });
  }
  const override = env[selection.overrideVariable];
  const fallback = env[selection.defaultVariable];
  // The IAM provider is asked only when neither variable settles it, as the bash asked it for every run.
  const attributes = override ? {} : await iamAttributesOf(options.context, request);
  const arn = resolveRoleArn({ override, attributes, selector: selection.selector, fallback });
  if (arn === "") {
    options.context.log.debug("assume_role=skipped (using agent credentials)");
    return { region };
  }
  const sessionName = `${selection.sessionPrefix}-${request.entities.scope || "workflow"}`;
  return { region, credentials: await options.roles.credentialsFor(arn, sessionName, region, options.context.log) };
}
