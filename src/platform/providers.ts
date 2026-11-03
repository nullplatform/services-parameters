/**
 * The platform's provider of a category over an NRN, chosen as the CLI's
 * `np provider list --categories` chooses it, which the bash scripts relied on:
 * the category's specifications at the NRN, every provider of those
 * specifications visible from it (its ascendants included) whose dimensions
 * do not contradict the request's, and the best match: the longest NRN, then
 * the most dimensions the request asked for, then the fewest it never asked
 * about, then the lowest id. A listing carries no attributes, so the winner
 * is read whole. Providers change rarely and every action reads one, so a
 * resolution is remembered for a short while per category, NRN and
 * dimensions.
 */

import type { Api } from "@nullplatform/plugin";

interface Listing<Item> {
  results?: Item[];
}

interface Category {
  id: string;
  slug: string;
}

interface Specification {
  id: string;
}

export interface ProviderRow {
  id: string;
  nrn: string;
  specification_id: string;
  dimensions?: Record<string, unknown>;
}

export interface Provider extends ProviderRow {
  attributes?: Record<string, unknown>;
}

interface Fit {
  matched: number;
  unasked: number;
}

/** The dimensions as the API's `dimensions` query spells them: `key:value`, sorted, comma-separated. */
export function dimensionsQuery(dimensions: Record<string, string>): string {
  return Object.keys(dimensions)
    .sort()
    .map((key) => `${key}:${dimensions[key]}`)
    .join(",");
}

/** How `provider` fits a request of `dimensions`: none when one of its own differs, else what it matched and what the request never asked. */
export function dimensionFit(provider: ProviderRow, dimensions: Record<string, string>): Fit | undefined {
  const fit: Fit = { matched: 0, unasked: 0 };
  for (const [key, value] of Object.entries(provider.dimensions ?? {})) {
    if (!(key in dimensions)) {
      fit.unasked += 1;
      continue;
    }
    if (dimensions[key] !== value) {
      return undefined;
    }
    fit.matched += 1;
  }
  return fit;
}

/** The better of two fitting providers: the longer NRN, then the more matched, then the fewer unasked, then the lower id. */
export function betterProvider(left: ProviderRow, right: ProviderRow, dimensions: Record<string, string>): ProviderRow {
  if (left.nrn.length !== right.nrn.length) {
    return left.nrn.length > right.nrn.length ? left : right;
  }
  const fits = [dimensionFit(left, dimensions), dimensionFit(right, dimensions)] as [Fit, Fit];
  if (fits[0].matched !== fits[1].matched) {
    return fits[0].matched > fits[1].matched ? left : right;
  }
  if (fits[0].unasked !== fits[1].unasked) {
    return fits[0].unasked < fits[1].unasked ? left : right;
  }
  return left.id <= right.id ? left : right;
}

/** How long a resolution is reused, per category, NRN and dimensions. */
export const REMEMBER_MS = 60_000;

interface Remembered {
  at: number;
  provider: Promise<Provider | undefined>;
}

const remembered = new Map<string, Remembered>();

/** Forgets every resolution: after a provider was changed, or between tests. */
export function forgetProviders(): void {
  remembered.clear();
}

/** The provider of `category` over `nrn` for a request of `dimensions`, whole; undefined when none is configured. Resolved once per REMEMBER_MS; a failed resolution is not kept. */
export function providerOf(
  api: Api,
  category: string,
  nrn: string,
  dimensions: Record<string, string>,
  now: () => number = Date.now,
): Promise<Provider | undefined> {
  const key = `${category}|${nrn}|${dimensionsQuery(dimensions)}`;
  const kept = remembered.get(key);
  if (kept && now() - kept.at < REMEMBER_MS) {
    return kept.provider;
  }
  const provider = resolveProvider(api, category, nrn, dimensions);
  remembered.set(key, { at: now(), provider });
  provider.catch(() => remembered.delete(key));
  return provider;
}

async function resolveProvider(
  api: Api,
  category: string,
  nrn: string,
  dimensions: Record<string, string>,
): Promise<Provider | undefined> {
  const categories = (await api.category.get<Listing<Category>>({ slug: category })).results ?? [];
  if (categories.length === 0) {
    return undefined;
  }
  const specifications =
    (
      await api.provider_specification.get<Listing<Specification>>({
        category: categories.map((found) => found.id).join(","),
        nrn,
      })
    ).results ?? [];
  if (specifications.length === 0) {
    return undefined;
  }
  const query = dimensionsQuery(dimensions);
  const candidates = await api.provider.get<Listing<ProviderRow>>({
    nrn,
    specification_id: specifications.map((specification) => specification.id).join(","),
    show_ascendants: true,
    ...(query === "" ? {} : { dimensions: query }),
  });
  let winner: ProviderRow | undefined;
  for (const candidate of candidates.results ?? []) {
    if (!candidate.nrn || dimensionFit(candidate, dimensions) === undefined) {
      continue;
    }
    winner = winner === undefined ? candidate : betterProvider(winner, candidate, dimensions);
  }
  return winner === undefined ? undefined : api.provider(winner.id).get<Provider>();
}
