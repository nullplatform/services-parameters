/**
 * The worker of one backend: four raw routes, `parameter:store`,
 * `parameter:retrieve`, `parameter:delete` and `parameter:notify`, each
 * reading the request from the notification, refusing one meant for another
 * backend, opening the provider's session and answering what the operation
 * returns. One image per backend carries one of these, with that backend's
 * client alone.
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

/** The request, when it is for `provider`; one for another backend is refused with both names. */
export function requestFor(provider: Provider, payload: Payload): ParameterRequest {
  const request = requestOf(payload);
  if (request.provider.slug !== provider.slug) {
    throw new Failure("WRONG_PROVIDER", {
      what: `This worker stores parameters in ${provider.slug}, and the parameter is bound to ${request.provider.slug}`,
      causes: ["The notification channel routes another provider's parameters to this worker"],
      fixes: [`Point the channel of ${request.provider.slug} at its own worker image`],
    });
  }
  return request;
}

async function perform(session: Session, action: Action, request: ParameterRequest): Promise<unknown> {
  if (action === "notify") {
    return session.notify ? session.notify(request) : DONE;
  }
  return session[action](request);
}

export function parametersWorker(provider: Provider, config: WorkerConfig) {
  const channel = { source: config.sources[0] ?? "service", filter: { "provider.specification_slug": provider.slug } };
  const route = (action: Action): Route => ({
    name: `parameter:${action}`,
    match: where({ action: `parameter:${action}` }),
    output: () => "raw" as const,
    channel,
    sample: SAMPLES[action],
    handler: async (payload: Payload, context: Context) => {
      const request = requestFor(provider, payload);
      const session = await provider.open(request, context);
      return perform(session, action, request);
    },
  });
  return definePlugin({
    package: { name: config.package.name, version: config.package.version, description: `Parameters and secrets stored in ${provider.slug}` },
    agent: { sources: config.sources },
    routes: ACTIONS.map(route),
  });
}
