/**
 * How an operation fails: in the words the bash scripts used, so what an
 * operator reads in the platform does not change. A failure names what went
 * wrong, the likely causes, how to fix it and, when a backend answered, what
 * it said. It is the action's failure, with a code the platform keeps.
 */

import { ActionError } from "@nullplatform/plugin";

export interface Trouble {
  /** What went wrong, one line. */
  what: string;
  causes?: string[];
  fixes?: string[];
  /** What the backend answered, when it did. */
  underlying?: string;
}

/** The message as the bash printed it: the problem, the causes, the fixes, the backend's words. */
export function troubleMessage(trouble: Trouble): string {
  const lines = [`❌ ${trouble.what}`];
  if (trouble.causes && trouble.causes.length > 0) {
    lines.push("", "💡 Possible causes:", ...trouble.causes.map((cause) => `   • ${cause}`));
  }
  if (trouble.fixes && trouble.fixes.length > 0) {
    lines.push("", "🔧 How to fix:", ...trouble.fixes.map((fix) => `   • ${fix}`));
  }
  if (trouble.underlying) {
    lines.push(`Underlying error: ${trouble.underlying}`);
  }
  return lines.join("\n");
}

export class Failure extends ActionError {
  constructor(
    code: string,
    readonly trouble: Trouble,
  ) {
    super(code, troubleMessage(trouble));
  }
}

/** A failure's cause as text, whatever was thrown. */
export const messageOf = (error: unknown): string => (error instanceof Error ? error.message : String(error));
