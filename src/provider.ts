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

export interface Done {
  success: true;
}

export interface Session {
  store(request: ParameterRequest): Promise<Stored>;
  retrieve(request: ParameterRequest): Promise<Retrieved>;
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
