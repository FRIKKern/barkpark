import { DesktopOnly } from "@/components/desktop-only";
import { GraphLanding } from "@/components/graph-landing";
import type { LandingProvenance } from "@/components/graph-landing";
import { MapLanding } from "@/components/map-landing";
import { API_URL_CONFIGURED } from "@/lib/bp-env";
import { corpusStatusMarker, fetchCorpusGraph } from "@/lib/graph";
import { fetchListings } from "@/lib/listings";
import { buildIdentity } from "@/lib/markers";

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
 * NO_MOBILE_FALLBACK — below `md` this page renders NOTHING, on purpose.
 *
 * The (finder) layout gives the left rail `w-full` on a phone, so this pane —
 * the layout's `flex-1` <section> — is laid out at x=390 in a 390px viewport,
 * inside an `overflow-hidden` parent. It is not merely small: it is entirely
 * off-screen and unreachable, with no scroll that can bring it back. The
 * `md:hidden` "← Search above, then tap a result" hint that used to live here
 * was therefore invisible to every phone visitor while still sitting in the
 * accessibility tree, narrating an interactive graph that a screen-reader user
 * could never reach (measured at 390x844: bounding box left=390..464).
 *
 * A hint the sighted user cannot see and the screen-reader user is misled by is
 * worse than no hint, and it has no honest home here — the visible column on a
 * phone belongs to <Finder>, which already shows the search box and a browse
 * list as its own idle state. So the heavy pointer/pan surface stays gated
 * behind `hidden md:block` + <DesktopOnly> and nothing replaces it.
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
  const listings = await fetchListings();
  // bp-doc-id HEALTH marker (content-truth): the first listing's id proves the
  // SSR rendered a real content document. Empty corpus → empty marker → the
  // deploy gate fails closed (a lost content link must not go live).
  const docId = listings[0]?.id ?? "";

  return (
    <>
      <meta name="bp-doc-id" content={docId} />
      {/* Desktop: the map fills the pane. The layout's <section> is a definite-
          height flex child, so `h-full` here resolves to a real pixel height —
          the canvas needs that to size itself (no layout shift). The <DesktopOnly>
          gate means the heavy Canvas2D map never even MOUNTS below `md` — CSS
          `hidden` alone would still run its client code on phones. */}
      <div className="hidden h-full w-full md:block">
        <DesktopOnly>
          <MapLanding listings={listings} />
        </DesktopOnly>
      </div>
      {/* No mobile fallback here — see NO_MOBILE_FALLBACK in the module doc. */}
    </>
  );
}

/** The default Barkpark docs demo: an interactive graph of the docs corpus. */
async function GraphFinderLanding() {
  const graph = await fetchCorpusGraph();
  const { nodes, edges, rootId, truncated, truncationReason } = graph;
  // bp-doc-id HEALTH marker (content-truth): the graph's anchor node id proves
  // the SSR rendered a real corpus. `rootId` prefers the highest-degree real
  // node; fall back to the first real (non-phantom) node id. Empty corpus →
  // empty marker → the deploy gate fails closed (charter D72 / fail-closed).
  const docId = rootId ?? nodes.find((n) => !n.phantom)?.doc_id ?? "";
  // bp-corpus-status HEALTH marker (cause-truth): emitted ONLY when the marker
  // above is empty, naming the upstream condition that emptied it (`graph 403:
  // …`, `graph 401: …`, `graph 0: …`, or the honest "read OK, nothing to
  // anchor"). It does NOT rescue the deploy — bp-doc-id stays empty and
  // `deploy/site-deploy-node.sh` still refuses to switch — it makes the refusal
  // legible, so the recorded failure_reason names the cause, not the symptom.
  const corpusStatus = corpusStatusMarker(graph, docId);

  // The HUMAN half of the same truth. Everything here is READ, never assumed:
  // `buildIdentity()` is the boot env with the HEALTH sentinels resolved to
  // null (so an undeployed build reads as a state, not as a build named "dev"),
  // `API_URL_CONFIGURED` is whether anyone actually pointed this site at a
  // corpus, and the upstream status/reason are the ones `fetchCorpusGraph`
  // carried out of its catch — which is what lets the landing say "could not
  // read the corpus" where an empty canvas used to imply "there is nothing
  // here". The COUNTS are not passed: <GraphLanding> derives them from the same
  // node array it renders, so the number and the picture cannot disagree.
  const provenance: LandingProvenance = {
    build: buildIdentity(),
    apiConfigured: API_URL_CONFIGURED,
    upstreamStatus: graph.upstreamStatus,
    upstreamReason: graph.upstreamReason,
  };

  return (
    <>
      <meta name="bp-doc-id" content={docId} />
      {corpusStatus !== "" && (
        <meta name="bp-corpus-status" content={corpusStatus} />
      )}
      {/* Desktop: the graph fills the pane. The layout's <section> is a definite-
          height flex child, so `h-full` here resolves to a real pixel height —
          the renderer's canvas needs that to size itself (no layout shift). The
          <DesktopOnly> gate means <GraphView>'s <Script src="/bp-graph.js">
          (~131 KB) never mounts below `md` — CSS `hidden` would still download +
          execute it on phones where nothing is shown. */}
      <div className="hidden h-full w-full md:block">
        <DesktopOnly>
          {/* truncated/truncationReason pass through so the landing's "showing
              a subset" note can actually fire — dropping them here was a
              complete dead prop path (stw9-graph-truncation-prop-wiring). */}
          <GraphLanding
            nodes={nodes}
            edges={edges}
            rootId={rootId}
            truncated={truncated}
            truncationReason={truncationReason}
            provenance={provenance}
          />
        </DesktopOnly>
      </div>
      {/* No mobile fallback here — see NO_MOBILE_FALLBACK in the module doc. */}
    </>
  );
}
