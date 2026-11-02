/**
 * What an image is to the agent, read from its environment: the package the
 * agent's pin names (`parameters` unless the image says otherwise),
 * its version, and the notification sources routed to it.
 */

import type { WorkerConfig } from "./worker";

const list = (value: string | undefined): string[] => (value ?? "").split(",").map((item) => item.trim()).filter(Boolean);

export function workerConfigOf(env: Record<string, string | undefined> = process.env): WorkerConfig {
  return {
    package: { name: env.NP_PACKAGE_NAME || "parameters", version: env.NP_PACKAGE_VERSION || "0.0.0" },
    sources: env.NP_AGENT_SOURCES ? list(env.NP_AGENT_SOURCES) : ["service"],
  };
}
