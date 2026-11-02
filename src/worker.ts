/**
 * The parameters worker: four raw routes, `parameter:store`,
 * `parameter:retrieve`, `parameter:delete` and `parameter:notify`, each
 * reading the request from the notification, picking the backend the request
 * names in `provider.specification_slug`, opening that provider's session and
 * answering what the operation returns. One worker serves every backend the
 * image carries.
 */

import { definePlugin, where, type Context, type Payload, type Route } from "@nullplatform/plugin";
import { requestOf, type ParameterRequest } from "./context";
import { Failure } from "./failure";
import { DONE, type Provider, type Session } from "./provider";
import deleteSample from "./samples/delete.json" with { type: "json" };
import notifySample from "./samples/notify.json" with { type: "json" };
import retrieveSample from "./samples/retrieve.json" with { type: "json" };
import storeSample from "./samples/store.json" with { type: "json" };

export interface WorkerConfig {
  package: { name: string; version: string };
  /** The notification sources the agent routes here. */
  sources: string[];
}

export const ACTIONS = ["store", "retrieve", "delete", "notify"] as const;
export type Action = (typeof ACTIONS)[number];

const SAMPLES: Record<Action, Payload> = { store: storeSample.notification, retrieve: retrieveSample.notification, delete: deleteSample.notification, notify: notifySample.notification };

/** The request and the backend it names; a backend the image does not carry is refused by name. */
export function routed(providers: ReadonlyMap<string, Provider>, payload: Payload): { request: ParameterRequest; provider: Provider } {
  const request = requestOf(payload);
  const provider = providers.get(request.provider.slug);
  if (!provider) {
    throw new Failure("UNKNOWN_PROVIDER", {
      what: `The parameter is bound to ${request.provider.slug}, and this worker serves ${[...providers.keys()].join(", ")}`,
      causes: ["The provider specification is not one this image implements", "The worker image is older than the provider"],
      fixes: [`Update the parameters worker to a version that implements ${request.provider.slug}`],
    });
  }
  return { request, provider };
}

async function perform(session: Session, action: Action, request: ParameterRequest): Promise<unknown> {
  if (action === "notify") {
    return session.notify ? session.notify(request) : DONE;
  }
  return session[action](request);
}

export function parametersWorker(providers: Provider[], config: WorkerConfig) {
  const bySlug = new Map(providers.map((provider) => [provider.slug, provider] as const));
  const slugs = [...bySlug.keys()];
  const channel = { source: config.sources[0] ?? "service", filter: { $or: slugs.map((slug) => ({ "provider.specification_slug": slug })) } };
  const route = (action: Action): Route => ({
    name: `parameter:${action}`,
    match: where({ action: `parameter:${action}` }),
    output: () => "raw" as const,
    channel,
    sample: SAMPLES[action],
    handler: async (payload: Payload, context: Context) => {
      const { request, provider } = routed(bySlug, payload);
      const session = await provider.open(request, context);
      return perform(session, action, request);
    },
  });
  return definePlugin({
    package: { name: config.package.name, version: config.package.version, description: `Parameters and secrets stored in ${slugs.join(", ")}` },
    agent: { sources: config.sources },
    routes: ACTIONS.map(route),
  });
}
