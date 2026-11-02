import { describe, expect, test } from "bun:test";
import { BATCH_CONCURRENCY, chunks, retrieveEach } from "../src/provider";
import { fakeContext, requestFor } from "./support";

const handle = (index: number) => `organization=acme-1/account=prod-2/namespace=b-3/application=api-4/P${index}-${index}#v${index}`;

describe("a batch read one value at a time", () => {
  test("reads at most the concurrency at once, answers every handle as sent, and leaves out what fails", async () => {
    let inFlight = 0;
    let mostAtOnce = 0;
    const session = {
      async retrieve(request: { externalId: { path: string; version: string } }) {
        inFlight += 1;
        mostAtOnce = Math.max(mostAtOnce, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 2));
        inFlight -= 1;
        if (request.externalId.version === "v7") {
          throw new Error("refused");
        }
        return { value: `value ${request.externalId.version}` };
      },
    };
    const { context, lines } = fakeContext();
    const requests = Array.from({ length: 25 }, (_, index) => requestFor("aws-secrets-manager", { external_id: handle(index) }));
    const answer = await retrieveEach(session, requests, context.log);
    expect(mostAtOnce).toBe(BATCH_CONCURRENCY);
    expect(answer.values.length).toBe(24);
    expect(answer.values.find((value) => value.external_id === handle(3))).toEqual({ external_id: handle(3), value: "value v3" });
    expect(answer.values.some((value) => value.external_id === handle(7))).toBe(false);
    expect(lines).toEqual([expect.stringContaining("P7-7' left out of the batch: refused")]);
    expect(await retrieveEach(session, [], context.log)).toEqual({ values: [] });
  });

  test("chunks keep the order", () => {
    expect(chunks([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunks([], 3)).toEqual([]);
  });
});
