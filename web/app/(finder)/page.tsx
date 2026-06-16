import { GraphLanding } from "@/components/graph-landing";
import { fetchCorpusGraph } from "@/lib/graph";

/**
 * The "/" right pane — the landing shown before any document is opened. It is
 * the `children` segment for "/" (the <Finder> itself lives in the layout's
 * left rail, so opening a doc never remounts it).
 *
 * On desktop this fills the pane with an Obsidian-style interactive graph of the
 * docs corpus (built by `lib/graph.fetchCorpusGraph`, rendered by the vanilla
 * Canvas2D renderer in `public/bp-graph.js`). Clicking a node opens that
 * document in this same pane — navigation stays inside the (finder) route group,
 * so the finder sidebar + its query-string search state survive.
 *
 * On mobile the finder owns the full screen, so the graph is hidden below `md`
 * and a short hint takes its place (the graph is a pointer-rich surface that
 * doesn't pay its way on a phone-width column).
 */
export default async function FinderLanding() {
  const { nodes, edges, rootId } = await fetchCorpusGraph();

  return (
    <>
      {/* Desktop: the graph fills the pane. The layout's <section> is a definite-
          height flex child, so `h-full` here resolves to a real pixel height —
          the renderer's canvas needs that to size itself (no layout shift). */}
      <div className="hidden h-full w-full md:block">
        <GraphLanding nodes={nodes} edges={edges} rootId={rootId} />
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
