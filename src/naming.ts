/**
 * The canonical path of a parameter: where an operator finds it in the
 * backend's own console knowing only its nullplatform context, without the
 * platform's database. The entities in NRN order, each `type=slug-id`, the
 * scope when the value is scoped, the dimensions sorted by key, then the
 * parameter's name and id. Every provider builds its name from it, with the
 * backend's own prefix and character rules; the handle nullplatform keeps is
 * the canonical form, the same across backends.
 */

import type { ParameterRequest } from "./context";

export const ENTITY_ORDER = ["organization", "account", "namespace", "application", "scope"] as const;

/** A name as AWS Secrets Manager and Parameter Store accept it: letters, digits, `.`, `_`, `-`; anything else is `_`. */
export const sanitizeForPath = (value: string): string => value.replace(/[^A-Za-z0-9._-]/g, "_");

/** The dimensions as `key=value` segments, sorted by key. */
export const dimensionSegments = (dimensions: Record<string, string>): string[] =>
  Object.keys(dimensions)
    .sort()
    .map((key) => `${key}=${dimensions[key]}`);

/** The parameter's own segment: `<name>-<id>`, the id alone when it has no name, nothing when it has no id. */
export function parameterSegment(
  request: ParameterRequest,
  sanitize: (value: string) => string = sanitizeForPath,
): string[] {
  if (request.name && request.parameterId) {
    return [`${sanitize(request.name)}-${request.parameterId}`];
  }
  return request.parameterId ? [request.parameterId] : [];
}

/** `organization=<slug>-<id>/account=…/application=…[/scope=…][/<dim>=<value>…]/<name>-<id>`. */
export function canonicalPath(request: ParameterRequest): string {
  const entities = ENTITY_ORDER.filter((entity) => request.entities[entity]).map(
    (entity) => `${entity}=${request.entities[`${entity}_slug`] ?? ""}-${request.entities[entity]}`,
  );
  return [...entities, ...dimensionSegments(request.dimensions), ...parameterSegment(request)].join("/");
}
