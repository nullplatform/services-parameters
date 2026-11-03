/**
 * What a backend is to the worker. A provider opens a session for one
 * request, validating its configuration and credentials once (the bash's
 * `setup`), and the session does the operation: store, retrieve, delete, and
 * notify when the backend has anything to do on it. Each operation answers
 * the JSON the platform reads, in the same shape the bash printed.
 */

import type { Context, Logger } from "@nullplatform/plugin";
import { handleOf, type ParameterRequest } from "./context";
import { messageOf } from "./failure";

export interface Stored {
  external_id: string;
  metadata: Record<string, unknown>;
}

export interface Retrieved {
  value: string;
}

/** The values of a batch that could be read; one left out is retrieved by the platform on its own. */
export interface RetrievedBatch {
  values: Array<{ external_id: string; value: string }>;
}

export interface Done {
  success: true;
}

export interface Session {
  store(request: ParameterRequest): Promise<Stored>;
  retrieve(request: ParameterRequest): Promise<Retrieved>;
  /** Several values of one request's provider and entities in one call; a backend without it answers NOT_IMPLEMENTED and the platform retrieves them one by one. */
  retrieveBatch?(requests: ParameterRequest[]): Promise<RetrievedBatch>;
  delete(request: ParameterRequest): Promise<Done>;
  /** A per-provider side effect on notify; none answers the default ack. */
  notify?(request: ParameterRequest): Promise<Done>;
}

export interface Provider {
  /** The provider specification's slug, what the platform names in `provider.specification_slug`. */
  slug: string;
  open(request: ParameterRequest, context: Context): Promise<Session>;
}

export const DONE: Done = { success: true };

/** `items` in groups of `size`, in order. */
export const chunks = <Item>(items: Item[], size: number): Item[][] =>
  Array.from({ length: Math.ceil(items.length / size) }, (_, index) => items.slice(index * size, (index + 1) * size));

/** How many single reads a batch runs at once in a backend without a batch read. */
export const BATCH_CONCURRENCY = 10;

/** The values of `requests` read one by one through `session.retrieve`, `limit` at a time; one that fails is logged and left out, and the platform retrieves it on its own. */
export async function retrieveEach(
  session: Pick<Session, "retrieve">,
  requests: ParameterRequest[],
  log: Logger,
  limit = BATCH_CONCURRENCY,
): Promise<RetrievedBatch> {
  const values: RetrievedBatch["values"] = [];
  const pending = [...requests];
  const read = async (): Promise<void> => {
    for (let request = pending.shift(); request; request = pending.shift()) {
      try {
        const { value } = await session.retrieve(request);
        values.push({ external_id: handleOf(request.externalId.path, request.externalId.version), value });
      } catch (error) {
        log.warn(`'${request.externalId.path}' left out of the batch: ${messageOf(error)}`);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, requests.length) }, read));
  return { values };
}
