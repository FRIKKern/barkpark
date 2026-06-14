"use client";

import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import {
  DOC_TYPES,
  ENGINES,
  FACET_DIMENSIONS,
  SORTS,
  typeLabel,
  type FindHit,
  type FindResponse,
  type PopularQuery,
  type SearchEngine,
  type SortId,
} from "@/lib/find";

/* ── small pieces ──────────────────────────────────────────────────────── */

function shortDate(value: string | null): string | null {
  if (!value) return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  // timeZone:"UTC" makes the formatted text identical on server and client —
  // without it the server (UTC) and the browser (local TZ) can render different
  // days near a date boundary, which is a React #418 hydration mismatch.
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d);
}

/** Safe client-side highlight — splits on matched terms, never injects HTML. */
function highlight(text: string, terms: string[]): ReactNode {
  const escaped = terms
    .filter(Boolean)
    .map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!escaped.length) return text;
  const re = new RegExp(`(${escaped.join("|")})`, "ig");
  const wanted = new Set(escaped.map((s) => s.toLowerCase()));
  return text.split(re).map((part, i) =>
    wanted.has(part.toLowerCase()) ? (
      <mark
        key={i}
        className="rounded bg-amber-200/70 px-0.5 text-inherit dark:bg-amber-400/30"
      >
        {part}
      </mark>
    ) : (
      <span key={i}>{part}</span>
    ),
  );
}

function TypeChip({ type }: { type: string }) {
  return (
    <span className="rounded-full bg-zinc-200/70 px-2 py-0.5 font-mono text-[0.7rem] uppercase tracking-wide text-zinc-500 dark:bg-zinc-800/70 dark:text-zinc-400">
      {type}
    </span>
  );
}

function ResultRow({
  hit,
  terms,
  master = false,
  queryString = "",
  selected = false,
}: {
  hit: FindHit;
  terms: string[];
  /** In master mode the row opens the doc in the right pane (no navigate-away)
   * and carries the live finder query params so search/engine state survives. */
  master?: boolean;
  /** Current finder query string (no leading `?`) — appended to the doc href so
   * the open doc and the finder's search params coexist in the URL. */
  queryString?: string;
  /** Whether this row is the doc currently open in the right pane. */
  selected?: boolean;
}) {
  const date = shortDate(hit.date);
  const inner = (
    <>
      <span className="flex items-center gap-2 text-lg font-medium tracking-tight">
        <span>{highlight(hit.title, terms)}</span>
        {hit.href ? (
          <span
            aria-hidden
            className="translate-x-0 text-zinc-400 opacity-0 transition-all group-hover:translate-x-1 group-hover:opacity-100"
          >
            →
          </span>
        ) : null}
      </span>
      {hit.excerpt ? (
        <span className="line-clamp-2 text-sm text-zinc-600 dark:text-zinc-400">
          {hit.excerpt}
        </span>
      ) : null}
      <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-zinc-400">
        <TypeChip type={hit.type} />
        {date ? <span>{date}</span> : null}
        {hit.slug ? <span className="font-mono">/{hit.slug}</span> : null}
        {!hit.href ? (
          <span className="italic text-zinc-400">view-only (no reader)</span>
        ) : null}
      </span>
    </>
  );

  const cls =
    "group -mx-3 flex flex-col gap-1.5 rounded-lg px-3 py-5 transition-colors";
  // Selected = the doc currently open in the right pane: a quiet highlight ring.
  const selectedCls = selected
    ? " bg-zinc-100 ring-1 ring-zinc-300 dark:bg-zinc-900/60 dark:ring-zinc-700"
    : " hover:bg-zinc-100 dark:hover:bg-zinc-900/60";

  if (!hit.href) return <div className={cls}>{inner}</div>;

  // Master mode: append the live finder query string so opening a doc preserves
  // search/engine/facets. Because <Finder> lives in the (finder) LAYOUT, this
  // navigation swaps only the `children` (detail) segment — the Finder never
  // remounts.
  const href = master && queryString ? `${hit.href}?${queryString}` : hit.href;
  return (
    <Link
      href={href}
      prefetch
      aria-current={selected ? "page" : undefined}
      className={`${cls}${selectedCls}`}
    >
      {inner}
    </Link>
  );
}

