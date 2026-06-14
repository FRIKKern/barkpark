import type { Metadata } from "next";
import { Finder } from "@/components/finder";
import { runSearch } from "@/lib/find-search";
import type { FindResponse, SearchEngine } from "@/lib/find";

export const metadata: Metadata = {
  title: "Barkpark — search the whole CMS",
  description:
    "A headless CMS demo: one content model behind a Go TUI, a Phoenix Studio, a JS SDK, and this Next.js app. Find any document across every type — Postgres precision or Indx fuzzy/typo-tolerant search.",
};

// Dynamic render so the initial browse results are server-rendered INTO the HTML
// (no post-hydration blank gap), while the actual data comes from `runSearch`'s
// 5-min Data Cache — so the per-request server work is a ~1ms cache read, not a
// round-trip. The cache key is shared with `/api/find`, so a warm landing and a
// warm client query hit the same entry.
export const dynamic = "force-dynamic";

type SP = Promise<{ q?: string; engine?: string }>;

/** The frontpage IS the finder. We pre-render the default browse (no query)
 * server-side so results paint in the first byte; a URL that already carries a
 * query is left to the client fetch (one less server round-trip on deep links).
 */
export default async function Home({ searchParams }: { searchParams: SP }) {
  const { q, engine: engineParam } = await searchParams;
  const engine: SearchEngine = engineParam === "postgres" ? "postgres" : "indx";

  let initialData: FindResponse | null = null;
  if (!q?.trim()) {
    try {
      const r = await runSearch({ q: " ", engine, browse: true, cacheOn: true });
      // Don't surface a stale server-side latency number on a prerendered seed —
      // the readout fills in on the first live interaction.
      initialData = { ...r, upstreamMs: null };
    } catch {
      initialData = null; // origin hiccup → fall back to the client fetch
    }
  }

  // No Suspense wrapper: the route is force-dynamic, so `searchParams` is known
  // server-side and the Finder renders WITH its seeded results in the first
  // paint — no skeleton-then-swap. (The audit showed the old skeleton fallback
  // was the home's only LCP outlier vs the single-shot reader pages.)
  return (
    <Finder variant="home" initialData={initialData} initialEngine={engine} />
  );
}
