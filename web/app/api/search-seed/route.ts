import { NextResponse } from "next/server";
import { runSearch } from "@/lib/find-search";
import { DEFAULT_ENGINE } from "@/lib/find";
import { buildPrefixSeed, type PrefixSeed, type SeedDoc } from "@/lib/prefix-seed";

/**
 * `/api/search-seed` — the HTTP-fetchable equivalent of the prefix index the
 * finder uses to resolve 1–2 character queries LOCALLY in 0ms, before the
 * live reply arrives.
 *
 * CONSUMER TOPOLOGY (measured, not aspirational): the finder does NOT read
 * this route. Its SSR seed is built independently in
 * `app/(finder)/layout.tsx`, which calls `buildPrefixSeed` over the
 * `DEFAULT_ENGINE` browse it ALREADY issues for the first paint — reusing
 * that read instead of paying a second engine round-trip — and inlines the
 * result as a prop on `<Finder>`. What THIS route serves is the same
 * construction as a fetchable endpoint for tooling / diagnostics: `buildSeed`
 * below issues its own `DEFAULT_ENGINE` browse and runs the same
 * `buildPrefixSeed` over it, so the payload carries the same engine ordering
 * and the same caps (see `lib/prefix-seed.ts`) as the seed the finder
 * actually inlines.
 *
 * The seed is small (~10–20 KB for 100 docs, capped per prefix) and changes
 * only when the corpus changes, so we cache it on the server for an hour —
 * except on a build failure, where GET answers 503 + no-store below.
 */
export const runtime = "nodejs";
export const revalidate = 3600;

/**
 * The seed, plus the field that says where an EMPTY seed came from.
 *
 * `{index:{},docs:[]}` has two entirely different causes — a corpus with
 * nothing in it, and an engine that never answered — and the consumer this
 * route declares above (tooling / diagnostics, over HTTP) has no other way to
 * tell them apart: it does not see the exception, it sees the body. So the
 * cause rides in the body, and `error` is the only field an empty index can be
 * read through. It stays a `PrefixSeed` structurally, so the SSR/browser
 * consumers that only read `index` + `docs` are unaffected.
 */
export interface SeedPayload extends PrefixSeed {
  /** Null when the seed descends from an engine answer; the reason when it
   * descends from a failure instead. */
  error: string | null;
}

export async function GET(): Promise<NextResponse> {
  const seed = await buildSeed();
  if (seed.error) {
    // The declared consumer is tooling / diagnostics, and no browser path
    // fetches this route (the keystroke path reads the inlined SSR prop), so a
    // failing seed is reported on the status line as well as in the body —
    // `res.ok` is the check a diagnostics client writes first, and an empty
    // index served 200 would read as a healthy empty corpus. `no-store` keeps
    // the hour-long edge cache from pinning a failure that lasted seconds.
    return NextResponse.json(seed, {
      status: 503,
      headers: { "Cache-Control": "no-store" },
    });
  }
  return NextResponse.json(seed, {
    headers: {
      "Cache-Control": "public, max-age=60, s-maxage=3600",
    },
  });
}

/**
 * Server-side seed builder for this route (exported for the receipt tests —
 * nothing else imports it; the (finder) layout builds its own seed from the
 * browse it already has, see the consumer topology above).
 *
 * `DEFAULT_ENGINE` deliberately mirrors the layout's browse engine so the
 * fetchable seed and the inlined seed descend from the same relevance
 * ordering — this route hardcoding a DIFFERENT engine is exactly the drift
 * the engine-parity arm of search-seed-receipt.test.ts reds on.
 */
export async function buildSeed(): Promise<SeedPayload> {
  try {
    const browse = await runSearch({ q: " ", engine: DEFAULT_ENGINE, browse: true });
    const docs: SeedDoc[] = browse.hits.map((h) => ({
      id: h.id,
      title: h.title,
      slug: h.slug,
      type: h.type,
    }));
    return { ...buildPrefixSeed(docs), error: null };
  } catch (err) {
    // A seed failure must NOT break the page — the caller still gets an empty
    // index, and the finder simply doesn't get the 0ms head-start in this
    // session. What changes is that the empty index now carries the reason it
    // is empty instead of being indistinguishable from an empty corpus.
    console.error("search-seed build failed:", err);
    const message = err instanceof Error ? err.message : String(err);
    return { index: {}, docs: [], error: `seed build failed: ${message}` };
  }
}
