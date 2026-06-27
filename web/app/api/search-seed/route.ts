import { NextResponse } from "next/server";
import { runSearch } from "@/lib/find-search";
import { buildPrefixSeed, type PrefixSeed, type SeedDoc } from "@/lib/prefix-seed";

/**
 * `/api/search-seed` — emits the bundled prefix index the finder uses to
 * resolve 1–2 character queries LOCALLY in 0ms, before the live WebSocket
 * reply arrives. The seed is built from the same ranked browse the landing
 * already issues (`runSearch({ q: " ", browse: true })`), so it inherits the
 * engine's relevance ordering for free — no parallel ranking pipeline.
 *
 * The seed is small (~10–20 KB for 100 docs, capped per prefix) and changes
 * only when the corpus changes, so we cache it on the server for an hour.
 * The browser path: the (finder) layout reads this seed during SSR and
 * inlines it as a prop on `<Finder>` — so the first paint already carries the
 * prefix index, NO client round-trip is required on the keystroke path.
 *
 * This route exists as the canonical materializer (and an explicit fetchable
 * endpoint for tooling / diagnostics) — the keystroke-path consumer is the
 * inlined prop, not a runtime fetch from the browser.
 */
export const runtime = "nodejs";
export const revalidate = 3600;

export async function GET(): Promise<NextResponse> {
  const seed = await buildSeed();
  return NextResponse.json(seed, {
    headers: {
      "Cache-Control": "public, max-age=60, s-maxage=3600",
    },
  });
}

/** Server-side seed builder — exported so the (finder) layout can call it
 * directly during SSR without the HTTP round-trip. */
export async function buildSeed(): Promise<PrefixSeed> {
  try {
    const browse = await runSearch({ q: " ", engine: "indx", browse: true });
    const docs: SeedDoc[] = browse.hits.map((h) => ({
      id: h.id,
      title: h.title,
      slug: h.slug,
      type: h.type,
    }));
    return buildPrefixSeed(docs);
  } catch {
    // A seed failure must NOT break the page — return an empty index. The
    // finder simply doesn't get the 0ms head-start in this session.
    return { index: {}, docs: [] };
  }
}
