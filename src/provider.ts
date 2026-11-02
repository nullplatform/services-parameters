/**
 * What a backend is to the worker. A provider opens a session for one
 * request, validating its configuration and credentials once (the bash's
 * `setup`), and the session does the operation: store, retrieve, delete, and
 * notify when the backend has anything to do on it. Each operation answers
 * the JSON the platform reads, in the same shape the bash printed.
 */

import type { Context } from "@nullplatform/plugin";
import type { ParameterRequest } from "./context";

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
