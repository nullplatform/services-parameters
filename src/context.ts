/**
 * What a parameter action asks, read from the notification the platform
 * sends: the parameter (its id, name, value, encoding, whether it is a
 * secret), the handle it was stored under, the provider chosen for it with
 * that provider's configuration, and the entities and dimensions its path is
 * built from. The platform decides the provider and sends its configuration
 * along, so a worker needs no configuration of its own beyond credentials.
 */

import type { Payload } from "@nullplatform/plugin";
import { Failure } from "./failure";

export type Kind = "secret" | "parameter" | "";

export interface ExternalId {
  /** The canonical path, what the backend's name is built from. */
  path: string;
  /** The backend's native version identifier, "" when none. */
  version: string;
}

export interface ParameterRequest {
  kind: Kind;
  parameterId: string;
  /** The value to store; "" on any other action. */
  value: string;
  name: string;
  encoding: string;
  externalId: ExternalId;
  provider: { slug: string; specificationId: string; attributes: Record<string, unknown> };
  /** The NRN's entities with their slugs: `value_entities` (a scope-level value) else `entities`. */
  entities: Record<string, string>;
  /** The parameter's dimensions, as sent. */
  dimensions: Record<string, string>;
  /** The value's dimensions, when the value is scoped: what the IAM provider is looked up with. */
  valueDimensions: Record<string, string>;
}

/** The handle split at its last `#`: the path and the version it carries. */
export function externalIdOf(handle: string): ExternalId {
  const at = handle.lastIndexOf("#");
  if (at < 0) {
    return { path: handle, version: "" };
  }
  return { path: handle.slice(0, at), version: handle.slice(at + 1) };
}

/** `external_id` as store returns it: the path, and the version after `#` when the backend gave one. */
export const handleOf = (path: string, version: string): string => (version ? `${path}#${version}` : path);

const text = (value: unknown): string => (value === null || value === undefined ? "" : String(value));
const record = (value: unknown): Record<string, unknown> => (value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {});
const texts = (value: unknown): Record<string, string> => Object.fromEntries(Object.entries(record(value)).filter(([, item]) => item !== null && item !== undefined).map(([key, item]) => [key, String(item)]));

/** The request a payload carries; a payload naming no provider is refused. */
export function requestOf(payload: Payload): ParameterRequest {
  const provider = record(payload.provider);
  const slug = text(provider.specification_slug);
  if (slug === "") {
    throw new Failure("MISSING_PROVIDER", {
      what: "Missing .provider.specification_slug in the notification",
      causes: ["The notification payload is malformed", "The parameter has no associated provider in nullplatform"],
      fixes: ["Verify the parameter has a provider configured"],
    });
  }
  const secret = payload.secret;
  return {
    kind: secret === true ? "secret" : secret === false ? "parameter" : "",
    parameterId: text(payload.parameter_id),
    value: text(payload.value),
    name: text(payload.parameter_name),
    encoding: text(payload.encoding),
    externalId: externalIdOf(text(payload.external_id)),
    provider: { slug, specificationId: text(provider.specification_id), attributes: record(provider.attributes) },
    entities: texts(payload.value_entities ?? payload.entities),
    dimensions: texts(payload.dimensions),
    valueDimensions: texts(payload.value_dimensions ?? payload.dimensions),
  };
}

/** The requests a `parameter:retrieve_batch` payload carries: its shared metadata with each of its `values`; a payload with none is refused. */
export function batchRequestsOf(payload: Payload): ParameterRequest[] {
  const shared = requestOf(payload);
  const values = Array.isArray(payload.values) ? (payload.values as unknown[]).map(record) : [];
  if (values.length === 0) {
    throw new Failure("MISSING_VALUES", {
      what: "A parameter:retrieve_batch notification carries no values",
      causes: ["The notification payload is malformed"],
      fixes: ["Send the values to retrieve in .values[], each with its external_id"],
    });
  }
  return values.map((value) => ({
    ...shared,
    kind: value.secret === true ? "secret" : value.secret === false ? "parameter" : "",
    name: text(value.parameter_name),
    encoding: text(value.encoding),
    externalId: externalIdOf(text(value.external_id)),
  }));
}

/** The NRN of the request's entities, the scope included when the value is scoped. */
export function nrnOf(request: ParameterRequest): string {
  const { entities } = request;
  const segments = ["organization", "account", "namespace", "application"].map((entity) => `${entity}=${entities[entity] ?? ""}`);
  if (entities.scope) {
    segments.push(`scope=${entities.scope}`);
  }
  return segments.join(":");
}
