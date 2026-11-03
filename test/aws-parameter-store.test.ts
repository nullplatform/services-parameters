import { describe, expect, test } from "bun:test";
import { awsParameterStore, parameterNameOf } from "../src/providers/aws-parameter-store/index";
import { awsError, CANONICAL, fakeContext, fakeSender, requestFor } from "./support";

const NAME = parameterNameOf(CANONICAL);
const open = async (
  answers: Record<string, (input: any) => unknown>,
  extra: Record<string, unknown> = {},
  attributes: Record<string, unknown> = {},
) => {
  const ssm = fakeSender(answers);
  const provider = awsParameterStore({
    clients: { ssm: () => ssm.sender, sts: () => fakeSender({}).sender },
    env: { AWS_REGION: "us-east-1" },
  });
  const request = requestFor("aws-parameter-store", {
    ...extra,
    provider: { specification_slug: "aws-parameter-store", attributes },
  });
  const { context } = fakeContext();
  return { session: await provider.open(request, context), request, sent: ssm.sent, provider, context };
};

describe("aws-parameter-store", () => {
  test("the name is /nullplatform/ plus the path with = as _", () => {
    expect(NAME).toBe(
      "/nullplatform/organization_acme-1255165411/account_prod-95118862/namespace_billing-37094320/application_api-321402625/DB_PASSWORD-42",
    );
  });

  test("store puts a SecureString for a secret with the KMS key, a String otherwise, overwriting, and the handle carries the version", async () => {
    const secret = await open(
      { PutParameterCommand: () => ({ Version: 3 }) },
      {},
      { setup: { kms_key_id: "alias/ps", tier: "Advanced" } },
    );
    const stored = await secret.session.store(secret.request);
    expect(stored).toEqual({
      external_id: `${CANONICAL}#3`,
      metadata: { parameter_name: NAME, region: "us-east-1", type: "SecureString", tier: "Advanced" },
    });
    expect(secret.sent[0].input).toEqual({
      Name: NAME,
      Value: "s3cr3t",
      Type: "SecureString",
      Tier: "Advanced",
      Overwrite: true,
      KeyId: "alias/ps",
    });
    const plain = await open({ PutParameterCommand: () => ({ Version: 1 }) }, { secret: false });
    await plain.session.store(plain.request);
    expect(plain.sent[0].input).toEqual({
      Name: NAME,
      Value: "s3cr3t",
      Type: "String",
      Tier: "Standard",
      Overwrite: true,
    });
  });

  test("an invalid tier is refused at open, a refused put is a failure", async () => {
    await expect(open({}, {}, { setup: { tier: "Gold" } })).rejects.toMatchObject({ code: "INVALID_TIER" });
    const refused = await open({
      PutParameterCommand: () => {
        throw awsError("AccessDeniedException");
      },
    });
    await expect(refused.session.store(refused.request)).rejects.toMatchObject({
      code: "STORE_FAILED",
      message: expect.stringContaining("ssm:PutParameter"),
    });
  });

  test("retrieve reads name:version with decryption; a missing parameter is NOT_FOUND", async () => {
    const { session, request, sent } = await open(
      { GetParameterCommand: () => ({ Parameter: { Value: "v" } }) },
      { external_id: `${CANONICAL}#2` },
    );
    expect(await session.retrieve(request)).toEqual({ value: "v" });
    expect(sent[0].input).toEqual({ Name: `${NAME}:2`, WithDecryption: true });
    const missing = await open(
      {
        GetParameterCommand: () => {
          throw awsError("ParameterNotFound");
        },
      },
      { external_id: CANONICAL },
    );
    await expect(missing.session.retrieve(missing.request)).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

  test("delete is idempotent on a missing parameter and fails on anything else", async () => {
    const { session, request, sent } = await open(
      { DeleteParameterCommand: () => ({}) },
      { external_id: `${CANONICAL}#2` },
    );
    expect(await session.delete(request)).toEqual({ success: true });
    expect(sent[0].input).toEqual({ Name: NAME });
    const gone = await open(
      {
        DeleteParameterCommand: () => {
          throw awsError("ParameterNotFound");
        },
      },
      { external_id: CANONICAL },
    );
    expect(await gone.session.delete(gone.request)).toEqual({ success: true });
    const refused = await open(
      {
        DeleteParameterCommand: () => {
          throw awsError("AccessDeniedException");
        },
      },
      { external_id: CANONICAL },
    );
    await expect(refused.session.delete(refused.request)).rejects.toMatchObject({ code: "DELETE_FAILED" });
  });
});

describe("a batch of parameters", () => {
  const base =
    "organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625";
  const nameOf = (handle: string) => `/nullplatform/${handle.split("#")[0].replace(/=/g, "_")}`;
  const batchRequests = (handles: string[]) =>
    handles.map((handle) => requestFor("aws-parameter-store", { external_id: handle }));

  test("reads 10 per GetParameters at the handles' versions, re-reads alone what the call skipped or answered at another version, and leaves out what still fails", async () => {
    const handles = Array.from({ length: 12 }, (_, index) => `${base}/P${index}-${index}#${index + 1}`);
    const { session, sent } = await open({
      GetParametersCommand: (input: { Names: string[] }) => ({
        Parameters: input.Names.filter(
          (selector) => !selector.endsWith("/P5-5:6") && !selector.endsWith("/P9-9:10"),
        ).map((selector) => {
          const [name, version] = selector.split(":");
          return {
            Name: name,
            Version: name.endsWith("/P2-2") ? 99 : Number(version),
            Value: `value of ${name.split("/").pop()}`,
          };
        }),
        InvalidParameters: input.Names.filter(
          (selector) => selector.endsWith("/P5-5:6") || selector.endsWith("/P9-9:10"),
        ),
      }),
      GetParameterCommand: (input: { Name: string }) => {
        if (input.Name.endsWith("/P2-2:3")) {
          return { Parameter: { Value: "value of P2-2 at 3" } };
        }
        if (input.Name.endsWith("/P9-9:10")) {
          return { Parameter: { Value: "value of P9-9 alone" } };
        }
        throw awsError("ParameterNotFound");
      },
    });
    const answer = await session.retrieveBatch!(batchRequests(handles));
    const byHandle = Object.fromEntries(answer.values.map((value) => [value.external_id, value.value]));
    expect(Object.keys(byHandle).length).toBe(11);
    expect(byHandle[handles[0]]).toBe("value of P0-0");
    expect(byHandle[handles[2]]).toBe("value of P2-2 at 3");
    expect(byHandle[handles[9]]).toBe("value of P9-9 alone");
    expect(byHandle[handles[5]]).toBeUndefined();
    const batches = sent.filter((call) => call.name === "GetParametersCommand").map((call) => call.input.Names);
    expect(batches.map((names) => names.length).sort()).toEqual([10, 2]);
    expect(batches[0][0]).toBe(`${nameOf(handles[0])}:1`);
    expect(batches.every((names) => names.every((name: string) => name.startsWith("/nullplatform/")))).toBe(true);
    expect(
      sent
        .filter((call) => call.name === "GetParameterCommand")
        .map((call) => call.input.Name.split("/").pop())
        .sort(),
    ).toEqual(["P2-2:3", "P5-5:6", "P9-9:10"]);
  });

  test("reads every parameter alone when the batch call itself fails", async () => {
    const handles = [`${base}/A-1#1`, `${base}/B-2#2`];
    const { session, sent } = await open({
      GetParametersCommand: () => {
        throw awsError("ThrottlingException");
      },
      GetParameterCommand: (input: { Name: string }) => ({ Parameter: { Value: input.Name.split("/").pop() } }),
    });
    const answer = await session.retrieveBatch!(batchRequests(handles));
    expect(answer.values.sort((left, right) => left.external_id.localeCompare(right.external_id))).toEqual([
      { external_id: handles[0], value: "A-1:1" },
      { external_id: handles[1], value: "B-2:2" },
    ]);
    expect(sent.filter((call) => call.name === "GetParameterCommand").length).toBe(2);
  });
});
