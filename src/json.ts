/**
 * Reading JSON that comes from outside, a notification or a backend's answer,
 * without trusting its shape: a value as text, as an object, as a record of
 * texts, the value at a dotted path, and a body parsed or empty.
 */

export type JsonObject = Record<string, unknown>;

/** The value as text; null and undefined are "". */
export const text = (value: unknown): string => (value === null || value === undefined ? "" : String(value));

/** The value as an object; anything else, an array included, is {}. */
export const record = (value: unknown): JsonObject =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as JsonObject) : {};

/** The object's entries as text, those that are null or undefined left out. */
export const texts = (value: unknown): Record<string, string> =>
  Object.fromEntries(
    Object.entries(record(value))
      .filter(([, item]) => item !== null && item !== undefined)
      .map(([key, item]) => [key, String(item)]),
  );

/** The value at a dotted path, `data.data.value`; undefined where the path leaves the object. */
export const valueAt = (object: unknown, path: string): unknown =>
  path.split(".").reduce<unknown>((value, key) => record(value)[key], object);

/** The text parsed as a JSON object; {} when it is empty, malformed or not an object. */
export function parsedObject(body: string): JsonObject {
  try {
    return record(JSON.parse(body));
  } catch {
    return {};
  }
}