/* ── main ──────────────────────────────────────────────────────────────── */

export function Finder({
  variant = "page",
  initialData = null,
  initialEngine = "indx",
}: {
  variant?: "page" | "home" | "master";
  /** Server-rendered browse result for the landing — seeds the first paint so
   * results show in the initial HTML instead of after a client round-trip. */
  initialData?: FindResponse | null;
  initialEngine?: SearchEngine;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const sp = useSearchParams();

  // Master mode: left column inside the (finder) layout; rows open docs in the
  // right @detail slot via in-place navigation (no remount, no full reload).
  const master = variant === "master";
  // Live finder params (q/engine/cache/sort/facets) — appended to each row's
  // doc href so the open doc and the search state coexist in the URL path+query.
  const currentQueryString = sp.toString();

  const q = sp.get("q") ?? "";
  // Default to Indx — the landing then showcases native facets + fuzzy recall.
  const engine: SearchEngine = sp.get("engine") === "postgres" ? "postgres" : "indx";
  // Cache mode: off by default (always-fresh baseline); on → Next Data Cache.
  const cacheOn = sp.get("cache") === "on";
  const sort: SortId = SORTS.some((s) => s.id === sp.get("sort"))
    ? (sp.get("sort") as SortId)
    : "relevance";
  // Multi-dimension facet selection — one URL param per dimension.
  const selectedFacets = useMemo(() => {
    const m: Record<string, Set<string>> = {};
    for (const { key } of FACET_DIMENSIONS) {
      const vals = (sp.get(key) ?? "").split(",").filter(Boolean);
      if (vals.length) m[key] = new Set(vals);
    }
    return m;
  }, [sp]);

  const setParams = useCallback(
    (patch: Record<string, string | null>) => {
      const next = new URLSearchParams(sp.toString());
      for (const [k, v] of Object.entries(patch)) {
        if (v === null || v === "") next.delete(k);
        else next.set(k, v);
      }
      const qs = next.toString();
      router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
    },
    [router, pathname, sp],
  );

  // Input is local + debounced into the URL's `q` (the source of truth).
  const [input, setInput] = useState(q);
  const [syncedQ, setSyncedQ] = useState(q);
  // When the URL's q changes externally (popular chip, back nav), pull it into
  // the box — done during render via React's previous-state pattern, not an
  // effect (avoids a cascading-render setState-in-effect).
  if (q !== syncedQ) {
    setSyncedQ(q);
    setInput(q);
  }
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => {
    if (input === q) return;
    clearTimeout(timer.current);
    timer.current = setTimeout(() => setParams({ q: input || null }), 250);
    return () => clearTimeout(timer.current);
  }, [input, q, setParams]);

  // Fetch whenever the committed query or engine changes. `loading` is derived
  // (the in-flight key differs from the resolved result's key) so the effect
  // never calls setState synchronously — only inside the async resolution.
  // `bust` lets "reset cache" force a cold refetch after revalidateTag.
  const [bust, setBust] = useState(0);
  const reqKey = `${engine} ${cacheOn ? "c" : "f"} ${bust} ${q}`;
  // Key the server-rendered seed corresponds to: the landing (cache off, bust 0,
  // empty query) on the page's engine. When it matches `reqKey` on mount we use
  // the seed instead of refetching — the first paint already has the results.
  const seedKey = initialData ? `${initialEngine} f 0 ` : null;
  const [result, setResult] = useState<{
    key: string;
    data: FindResponse;
    roundTripMs: number | null;
    prerendered?: boolean;
  } | null>(
    initialData && seedKey
      ? { key: seedKey, data: initialData, roundTripMs: null, prerendered: true }
      : null,
  );
  const loading = result?.key !== reqKey;
  const consumedSeed = useRef(false);
  useEffect(() => {
    // First mount: if the server already rendered exactly this view, keep the
    // seed and skip the round-trip. Any later param change always fetches.
    if (!consumedSeed.current) {
      consumedSeed.current = true;
      if (seedKey && reqKey === seedKey) return;
    }
    const ctrl = new AbortController();
    const params = new URLSearchParams({ engine });
    if (q) params.set("q", q);
    if (cacheOn) params.set("cache", "on");
    const t0 = performance.now();
    fetch(`/api/find?${params.toString()}`, { signal: ctrl.signal })
      .then((r) => r.json())
      .then((d: FindResponse) =>
        setResult({
          key: reqKey,
          data: d,
          roundTripMs: Math.round(performance.now() - t0),
        }),
      )
      .catch((e) => {
        if ((e as Error).name !== "AbortError") {
          setResult({
            key: reqKey,
            roundTripMs: Math.round(performance.now() - t0),
            data: {
              mode: q ? "search" : "browse",
              hits: [],
              total: 0,
              engine,
              engineUsed: engine,
              indxUnavailable: false,
              facets: null,
              truncation: null,
              parsedQuery: null,
              recovery: null,
              ms: null,
              cache: cacheOn,
              upstreamMs: null,
              error: (e as Error).message,
            },
          });
        }
      });
    return () => ctrl.abort();
  }, [reqKey, engine, q, cacheOn, seedKey]);
  const data = result?.data ?? null;
  const roundTripMs = result?.key === reqKey ? result.roundTripMs : null;
  // Stale-while-revalidate: only blank to a skeleton when there's NOTHING to
  // show. Once we have any result, a new query keeps the old list visible
  // (dimmed) until the fresh one lands — the search feels continuous.
  const showSkeleton = loading && !data;
  const prerendered = result?.key === reqKey && result.prerendered === true;

  // Popular past queries (search-intelligence) — shown when the box is empty.
  const [popular, setPopular] = useState<PopularQuery[]>([]);
  useEffect(() => {
    fetch("/api/find?suggest=1")
      .then((r) => r.json())
      .then((d: { popular?: PopularQuery[] }) =>
        setPopular((d.popular ?? []).filter((p) => p.query).slice(0, 6)),
      )
      .catch(() => {});
  }, []);

  const hits = useMemo(() => data?.hits ?? [], [data]);

  // Facet groups: prefer Indx's dataset-wide buckets; fall back to a client
  // type-count when the engine returned none (Postgres path).
  const facetsFromIndx = Boolean(data?.facets);
  const facetGroups = useMemo(() => {
    if (data?.facets) {
      return FACET_DIMENSIONS.map(({ key, label }) => ({
        key,
        label,
        buckets: data.facets![key] ?? [],
      })).filter((g) => g.buckets.length > 0);
    }
    const counts = new Map<string, number>();
    for (const h of hits) counts.set(h.type, (counts.get(h.type) ?? 0) + 1);
    const buckets = DOC_TYPES.map((t) => ({
      label: t.type,
      count: counts.get(t.type) ?? 0,
    })).filter((b) => b.count > 0);
    return buckets.length ? [{ key: "type", label: "Type", buckets }] : [];
  }, [data, hits]);

  const facetCount = Object.values(selectedFacets).reduce((n, s) => n + s.size, 0);

  const visibleHits = useMemo(() => {
    let out = hits;
    for (const [dim, vals] of Object.entries(selectedFacets)) {
      out = out.filter((h) => vals.has(h.facets[dim] ?? ""));
    }
    if (sort === "newest") {
      out = [...out].sort((a, b) => (b.date ?? "").localeCompare(a.date ?? ""));
    } else if (sort === "title") {
      out = [...out].sort((a, b) => a.title.localeCompare(b.title));
    }
    return out;
  }, [hits, selectedFacets, sort]);

  // Indx coverage boundary — only meaningful over the unfiltered,
  // relevance-ordered result set of a real query (not browse/recovery).
  const boundary =
    q &&
    sort === "relevance" &&
    facetCount === 0 &&
    !data?.recovery &&
    data?.engineUsed === "indx" &&
    data?.truncation &&
    data.truncation.index >= 1 &&
    data.truncation.index < visibleHits.length
      ? data.truncation.index
      : null;

  const highlightTerms = useMemo(() => {
    const p = data?.parsedQuery;
    return p ? [...p.terms, ...p.phrases] : [];
  }, [data]);

  const toggleFacet = (dim: string, value: string) => {
    const next = new Set(selectedFacets[dim] ?? []);
    if (next.has(value)) next.delete(value);
    else next.add(value);
    setParams({ [dim]: [...next].join(",") || null });
  };

  const resetFacets = () => {
    const patch: Record<string, null> = {};
    for (const { key } of FACET_DIMENSIONS) patch[key] = null;
    setParams(patch);
  };

  const [resetting, setResetting] = useState(false);
  const resetCache = async () => {
    setResetting(true);
    try {
      await fetch("/api/cache/reset", { method: "POST" });
      setBust((b) => b + 1); // force a cold refetch against the emptied cache
    } finally {
      setResetting(false);
    }
  };

  const [reindexMsg, setReindexMsg] = useState<string | null>(null);
  const reindexNow = async () => {
    setReindexMsg("queuing…");
    try {
      const r = await fetch("/api/admin/reindex", { method: "POST" });
      const d = (await r.json()) as { ok?: boolean; error?: string };
      if (d.ok) {
        setReindexMsg("rebuilding ~30s…");
        // The rebuild runs async on the API node; refetch once it should be live.
        setTimeout(() => {
          setBust((b) => b + 1);
          setReindexMsg(null);
        }, 32000);
      } else {
        setReindexMsg(d.error ?? "reindex failed");
        setTimeout(() => setReindexMsg(null), 4000);
      }
    } catch (e) {
      setReindexMsg((e as Error).message);
      setTimeout(() => setReindexMsg(null), 4000);
    }
  };

  const activeEngine = ENGINES.find((e) => e.id === engine)!;

  return (
    <main
      className={
        master
          ? // Left frontpage column (the ~1080px aside, which scrolls). Cap +
            // centre the content at max-w-4xl so it keeps the original landing
            // page's proportions inside the wide column — spacious, not sprawled.
            "mx-auto flex w-full max-w-4xl flex-col gap-8 px-8 py-12"
          : "mx-auto flex min-h-screen w-full max-w-4xl flex-col gap-8 px-6 py-12"
      }
    >
      {variant === "page" ? (
        <header className="flex flex-col gap-3 border-b border-zinc-200 pb-6 dark:border-zinc-800">
          <Link
            href="/"
            className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
          >
            ← Barkpark
          </Link>
          <h1 className="text-4xl font-semibold tracking-tight">Find anything</h1>
          <p className="text-zinc-500 dark:text-zinc-400">
            Search across every document type in the{" "}
            <code className="rounded bg-zinc-200/70 px-1.5 py-0.5 font-mono text-[0.8em] dark:bg-zinc-800/70">
              production
            </code>{" "}
            dataset — posts, papers, pages, authors, categories, projects.
          </p>
        </header>
      ) : (
        // Frontpage hero — shown for the home AND the master split, so the left
        // column reads like the landing page it replaced.
        <header className="flex flex-col gap-4 border-b border-zinc-200 pb-8 dark:border-zinc-800">
          <span className="text-xs font-medium uppercase tracking-widest text-zinc-400">
            Barkpark · Headless CMS
          </span>
          <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
            Search the whole CMS.
          </h1>
          <p className="max-w-2xl text-lg leading-relaxed text-zinc-600 dark:text-zinc-300">
            One content model, many surfaces — a Go TUI, a Phoenix Studio, a JS
            SDK, and this Next.js app, all reading one API. Find any document
            across every type below, two ways:{" "}
            <span className="font-medium text-zinc-900 dark:text-zinc-100">
              Postgres
            </span>{" "}
            for exact precision,{" "}
            <span className="font-medium text-zinc-900 dark:text-zinc-100">
              Indx
            </span>{" "}
            for fuzzy, typo-tolerant recall.
          </p>
          <nav className="flex flex-wrap gap-x-5 gap-y-1 text-sm">
            <Link
              href="/papers"
              className="font-medium text-zinc-700 transition-colors hover:text-zinc-950 dark:text-zinc-300 dark:hover:text-zinc-50"
            >
              Browse Papers (Portable Docs) →
            </Link>
            <Link
              href="/bench"
              className="text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
            >
              Engine benchmark →
            </Link>
          </nav>
        </header>
      )}

      {/* search + engine */}
      <div className="flex flex-col gap-3">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <div className="relative flex-1">
            <span
              aria-hidden
              className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-zinc-400"
            >
              ⌕
            </span>
            <input
              type="search"
              id="finder-search"
              name="q"
              aria-label="Search documents"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder='Try: headless · "cli guide" · phoenex · report -draft'
              autoFocus
              className="w-full rounded-lg border border-zinc-300 bg-transparent py-2.5 pl-9 pr-3 text-base outline-none transition-colors focus:border-zinc-500 dark:border-zinc-700 dark:focus:border-zinc-400"
            />
          </div>
          <div
            role="tablist"
            aria-label="Search engine"
            className="flex shrink-0 rounded-lg border border-zinc-300 p-0.5 dark:border-zinc-700"
          >
            {ENGINES.map((e) => (
              <button
                key={e.id}
                role="tab"
                aria-selected={engine === e.id}
                onClick={() => setParams({ engine: e.id })}
                className={`rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
                  engine === e.id
                    ? "bg-zinc-900 text-zinc-50 dark:bg-zinc-100 dark:text-zinc-900"
                    : "text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200"
                }`}
              >
                {e.label}
              </button>
            ))}
          </div>
        </div>
        <p className="text-sm text-zinc-500 dark:text-zinc-400">
          <span className="font-medium text-zinc-700 dark:text-zinc-300">
            {activeEngine.label}:
          </span>{" "}
          {activeEngine.tagline}
        </p>
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <span className="text-zinc-400">Cache</span>
          <button
            role="switch"
            aria-checked={cacheOn}
            onClick={() => setParams({ cache: cacheOn ? null : "on" })}
            className={`rounded-full px-2.5 py-0.5 font-medium transition-colors ${
              cacheOn
                ? "bg-emerald-600 text-white"
                : "border border-zinc-300 text-zinc-500 hover:text-zinc-900 dark:border-zinc-700 dark:hover:text-zinc-200"
            }`}
          >
            {cacheOn ? "on" : "off"}
          </button>
          <span className="text-zinc-400">
            {cacheOn
              ? "Next Data Cache — warm hits skip the API round-trip"
              : "always fresh (no-store)"}
          </span>
          {cacheOn ? (
            <button
              onClick={resetCache}
              disabled={resetting}
              className="rounded-full border border-zinc-300 px-2.5 py-0.5 font-medium text-zinc-500 transition-colors hover:text-zinc-900 disabled:opacity-50 dark:border-zinc-700 dark:hover:text-zinc-200"
            >
              {resetting ? "resetting…" : "reset cache"}
            </button>
          ) : null}
          {engine === "indx" ? (
            <button
              onClick={reindexNow}
              disabled={!!reindexMsg}
              title="Trigger an Indx blue/green rebuild"
              className="rounded-full border border-zinc-300 px-2.5 py-0.5 font-medium text-zinc-500 transition-colors hover:text-zinc-900 disabled:opacity-60 dark:border-zinc-700 dark:hover:text-zinc-200"
            >
              {reindexMsg ?? "reindex"}
            </button>
          ) : null}
        </div>
        <p className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-400">
          <span>
            <code className="font-mono">&quot;exact phrase&quot;</code> phrase
          </span>
          <span>
            <code className="font-mono">-word</code> exclude
          </span>
          <span>
            <code className="font-mono">prefix*</code> starts-with
          </span>
        </p>
      </div>

      {/* banners */}
      {data?.error ? (
        <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Search failed.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{data.error}</pre>
        </section>
      ) : null}
      {data?.indxUnavailable ? (
        <section className="rounded-lg border border-amber-300/70 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900/60 dark:bg-amber-950/30 dark:text-amber-200">
          Indx needs a scoped read token, which isn&apos;t configured in this
          deployment — showing <strong>Postgres</strong> results. Set{" "}
          <code className="font-mono">BARKPARK_READ_TOKEN</code> to enable
          fuzzy/typo search.
        </section>
      ) : null}
      {data?.recovery ? (
        <section className="rounded-lg border border-blue-300/70 bg-blue-50 px-4 py-3 text-sm text-blue-900 dark:border-blue-900/60 dark:bg-blue-950/30 dark:text-blue-200">
          No exact matches — widened to fuzzy results (
          <code className="font-mono">{data.recovery}</code>).
        </section>
      ) : null}

      {/* parsed-query chips */}
      {data?.parsedQuery &&
      (data.parsedQuery.terms.length ||
        data.parsedQuery.phrases.length ||
        data.parsedQuery.excludes.length ||
        data.parsedQuery.prefixes.length) ? (
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <span className="text-zinc-400">Understood as:</span>
          {data.parsedQuery.terms.map((t) => (
            <span
              key={`t-${t}`}
              className="rounded bg-zinc-200/70 px-2 py-0.5 font-mono dark:bg-zinc-800/70"
            >
              {t}
            </span>
          ))}
          {data.parsedQuery.phrases.map((t) => (
            <span
              key={`p-${t}`}
              className="rounded bg-zinc-200/70 px-2 py-0.5 font-mono dark:bg-zinc-800/70"
            >
              &quot;{t}&quot;
            </span>
          ))}
          {data.parsedQuery.prefixes.map((t) => (
            <span
              key={`x-${t}`}
              className="rounded bg-zinc-200/70 px-2 py-0.5 font-mono dark:bg-zinc-800/70"
            >
              {t}*
            </span>
          ))}
          {data.parsedQuery.excludes.map((t) => (
            <span
              key={`e-${t}`}
              className="rounded bg-red-100 px-2 py-0.5 font-mono text-red-700 line-through dark:bg-red-950/40 dark:text-red-300"
            >
              {t}
            </span>
          ))}
        </div>
      ) : null}

      {/* The ~720px column is wide enough for the original facet-rail-beside-
          results layout, so master uses the same grid as the standalone page. */}
      <div className="grid gap-8 md:grid-cols-[12rem_1fr]">
        {/* facets — Indx-computed dimensions (type/status/author/category) */}
        <aside className="flex flex-col gap-5"
        >
          {facetCount > 0 ? (
            <button
              onClick={resetFacets}
              className="self-start text-xs text-zinc-400 transition-colors hover:text-zinc-700 dark:hover:text-zinc-200"
            >
              clear filters ({facetCount})
            </button>
          ) : null}

          {facetGroups.map((g) => (
            <div key={g.key} className="flex flex-col gap-2">
              <h2 className="text-xs font-medium uppercase tracking-widest text-zinc-400">
                {g.label}
              </h2>
              <ul className="flex flex-col gap-0.5">
                {g.buckets.map((b) => {
                  const on = selectedFacets[g.key]?.has(b.label) ?? false;
                  const display = g.key === "type" ? typeLabel(b.label) : b.label;
                  return (
                    <li key={b.label}>
                      <button
                        onClick={() => toggleFacet(g.key, b.label)}
                        className={`flex w-full items-center justify-between gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors ${
                          on
                            ? "bg-zinc-900 text-zinc-50 dark:bg-zinc-100 dark:text-zinc-900"
                            : "text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-900/60"
                        }`}
                      >
                        <span className="truncate">{display}</span>
                        <span
                          className={`shrink-0 font-mono text-xs ${on ? "" : "text-zinc-400"}`}
                        >
                          {b.count}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}

          {facetsFromIndx ? (
            <p className="text-[0.7rem] leading-snug text-zinc-400">
              Counts computed by{" "}
              <span className="font-medium text-zinc-500 dark:text-zinc-400">
                {data?.engineUsed === "postgres" ? "Postgres" : "Indx"}
              </span>{" "}
              across the {q ? "matches" : "dataset"}.
            </p>
          ) : null}
        </aside>

        {/* results */}
        <section className="flex min-w-0 flex-col gap-2">
          <div className="flex flex-wrap items-center justify-between gap-2 text-sm text-zinc-400">
            {showSkeleton ? (
              <span>Searching…</span>
            ) : (
              <span className="flex flex-wrap items-center gap-x-2">
                <span>
                  {visibleHits.length}
                  {data && data.total > hits.length ? ` of ${data.total}` : ""}{" "}
                  {visibleHits.length === 1 ? "result" : "results"}
                </span>
                {data?.engineUsed ? (
                  <span className="font-mono">· {data.engineUsed}</span>
                ) : null}
                {/* engine compute · upstream fetch (cache-hit proxy) · client round-trip */}
                {typeof data?.ms === "number" ? (
                  <span className="font-mono" title="engine compute time">
                    · {data.ms}ms
                  </span>
                ) : null}
                {typeof data?.upstreamMs === "number" ? (
                  <span
                    className="font-mono"
                    title="route handler → API (≈0ms = Data Cache hit)"
                  >
                    · api {data.upstreamMs}ms
                  </span>
                ) : null}
                {typeof roundTripMs === "number" ? (
                  <span className="font-mono" title="browser round-trip">
                    · rt {roundTripMs}ms
                  </span>
                ) : null}
                {prerendered ? (
                  <span
                    className="rounded bg-emerald-100 px-1.5 py-0.5 text-[0.7rem] font-medium text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"
                    title="server-rendered into the first byte (ISR Data Cache)"
                  >
                    prerendered
                  </span>
                ) : data ? (
                  <span
                    className={`rounded px-1.5 py-0.5 text-[0.7rem] font-medium ${
                      data.cache
                        ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-300"
                        : "bg-zinc-200/70 text-zinc-500 dark:bg-zinc-800/70"
                    }`}
                  >
                    {data.cache
                      ? data.upstreamMs !== null && data.upstreamMs <= 8
                        ? "cache HIT"
                        : "cached"
                      : "no-store"}
                  </span>
                ) : null}
                {loading ? (
                  <span className="animate-pulse text-zinc-400">· searching…</span>
                ) : null}
              </span>
            )}
            {hits.length > 0 ? (
              <div
                role="tablist"
                aria-label="Sort"
                className="flex rounded-md border border-zinc-300 p-0.5 dark:border-zinc-700"
              >
                {SORTS.map((s) => (
                  <button
                    key={s.id}
                    role="tab"
                    aria-selected={sort === s.id}
                    onClick={() =>
                      setParams({ sort: s.id === "relevance" ? null : s.id })
                    }
                    className={`rounded px-2 py-1 text-xs font-medium transition-colors ${
                      sort === s.id
                        ? "bg-zinc-900 text-zinc-50 dark:bg-zinc-100 dark:text-zinc-900"
                        : "text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200"
                    }`}
                  >
                    {s.label}
                  </button>
                ))}
              </div>
            ) : null}
          </div>

          {/* popular searches when idle */}
          {!q && popular.length > 0 ? (
            <div className="flex flex-wrap items-center gap-2 pb-2 text-sm">
              <span className="text-zinc-400">Popular:</span>
              {popular.map((p) => (
                <button
                  key={p.query}
                  onClick={() => setParams({ q: p.query })}
                  className="rounded-full border border-zinc-300 px-3 py-1 text-zinc-600 transition-colors hover:border-zinc-500 hover:text-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:text-zinc-100"
                >
                  {p.query}
                </button>
              ))}
            </div>
          ) : null}

          {showSkeleton ? (
            <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
              {Array.from({ length: 5 }).map((_, i) => (
                <li key={i} className="flex flex-col gap-2 py-5">
                  <div className="h-5 w-2/3 animate-pulse rounded bg-zinc-200 dark:bg-zinc-800" />
                  <div className="h-3 w-full animate-pulse rounded bg-zinc-100 dark:bg-zinc-900" />
                </li>
              ))}
            </ul>
          ) : visibleHits.length === 0 ? (
            <p className="py-8 text-zinc-500">
              {q
                ? "No documents match your search."
                : "No documents found."}
            </p>
          ) : (
            <ul
              className={`flex flex-col divide-y divide-zinc-200 transition-opacity dark:divide-zinc-800 ${
                loading ? "opacity-50" : "opacity-100"
              }`}
            >
              {visibleHits.map((hit, i) => (
                <Fragment key={`${hit.type}:${hit.id}`}>
                  {boundary === i ? (
                    <li className="py-3">
                      <div className="flex items-center gap-3 text-[0.7rem] font-medium uppercase tracking-widest text-zinc-400">
                        <span className="h-px flex-1 bg-zinc-200 dark:bg-zinc-800" />
                        confident matches ↑ · related below
                        <span className="h-px flex-1 bg-zinc-200 dark:bg-zinc-800" />
                      </div>
                    </li>
                  ) : null}
                  <li>
                    <ResultRow
                      hit={hit}
                      terms={highlightTerms}
                      master={master}
                      queryString={currentQueryString}
                      selected={
                        master &&
                        (pathname === hit.href ||
                          pathname === `/d/${hit.type}/${hit.slug}`)
                      }
                    />
                  </li>
                </Fragment>
              ))}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}
