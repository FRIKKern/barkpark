import { Finder } from "@/components/finder";
import { DocumentNav } from "@/components/document-nav";
import { runSearch } from "@/lib/find-search";
import type { FindResponse } from "@/lib/find";
import { HoveredDocProvider } from "@/lib/hovered-doc-context";
import { FinderNavProvider } from "@/lib/finder-nav-context";

// Force-dynamic so the Finder's server-seeded browse renders straight into the
// HTML — no `useSearchParams` CSR-bailout skeleton, so the master column keeps
// the home's instant first paint. The seed is a direct (fresh) engine read on
// the server; the client then drives all subsequent searches against the engine.
export const dynamic = "force-dynamic";

/**
 * The split-view shell. The <Finder> lives HERE, in the layout — so opening a
 * document (which only swaps the `children` segment) never remounts it. Search
 * text, scroll position, and any in-flight query all survive a navigation into
 * `/d/[type]/[slug]`.
 *
 *   ┌──────────────┬───────────────────────────────┐
 *   │  <Finder>    │                               │
 *   │  (left rail) │   {children}  (the detail)    │
 *   │  scrolls     │   scrolls independently       │
 *   └──────────────┴───────────────────────────────┘
 *
 * `children` is a plain nested route (NOT a parallel slot): `/` renders the
 * welcome page, `/d/[type]/[slug]` renders the document. Keeping it `children`
 * (rather than an `@detail` slot) is what makes `notFound()` in the detail page
 * set a real HTTP 404 — a slot's notFound() does not, because the children
 * segment still resolves 200 underneath it.
 *
 * On mobile the rail is full-width; the open document mounts as a
 * `fixed inset-0 md:static` overlay (rendered by <DocumentDetail>), and the
 * welcome page hides itself (`hidden md:flex`) so the finder owns the small
 * screen until something is opened.
 */
export default async function FinderLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  // Seed the master finder with the default browse, same as the old home page.
  // Swallow origin hiccups → null lets the Finder fall back to its client fetch.
  const r = await runSearch({
    q: " ",
    engine: "indx",
    browse: true,
  }).catch(() => null);
  // Don't surface a stale prerendered latency number — the readout fills in on
  // the first live interaction (mirrors the retired home page).
  const initialData: FindResponse | null = r ? { ...r, upstreamMs: null } : null;

  return (
    <HoveredDocProvider>
      <FinderNavProvider>
        <div className="flex h-screen w-full overflow-hidden">
          <aside className="w-full shrink-0 overflow-y-auto border-r border-zinc-200 md:w-[480px] lg:w-[640px] xl:w-[860px] 2xl:w-[1080px] dark:border-zinc-800">
            <Finder
              variant="master"
              initialData={initialData}
              initialEngine="indx"
            />
          </aside>
          <DocumentNav>{children}</DocumentNav>
        </div>
      </FinderNavProvider>
    </HoveredDocProvider>
  );
}
