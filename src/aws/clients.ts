/**
 * The AWS SDK's clients as the providers build them: one per region and
 * identity, the SDK's own credential chain when no role was assumed. A test
 * hands fakes in their place.
 */

import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";
import { AssumedRoles, type AwsAccess, type Sender } from "./role";

export interface AwsClients {
  sts: (region: string) => Sender;
}

export const realAwsClients: AwsClients = { sts: (region) => new STSClient({ region }) };

/** The roles assumed through `clients`, remembered for the worker's life. */
export const assumedRolesOf = (clients: AwsClients): AssumedRoles => new AssumedRoles(clients.sts, AssumeRoleCommand);

/** The client options an access resolves to. */
export const clientOptions = (access: AwsAccess): { region: string; credentials?: AwsAccess["credentials"] } =>
  access.credentials ? { region: access.region, credentials: access.credentials } : { region: access.region };
