import { barkparkFetch as barkparkFetchWithOpts } from "@/lib/barkpark";

export const DEFAULT_REVALIDATE = 60;

export function barkparkFetch<T>(path: string): Promise<T> {
  return barkparkFetchWithOpts<T>(path, { revalidate: DEFAULT_REVALIDATE });
}
