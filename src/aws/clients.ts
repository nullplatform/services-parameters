/**
 * The AWS SDK as the providers reach it: a client is a sender of the SDK's
 * commands, one per region and identity, built by the SDK with its own
 * credential chain unless a role was assumed. A test hands fakes in their
 * place.
 */

import { STSClient } from "@aws-sdk/client-sts";
import type { AwsCredentialIdentity } from "@aws-sdk/types";

/** A client the SDK's commands are sent through, answering what the command's output says; a test fakes it. */
export interface Sender {
  send<Output>(command: unknown): Promise<Output>;
}

export interface AwsAccess {
  region: string;
  /** The assumed role's credentials; none runs as the agent. */
  credentials?: AwsCredentialIdentity;
}

export interface AwsClients {
  sts: (region: string) => Sender;
}

export const realAwsClients: AwsClients = { sts: (region) => new STSClient({ region }) };

/** The client options an access resolves to. */
export const clientOptions = (access: AwsAccess): { region: string; credentials?: AwsCredentialIdentity } =>
  access.credentials ? { region: access.region, credentials: access.credentials } : { region: access.region };

/** The service's error code, which the SDK puts in the error's name; "" for anything else. */
export const errorNameOf = (error: unknown): string => (error instanceof Error ? error.name : "");
