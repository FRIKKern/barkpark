import { MapLanding } from "@/components/map-landing";
import { fetchListings } from "@/lib/listings";

/**
 * The "/" right pane — the landing shown before any listing is opened. It is
 * the `children` segment for "/" (the <Finder> itself lives in the layout's
 * left rail, so opening a listing never remounts it).
 *
 * On desktop this fills the pane with an interactive map of every listing
 * (sourced by `lib/listings.fetchListings`, rendered by the self-contained
 * Canvas2D map in `components/listings-map`). Searching in the left rail filters
 * the visible pins; clicking a pin opens its info popover. Replaces the old
 * documentation graph — the directory's headline surface is a map of places.
 *
 * On mobile the finder owns the full screen, so the map is hidden below `md`
 * and a short hint takes its place (a pan/zoom map doesn't pay its way on a
 * phone-width column behind the list).
 */
export default async function FinderLanding() {
  const listings = await fetchListings();

  return (
    <>
      {/* Desktop: the map fills the pane. The layout's <section> is a definite-
          height flex child, so `h-full` here resolves to a real pixel height —
          the canvas needs that to size itself (no layout shift). */}
      <div className="hidden h-full w-full md:block">
        <MapLanding listings={listings} />
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
