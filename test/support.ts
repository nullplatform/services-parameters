/** The request every suite starts from, as the platform sends a parameter action, and the fakes the backends are answered with. */
import type { Context, Payload } from "@nullplatform/plugin";
import { requestOf, type ParameterRequest } from "../src/context";
import storeSample from "../src/samples/store.json" with { type: "json" };

export const ENTITIES = { organization: "1255165411", organization_slug: "acme", account: "95118862", account_slug: "prod", namespace: "37094320", namespace_slug: "billing", application: "321402625", application_slug: "api" };
export const CANONICAL = "organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/DB_PASSWORD-42";

/** A store payload for `slug`, the sample's entities, no dimensions unless given. */
export function payloadFor(slug: string, extra: Record<string, unknown> = {}): Payload {
  const sample = storeSample.notification as Record<string, unknown>;
  return { ...sample, dimensions: {}, provider: { ...(sample.provider as Record<string, unknown>), specification_slug: slug, attributes: {} }, ...extra };
}

export const requestFor = (slug: string, extra: Record<string, unknown> = {}): ParameterRequest => requestOf(payloadFor(slug, extra));

/** A context whose log is kept and whose platform answers no provider. */
export function fakeContext(providers: unknown[] = []): { context: Context; lines: string[] } {
  const lines: string[] = [];
  const log = { debug: (line: string) => lines.push(`debug ${line}`), info: (line: string) => lines.push(`info ${line}`), warn: (line: string) => lines.push(`warn ${line}`), error: (line: string) => lines.push(`error ${line}`) };
  const api = { provider: { list: () => ({ [Symbol.asyncIterator]: async function* () { yield { results: providers }; } }) } };
  return { context: { log, api, signal: undefined } as unknown as Context, lines };
}

export interface Sent {
  name: string;
  input: Record<string, any>;
}

/** An AWS client fake: answers each command by its class name, remembers what was sent. */
export function fakeSender(answers: Record<string, (input: any) => unknown>): { sender: { send(command: any): Promise<any> }; sent: Sent[] } {
  const sent: Sent[] = [];
  return {
    sent,
    sender: {
      async send(command: any) {
        const name: string = command.constructor.name;
        sent.push({ name, input: command.input });
        const answer = answers[name];
        if (!answer) {
          throw new Error(`no answer for ${name}`);
        }
        return answer(command.input);
      },
    },
  };
}

/** An error as the AWS SDK throws one: its name is the service's code. */
export function awsError(name: string, message = name): Error {
  const error = new Error(message);
  error.name = name;
  return error;
}

/** A fetch fake answering by method and URL, remembering each call. */
export function fakeFetch(route: (method: string, url: string, body: unknown) => { status: number; body?: unknown } | undefined): { fetch: typeof fetch; calls: Array<{ method: string; url: string; body: unknown; headers: Record<string, string> }> } {
  const calls: Array<{ method: string; url: string; body: unknown; headers: Record<string, string> }> = [];
  const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    calls.push({ method, url, body, headers: (init?.headers as Record<string, string>) ?? {} });
    const answer = route(method, url, body);
    if (!answer) {
      throw new TypeError("fetch failed");
    }
    return new Response(answer.body === undefined ? "" : JSON.stringify(answer.body), { status: answer.status });
  }) as typeof fetch;
  return { fetch: fetchFn, calls };
}
