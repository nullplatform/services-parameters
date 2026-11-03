/**
 * Where a provider's settings come from, in the order the bash resolved them:
 * the provider's attributes in the payload first (the platform's
 * configuration), the worker's environment second (an operator's override,
 * and the only place for credentials), a default last.
 */

import { valueAt } from "./json";

export interface SettingSource {
  /** A dotted path into the provider's attributes, `setup.kms_key_id`. */
  attribute?: string;
  /** An environment variable. */
  variable?: string;
  fallback?: string;
}

/** The setting's value as text: the attribute when set, else the variable when set, else the fallback, else "". */
export function settingOf(
  attributes: Record<string, unknown>,
  env: Record<string, string | undefined>,
  source: SettingSource,
): string {
  if (source.attribute !== undefined) {
    const value = valueAt(attributes, source.attribute);
    if (value !== undefined && value !== null && value !== "") {
      return Array.isArray(value) ? value.join(",") : String(value);
    }
  }
  if (source.variable !== undefined && env[source.variable]) {
    return env[source.variable] as string;
  }
  return source.fallback ?? "";
}
