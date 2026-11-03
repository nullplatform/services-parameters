/**
 * Where a provider's settings come from, in the order the bash resolved them:
 * the provider's attributes in the payload first (the platform's
 * configuration), the worker's environment second (an operator's override,
 * and the only place for credentials), a default last.
 */

export interface SettingSource {
  /** A dotted path into the provider's attributes, `setup.kms_key_id`. */
  attribute?: string;
  /** An environment variable. */
  variable?: string;
  fallback?: string;
}

const at = (attributes: Record<string, unknown>, path: string): unknown =>
  path
    .split(".")
    .reduce<unknown>(
      (value, key) => (value && typeof value === "object" ? (value as Record<string, unknown>)[key] : undefined),
      attributes,
    );

/** The setting's value as text: the attribute when set, else the variable when set, else the fallback, else "". */
export function settingOf(
  attributes: Record<string, unknown>,
  env: Record<string, string | undefined>,
  source: SettingSource,
): string {
  if (source.attribute !== undefined) {
    const value = at(attributes, source.attribute);
    if (value !== undefined && value !== null && value !== "") {
      return Array.isArray(value) ? value.join(",") : String(value);
    }
  }
  if (source.variable !== undefined && env[source.variable]) {
    return env[source.variable] as string;
  }
  return source.fallback ?? "";
}
