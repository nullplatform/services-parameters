import { describe, expect, test } from "bun:test";
import { awsSecretsManager, envelopeOf, NAME_PREFIX } from "../src/providers/aws-secrets-manager/index";
import { awsError, CANONICAL, fakeContext, fakeSender, requestFor } from "./support";

const NOW = new Date("2026-11-02T10:00:00.000Z");
const provider = (answers: Record<string, (input: any) => unknown>) => {
  const secrets = fakeSender(answers);
  const sts = fakeSender({});
  return { provider: awsSecretsManager({ clients: { secrets: () => secrets.sender, sts: () => sts.sender }, env: { AWS_REGION: "us-east-1" }, now: () => NOW }), sent: secrets.sent };
};
const open = async (answers: Record<string, (input: any) => unknown>, extra: Record<string, unknown> = {}) => {
  const built = provider(answers);
  const request = requestFor("aws-secrets-manager", extra);
  const { context, lines } = fakeContext();
  return { session: await built.provider.open(request, context), request, sent: built.sent, lines };
};

describe("aws-secrets-manager", () => {
  test("store creates the secret under nullplatform/ with the envelope, the handle carrying the version", async () => {
    const { session, request, sent } = await open({ CreateSecretCommand: () => ({ ARN: "arn:secret", VersionId: "v1-uuid" }) });
    const stored = await session.store(request);
    expect(stored).toEqual({ external_id: `${CANONICAL}#v1-uuid`, metadata: { secret_arn: "arn:secret", secret_name: `${NAME_PREFIX}${CANONICAL}`, region: "us-east-1" } });
    expect(sent[0].input).toEqual({ Name: `${NAME_PREFIX}${CANONICAL}`, SecretString: envelopeOf(request, CANONICAL, NOW) });
    expect(JSON.parse(sent[0].input.SecretString)).toEqual({ parameter_id: 42, value: "s3cr3t", stored_at: "2026-11-02T10:00:00Z", external_id: CANONICAL });
  });

  test("store adds a version to a secret that exists, and passes the KMS key the provider configures", async () => {
    const { session, request, sent, lines } = await open({ CreateSecretCommand: () => { throw awsError("ResourceExistsException"); }, PutSecretValueCommand: () => ({ ARN: "arn:secret", VersionId: "v2-uuid" }) }, { provider: { specification_slug: "aws-secrets-manager", attributes: { setup: { kms_key_id: "alias/custom" } } } });
    const stored = await session.store(request);
    expect(stored.external_id).toBe(`${CANONICAL}#v2-uuid`);
    expect(sent.map((call) => call.name)).toEqual(["CreateSecretCommand", "PutSecretValueCommand"]);
    expect(sent[0].input.KmsKeyId).toBe("alias/custom");
    expect(lines).toContain(`debug Secret '${NAME_PREFIX}${CANONICAL}' exists; adding new version (history preserved by AWS SM)`);
  });

  test("a refused create or put is a failure naming the cause", async () => {
    const denied = await open({ CreateSecretCommand: () => { throw awsError("AccessDeniedException", "not authorized"); } });
    await expect(denied.session.store(denied.request)).rejects.toMatchObject({ code: "STORE_FAILED", message: expect.stringContaining("secretsmanager:CreateSecret") });
    const stale = await open({ CreateSecretCommand: () => { throw awsError("ResourceExistsException"); }, PutSecretValueCommand: () => { throw awsError("InvalidRequestException", "pending deletion"); } });
    await expect(stale.session.store(stale.request)).rejects.toMatchObject({ code: "STORE_FAILED", message: expect.stringContaining("pending deletion") });
  });

  test("retrieve reads the version the handle names and unwraps the envelope; a missing secret is NOT_FOUND", async () => {
    const { session, request, sent } = await open({ GetSecretValueCommand: () => ({ SecretString: JSON.stringify({ value: "s3cr3t" }) }) }, { external_id: `${CANONICAL}#v1-uuid` });
    expect(await session.retrieve(request)).toEqual({ value: "s3cr3t" });
    expect(sent[0].input).toEqual({ SecretId: `${NAME_PREFIX}${CANONICAL}`, VersionId: "v1-uuid" });
    const latest = await open({ GetSecretValueCommand: () => ({ SecretString: JSON.stringify({ value: "x" }) }) }, { external_id: CANONICAL });
    await latest.session.retrieve(latest.request);
    expect(latest.sent[0].input).toEqual({ SecretId: `${NAME_PREFIX}${CANONICAL}` });
    const missing = await open({ GetSecretValueCommand: () => { throw awsError("ResourceNotFoundException"); } }, { external_id: `${CANONICAL}#v9` });
    await expect(missing.session.retrieve(missing.request)).rejects.toMatchObject({ code: "NOT_FOUND", message: expect.stringContaining("Requested version 'v9' was pruned") });
    const refused = await open({ GetSecretValueCommand: () => { throw awsError("AccessDeniedException"); } }, { external_id: CANONICAL });
    await expect(refused.session.retrieve(refused.request)).rejects.toMatchObject({ code: "RETRIEVE_FAILED" });
  });

  test("delete removes the secret without recovery, a missing one is success, anything else fails", async () => {
    const { session, request, sent } = await open({ DeleteSecretCommand: () => ({}) }, { external_id: `${CANONICAL}#v1` });
    expect(await session.delete(request)).toEqual({ success: true });
    expect(sent[0].input).toEqual({ SecretId: `${NAME_PREFIX}${CANONICAL}`, ForceDeleteWithoutRecovery: true });
    const gone = await open({ DeleteSecretCommand: () => { throw awsError("ResourceNotFoundException"); } }, { external_id: CANONICAL });
    expect(await gone.session.delete(gone.request)).toEqual({ success: true });
    const refused = await open({ DeleteSecretCommand: () => { throw awsError("AccessDeniedException"); } }, { external_id: CANONICAL });
    await expect(refused.session.delete(refused.request)).rejects.toMatchObject({ code: "DELETE_FAILED" });
  });
});
