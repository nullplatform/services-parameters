import { beforeEach, describe, expect, test } from "bun:test";
import { forgetProviders } from "../src/platform/providers";
import { AssumedRoles, arnForSelector, awsAccess, resolveRoleArn, type RoleSelection } from "../src/aws/role";
import { fakeContext, fakeSender, requestFor } from "./support";

class AssumeRole {
  constructor(readonly input: { RoleArn: string; RoleSessionName: string }) {}
}
const SELECTION: RoleSelection = {
  selector: "secret_manager",
  overrideVariable: "OVERRIDE",
  defaultVariable: "DEFAULT",
  sessionPrefix: "np-test",
};
const IAM = {
  iam_role_arns: {
    arns: [
      { selector: "parameter_store", arn: "arn:ps" },
      { selector: "secret_manager", arn: "arn:sm" },
    ],
  },
};

describe("the role to assume", () => {
  test("is the override, else the provider's for the selector, else the default, else none", () => {
    expect(arnForSelector(IAM, "secret_manager")).toBe("arn:sm");
    expect(arnForSelector({}, "secret_manager")).toBe("");
    expect(resolveRoleArn({ override: "arn:o", attributes: IAM, selector: "secret_manager", fallback: "arn:d" })).toBe(
      "arn:o",
    );
    expect(resolveRoleArn({ attributes: IAM, selector: "secret_manager", fallback: "arn:d" })).toBe("arn:sm");
    expect(resolveRoleArn({ attributes: {}, selector: "secret_manager", fallback: "arn:d" })).toBe("arn:d");
    expect(resolveRoleArn({ attributes: {}, selector: "secret_manager" })).toBe("");
  });
});

describe("assumed credentials", () => {
  test("are asked of STS once and kept until a minute before they expire", async () => {
    let now = Date.parse("2026-11-02T10:00:00Z");
    const { sender, sent } = fakeSender({
      AssumeRole: () => ({
        Credentials: {
          AccessKeyId: "AK",
          SecretAccessKey: "SK",
          SessionToken: "ST",
          Expiration: new Date(now + 3_600_000),
        },
      }),
    });
    const roles = new AssumedRoles(
      () => sender,
      AssumeRole as never,
      () => now,
    );
    const { context } = fakeContext();
    const first = await roles.credentialsFor("arn:sm", "np-test-workflow", "us-east-1", context.log);
    expect(first).toEqual({ accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "ST" });
    now += 3_000_000;
    await roles.credentialsFor("arn:sm", "np-test-workflow", "us-east-1", context.log);
    expect(sent).toHaveLength(1);
    now += 600_000;
    await roles.credentialsFor("arn:sm", "np-test-workflow", "us-east-1", context.log);
    expect(sent).toHaveLength(2);
    expect(sent[0].input).toEqual({ RoleArn: "arn:sm", RoleSessionName: "np-test-workflow" });
  });

  test("a refused or incomplete assume role is a failure in plain words", async () => {
    const { context } = fakeContext();
    const refused = new AssumedRoles(
      () =>
        fakeSender({
          AssumeRole: () => {
            throw new Error("AccessDenied");
          },
        }).sender,
      AssumeRole as never,
    );
    await expect(refused.credentialsFor("arn:x", "s", "r", context.log)).rejects.toMatchObject({
      code: "ASSUME_ROLE_FAILED",
      message: expect.stringContaining("AccessDenied"),
    });
    const partial = new AssumedRoles(
      () => fakeSender({ AssumeRole: () => ({ Credentials: { AccessKeyId: "AK" } }) }).sender,
      AssumeRole as never,
    );
    await expect(partial.credentialsFor("arn:x", "s", "r", context.log)).rejects.toMatchObject({
      code: "ASSUME_ROLE_FAILED",
      message: expect.stringContaining("incomplete"),
    });
  });
});

describe("the access of an operation", () => {
  beforeEach(forgetProviders);

  test("needs the region, runs as the agent when nothing names a role, and asks the IAM provider at the request's NRN", async () => {
    const roles = new AssumedRoles(() => fakeSender({}).sender, AssumeRole as never);
    const request = requestFor("aws-secrets-manager");
    await expect(
      awsAccess({ context: fakeContext().context, request, env: {}, selection: SELECTION, roles }),
    ).rejects.toMatchObject({ code: "MISSING_REGION" });
    const asAgent = await awsAccess({
      context: fakeContext().context,
      request,
      env: { AWS_REGION: "us-east-1" },
      selection: SELECTION,
      roles,
    });
    expect(asAgent).toEqual({ region: "us-east-1" });
  });

  test("assumes the role the IAM provider names, with the scope in the session name", async () => {
    const { sender, sent } = fakeSender({
      AssumeRole: () => ({ Credentials: { AccessKeyId: "AK", SecretAccessKey: "SK", SessionToken: "ST" } }),
    });
    const roles = new AssumedRoles(() => sender, AssumeRole as never);
    const request = requestFor("aws-secrets-manager", {
      value_entities: { organization: "1", account: "2", namespace: "3", application: "4", scope: "5" },
      value_dimensions: { environment: "prod" },
    });
    const { context } = fakeContext([{ attributes: IAM }]);
    const access = await awsAccess({ context, request, env: { AWS_REGION: "eu-west-1" }, selection: SELECTION, roles });
    expect(access.credentials?.accessKeyId).toBe("AK");
    expect(sent[0].input).toEqual({ RoleArn: "arn:sm", RoleSessionName: "np-test-5" });
    const overridden = await awsAccess({
      context,
      request,
      env: { AWS_REGION: "eu-west-1", OVERRIDE: "arn:o" },
      selection: SELECTION,
      roles,
    });
    expect(overridden.credentials?.accessKeyId).toBe("AK");
    expect(sent[1].input.RoleArn).toBe("arn:o");
  });
});
