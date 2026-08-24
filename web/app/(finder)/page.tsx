import { DesktopOnly } from "@/components/desktop-only";
import { GraphLanding } from "@/components/graph-landing";
import { MapLanding } from "@/components/map-landing";
import { fetchCorpusGraph } from "@/lib/graph";
import { fetchListingsResult } from "@/lib/listings";

/**
 * The "/" right pane — the landing shown before any document is opened. It is
 * the `children` segment for "/" (the <Finder> itself lives in the layout's
 * left rail, so opening a doc never remounts it).
 *
 * Two landings share this surface, picked by `NEXT_PUBLIC_FINDER_LANDING`:
 *
 *   - default / "graph" — the Barkpark docs demo: an Obsidian-style interactive
 *     graph of the docs corpus (built by `lib/graph.fetchCorpusGraph`, rendered
 *     by the vanilla Canvas2D renderer in `public/bp-graph.js`).
 *   - "map" — the place-directory template demo: a map of every listing
 *     (sourced by `lib/listings.fetchListings`, rendered by the self-contained
 *     Canvas2D map in `components/listings-map`).
 *
 * The map is opt-in so the stock web demo keeps its graph landing — the
 * place-directory template (`templates/place-directory`) is what flips the env
 * var. Both code paths stay in the tree; this is a config switch, not a swap.
 *
 * On mobile the finder owns the full screen, so the heavy pointer/pan surface is
 * hidden below `md` and a short hint takes its place either way.
 */
export default async function FinderLanding() {
  const landing = process.env.NEXT_PUBLIC_FINDER_LANDING;

  if (landing === "map") {
    return <MapFinderLanding />;
  }

  return <GraphFinderLanding />;
}

/** The place-directory template demo: an interactive map of listings. */
async function MapFinderLanding() {
  // `substituted` is true ONLY when a live source was configured and then
  // replaced by the bundled sample pins — a broken or empty upstream
  // (task-78bd64a68c6de26f). It is false out of the box, where the samples ARE
  // the intended template content and a warning would be noise. Mirrors how the
  // graph landing surfaces `truncated` / `truncationReason` below.
  const { listings, substituted, source } = await fetchListingsResult();

  return (
    <>
      {/* Desktop: the map fills the pane. The layout's <section> is a definite-
          height flex child, so `h-full` here resolves to a real pixel height —
          the canvas needs that to size itself (no layout shift). The <DesktopOnly>
          gate means the heavy Canvas2D map never even MOUNTS below `md` — CSS
          `hidden` alone would still run its client code on phones. */}
      <div className="relative hidden h-full w-full md:block">
        {substituted && <SampleListingsNotice source={source} />}
        <DesktopOnly>
          <MapLanding listings={listings} />
        </DesktopOnly>
      </div>

      {/* Mobile fallback: a short hint instead of the pan-heavy map. */}
      <div className="flex h-full flex-col items-center justify-center gap-4 px-8 text-center md:hidden">
        <div
          aria-hidden
          className="text-4xl text-zinc-300 select-none dark:text-zinc-700"
        >
          ←
        </div>
        <p className="max-w-xs text-sm text-zinc-500 dark:text-zinc-400">
          Search above to find a listing, then tap a result to open it here.
        </p>
        <p className="max-w-xs text-xs text-zinc-400 dark:text-zinc-600">
          The interactive map is available on a wider screen.
        </p>
      </div>
    </>
  );
}

/** The default Barkpark docs demo: an interactive graph of the docs corpus. */
async function GraphFinderLanding() {
  const { nodes, edges, rootId, truncated, truncationReason } =
    await fetchCorpusGraph();

  return (
    <>
      {/* Desktop: the graph fills the pane. The layout's <section> is a definite-
          height flex child, so `h-full` here resolves to a real pixel height —
          the renderer's canvas needs that to size itself (no layout shift). The
          <DesktopOnly> gate means <GraphView>'s <Script src="/bp-graph.js">
          (~131 KB) never mounts below `md` — CSS `hidden` would still download +
          execute it on phones where nothing is shown. */}
      <div className="hidden h-full w-full md:block">
        <DesktopOnly>
          <GraphLanding
            nodes={nodes}
            edges={edges}
            rootId={rootId}
            truncated={truncated}
            truncationReason={truncationReason}
          />
        </DesktopOnly>
      </div>

      {/* Mobile fallback: a short hint instead of the pointer-heavy graph. */}
      <div className="flex h-full flex-col items-center justify-center gap-4 px-8 text-center md:hidden">
        <div
          aria-hidden
          className="text-4xl text-zinc-300 select-none dark:text-zinc-700"
        >
          ←
        </div>
        <p className="max-w-xs text-sm text-zinc-500 dark:text-zinc-400">
          Search above to find a document, then tap a result to read it here.
        </p>
        <p className="max-w-xs text-xs text-zinc-400 dark:text-zinc-600">
          The interactive documentation graph is available on a wider screen.
        </p>
      </div>
    </>
  );
}

/**
 * Says out loud that the map is drawing PLACEHOLDER pins, not the operator's
 * dataset. Rendered only for `sample:failed` / `sample:empty` — never for the
 * out-of-the-box `sample:unconfigured` case, where the sample rows are the
 * product. Before this, a deployment with a broken `LISTINGS_TYPE` drew exactly
 * the same map as a working one (task-78bd64a68c6de26f).
 */
function SampleListingsNotice({ source }: { source: string }) {
  const why =
    source === "sample:empty"
      ? "the configured source matched no rows"
      : "the configured source could not be reached";

  return (
    <div
      role="status"
      className="pointer-events-none absolute inset-x-0 top-0 z-10 flex justify-center p-3"
    >
      <p className="pointer-events-auto rounded-full border border-amber-300/70 bg-amber-50/95 px-3 py-1 text-xs font-medium text-amber-900 shadow-sm backdrop-blur dark:border-amber-500/40 dark:bg-amber-950/90 dark:text-amber-200">
        Showing sample listings — {why}. Check the server log for details.
      </p>
    </div>
  );
}
