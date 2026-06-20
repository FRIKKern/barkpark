"use client";

import { Fragment, memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  ReactNode,
  CSSProperties,
  KeyboardEvent as ReactKeyboardEvent,
  FocusEvent as ReactFocusEvent,
} from "react";
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
import { useHoveredDoc, useGraphMatches } from "@/lib/hovered-doc-context";
import { useFinderNav } from "@/lib/finder-nav-context";
import { useLiveSearch } from "@/lib/use-live-search";
import { suggestCorrection } from "@/lib/did-you-mean";
import { getSearchSessionId } from "@/lib/search-session";
import { stemToken, queryStems } from "@/lib/stem";
import { highlightSegments, words, termHitsWords } from "@/lib/fuzzy";

/** Fire-and-forget feedback POST — never throws, never blocks the caller. */
function recordFindEvent(body: {
  kind: "correction" | "click";
  from?: string;
  to?: string;
  queryEventId?: string | null;
  objectId?: string;
  position?: number;
  sid?: string;
}): void {
  try {
    void fetch("/api/find-event", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      keepalive: true,
    }).catch(() => {});
  } catch {
    /* never let recording break the UI */
  }
}

/**
 * Promote results that contain the query terms EXACTLY (case-insensitive
 * substring across title + body + slug) above results that only fuzzy-match.
 *
 * When an engine finds no full-text hit it widens to fuzzy (Postgres'
 * `typo_widen`), and a trigram TITLE match ("Webhooks" ≈ "websocket") can
 * outrank a doc that literally contains the term in its body. This pulls the
 * real mentions back to the top. Stable within each group, and a pure no-op
 * when the query is a genuine typo that nothing contains — so fuzzy recall is
 * fully preserved. Applies to the verified result of EITHER engine.
 */
function partitionExact(hits: FindHit[], tokens: string[]): FindHit[] {
  if (tokens.length === 0) return hits;
  const exact: FindHit[] = [];
  const fuzzy: FindHit[] = [];
  for (const h of hits) {
    const hayWords = words(`${h.title} ${h.body ?? h.excerpt ?? ""} ${h.slug ?? ""}`);
    // A doc "contains" the query when every token hits — by substring (incl.
    // camelCase like "WebSocket"), inflection ("publishing" ⇢ "publish"), or
    // stem; same test the highlighter and strength meter use.
    (tokens.every((t) => termHitsWords(t, hayWords)) ? exact : fuzzy).push(h);
  }
  // Only reorder on a genuine mix — otherwise keep the engine's order intact.
  return exact.length > 0 && fuzzy.length > 0 ? [...exact, ...fuzzy] : hits;
}

/**
 * Build a CONTEXTUAL snippet around the first query-term match in the body, so
 * a result shows the text that actually triggered it — not just a generic
 * opening excerpt. Windows ~70 chars before / ~120 after the earliest match,
 * snapped to word boundaries, with ellipses. Falls back to the static excerpt
 * when there's no query or nothing matches in the (capped) body.
 */
function matchSnippet(hit: FindHit, terms: string[]): string | null {
  const clean = terms.map((t) => t.toLowerCase()).filter((t) => t.length >= 2);
  const body = hit.body ?? "";
  if (clean.length === 0 || !body) return hit.excerpt;

  const lower = body.toLowerCase();
  let idx = -1;
  let matchLen = 0;
  // Earliest substring match (exact/prefix).
  for (const t of clean) {
    const at = lower.indexOf(t.toLowerCase());
    if (at !== -1 && (idx === -1 || at < idx)) {
      idx = at;
      matchLen = t.length;
    }
  }
  // Earliest STEM match (so "operators" finds "operator's" in the body).
  const stems = queryStems(clean);
  const wordRe = /[A-Za-z0-9_'’]+/g;
  let m: RegExpExecArray | null;
  while ((m = wordRe.exec(body)) !== null) {
    if (stems.has(stemToken(m[0]))) {
      if (idx === -1 || m.index < idx) {
        idx = m.index;
        matchLen = m[0].length;
      }
      break; // regex is left-to-right, so this is the earliest stem hit
    }
  }
  // No match in the body → keep the default excerpt (the title still highlights).
  if (idx === -1) return hit.excerpt;

  let start = Math.max(0, idx - 70);
  const end = Math.min(body.length, idx + matchLen + 120);
  // Snap the start forward to a word boundary so we don't begin mid-word.
  if (start > 0) {
    const sp = body.indexOf(" ", start);
    if (sp !== -1 && sp < idx) start = sp + 1;
  }
  let snip = body.slice(start, end).trim();
  if (start > 0) snip = `… ${snip}`;
  if (end < body.length) snip = `${snip} …`;
  return snip;
}

/**
 * A QUALITATIVE match-strength signal — deliberately NOT a numeric engine score
 * (Postgres ts_rank, Indx BM25F, and fuzzy trigram aren't comparable across
 * engines or queries, and a number reads as false precision). Instead it's
 * derived from explainable, engine-agnostic facts the client already has —
 * WHERE and HOW COMPLETELY the query matched:
 *
 *   title   — every term is in the title        (strongest)
 *   body    — every term appears in the text     (solid)
 *   partial — only some terms matched            (weak)
 *   fuzzy   — no term matches exactly; the engine widened to similarity (loosest)
 *
 * It's relative-within-a-query and self-explaining (tooltip), so it informs
 * without the foot-gun of a precise-looking cross-query score.
 */
type MatchStrength = "title" | "body" | "partial" | "fuzzy";

function matchStrength(hit: FindHit, terms: string[]): MatchStrength {
  const t = terms.filter(Boolean);
  if (t.length === 0) return "title";
  const restText = `${hit.body ?? hit.excerpt ?? ""} ${hit.slug ?? ""}`;
  // Use the SAME hit test as the highlighter (exact / inflection / verbatim), so
  // "publishing" counts as a title hit when the title says "publish" — otherwise
  // the meter says "fuzzy" while the word is clearly lit up.
  const titleWords = words(hit.title);
  const restWords = words(restText);
  const inTitle = (x: string) => termHitsWords(x, titleWords);
  const inAny = (x: string) => inTitle(x) || termHitsWords(x, restWords);
  if (t.every(inTitle)) return "title";
  if (t.every(inAny)) return "body";
  if (t.some(inAny)) return "partial";
  return "fuzzy";
}

const STRENGTH_META: Record<
  MatchStrength,
  { bars: number; label: string; fuzzy?: boolean }
> = {
  title: { bars: 3, label: "Strong match — every term is in the title" },
  body: { bars: 2, label: "Solid match — every term appears in the text" },
  partial: { bars: 1, label: "Partial match — only some terms matched" },
  fuzzy: {
    bars: 1,
    label: "Fuzzy match — no exact term; found by similarity",
    fuzzy: true,
  },
};

/** A tiny ascending 3-bar meter for {@link MatchStrength}. Emerald for real
 * matches, amber for fuzzy; the label rides in a tooltip (no bare number). */
function StrengthMeter({ level }: { level: MatchStrength }) {
  const { bars, label, fuzzy } = STRENGTH_META[level];
  const heights = ["h-1", "h-1.5", "h-2"];
  return (
    <span
      role="img"
      aria-label={label}
      title={label}
      className="inline-flex shrink-0 items-end gap-px"
    >
      {[0, 1, 2].map((i) => (
        <span
          key={i}
          className={`w-[3px] rounded-sm ${heights[i]} ${
            i < bars
              ? fuzzy
                ? "bg-amber-400/90"
                : "bg-emerald-500/80"
              : "bg-zinc-200 dark:bg-zinc-700"
          }`}
        />
      ))}
    </span>
  );
}

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

/** Safe client-side highlight — delegates to {@link highlightSegments}, which
 * tints each WORD by how honestly it answers the query on a green→red gradient,
 * and returns three non-colliding channels per match: a background hue
 * (quality), an underline STYLE (solid/dashed/dotted — a colour-blind-safe echo
 * of quality), and, for a corrected misspelling, the inferred/changed letters
 * flagged so we can ghost them ("wrapp·e·r"). Never injects HTML; only ever
 * wraps whole word-runs (light/dark backgrounds swapped in globals.css). */
function highlight(text: string, terms: string[]): ReactNode {
  if (!terms.some(Boolean)) return text;
  return highlightSegments(text, terms).map((seg, i) => {
    if (!seg.match) return <span key={i}>{seg.text}</span>;
    const body = (seg.runs ?? [{ text: seg.text, inferred: false }]).map((run, j) =>
      run.inferred ? (
        <span key={j} className="bp-hl-inferred">
          {run.text}
        </span>
      ) : (
        <span key={j}>{run.text}</span>
      ),
    );
    return (
      <mark
        key={i}
        title={`${seg.label} · ${Math.round((seg.score ?? 0) * 100)}%`}
        aria-label={`${seg.text} (${seg.label?.toLowerCase()})`}
        className="bp-hl rounded px-0.5 text-inherit"
        style={
          {
            "--hl": seg.light,
            "--hl-d": seg.dark,
            textDecorationLine: "underline",
            textDecorationStyle: seg.underline,
            textDecorationThickness: "2px",
            textUnderlineOffset: "2px",
          } as CSSProperties
        }
      >
        {body}
      </mark>
    );
  });
}

/** Key for the highlight encoding — the red→green quality gradient plus its
 * colour-blind-safe echo (underline style: solid = typed verbatim, dashed/dotted
 * = understood after correcting a typo). Shown once above the results. */
function HighlightLegend() {
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[0.7rem] text-zinc-500 dark:text-zinc-400">
      <span className="flex items-center gap-2">
        <span className="uppercase tracking-widest">match</span>
        <span>fuzzy</span>
        <span
          aria-hidden
          className="h-2 w-24 rounded-full"
          style={{
            backgroundImage:
              "linear-gradient(to right, hsl(0 55% 60%), hsl(24 70% 56%), hsl(48 82% 50%), hsl(72 86% 46%), hsl(100 88% 42%), hsl(130 90% 38%), hsl(162 95% 34%))",
          }}
        />
        <span>exact</span>
      </span>
      <span className="flex items-center gap-3">
        <span className="underline decoration-solid decoration-2 underline-offset-2">verbatim</span>
        <span className="underline decoration-dashed decoration-2 underline-offset-2">corrected</span>
        <span>
          <span className="underline decoration-solid decoration-2 underline-offset-2">wrapp</span>
          <span className="italic opacity-45 underline decoration-solid decoration-2 underline-offset-2">e</span>
          <span className="underline decoration-solid decoration-2 underline-offset-2">r</span>
          <span className="ml-1">= inferred letter</span>
        </span>
      </span>
    </div>
  );
}

function TypeChip({ type }: { type: string }) {
  return (
    <span className="rounded-full bg-zinc-200/70 px-2 py-0.5 font-mono text-[0.7rem] uppercase tracking-wide text-zinc-500 dark:bg-zinc-800/70 dark:text-zinc-400">
      {type}
    </span>
  );
}

const ResultRow = memo(function ResultRow({
  hit,
  terms,
  master = false,
  queryString = "",
  selected = false,
  searchEventId = null,
  sessionId,
  position,
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
  /** Query event id from the current search — attributes a click interaction. */
  searchEventId?: string | null;
  /** Browser session id forwarded as X-BP-SEARCH-CLIENT on the interaction. */
  sessionId?: string;
  /** Zero-based rank of this row in the visible result set. */
  position?: number;
}) {
  const date = shortDate(hit.date);
  // Memoise the highlight render path — highlightSegments runs a per-token
  // Damerau + per-corrected-word LCS DP, and this row re-renders on every
  // keystroke; terms is already a stable useMemo from the parent.
  const titleNodes = useMemo(() => highlight(hit.title, terms), [hit.title, terms]);
  const snippet = useMemo(() => matchSnippet(hit, terms), [hit, terms]);
  const snippetNodes = useMemo(
    () => (snippet ? highlight(snippet, terms) : null),
    [snippet, terms],
  );
  // Cross-surface highlight: lit when the landing graph hovers this doc's node
  // (matched by doc_id == slug). A no-op outside the provider (default null).
  const { hoveredId, setHoveredId } = useHoveredDoc();
  const graphHovered = hoveredId != null && hoveredId === hit.slug;
  // Publish this row's hover so the landing graph focuses the matching node
  // (the list → graph half of the bridge; graphHovered above is the graph → list
  // half that lights this row). setHoveredId dedups, so re-publishing is cheap.
  const onHoverEnter = () => setHoveredId(hit.slug);
  const onHoverLeave = () => setHoveredId(null);
  // Keyboard focus on a row IS a hover (lights the graph node + the violet ring).
  // Clear only when focus leaves the result list entirely — not when moving
  // between rows, which would flicker the graph node off/on each step.
  const onBlurOut = (e: ReactFocusEvent) => {
    const to = e.relatedTarget as HTMLElement | null;
    if (!to || !to.closest("[data-nav-result]")) onHoverLeave();
  };
  // Fire-and-forget click signal — non-blocking so it never delays navigation.
  const onResultClick = () => {
    if (searchEventId) {
      recordFindEvent({
        kind: "click",
        queryEventId: searchEventId,
        objectId: hit.id,
        position,
        sid: sessionId,
      });
    }
  };
  const inner = (
    <>
      <span className="flex items-center gap-2 text-lg font-medium tracking-tight">
        <span>{titleNodes}</span>
        {hit.href ? (
          <span
            aria-hidden
            className="translate-x-0 text-zinc-400 opacity-0 transition-all group-hover:translate-x-1 group-hover:opacity-100"
          >
            →
          </span>
        ) : null}
        {/* Match-strength meter — only with an active query, right-aligned so the
            rows form a strength column you can scan. */}
        {terms.length > 0 ? (
          <span className="ml-auto pl-2">
            <StrengthMeter level={matchStrength(hit, terms)} />
          </span>
        ) : null}
      </span>
      {snippetNodes ? (
        <span className="line-clamp-2 text-sm text-zinc-600 dark:text-zinc-400">
          {snippetNodes}
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
  // State ring: the open doc (selected) wins; else a graph-hover accent (violet,
  // tied to the graph's accent node); else the normal hover wash.
  const stateCls = selected
    ? " bg-zinc-100 ring-1 ring-zinc-300 dark:bg-zinc-900/60 dark:ring-zinc-700"
    : graphHovered
      ? " bg-violet-50 ring-1 ring-violet-300 dark:bg-violet-950/30 dark:ring-violet-600/60"
      : " hover:bg-zinc-100 dark:hover:bg-zinc-900/60";

  if (!hit.href)
    return (
      <div
        data-nav-result=""
        tabIndex={0}
        className={`${cls}${stateCls} focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-violet-500`}
        onMouseEnter={onHoverEnter}
        onMouseLeave={onHoverLeave}
        onFocus={onHoverEnter}
        onBlur={onBlurOut}
      >
        {inner}
      </div>
    );

  // Master mode: append the live finder query string so opening a doc preserves
  // search/engine/facets. Because <Finder> lives in the (finder) LAYOUT, this
  // navigation swaps only the `children` (detail) segment — the Finder never
  // remounts.
  const href = master && queryString ? `${hit.href}?${queryString}` : hit.href;
  return (
    <Link
      href={href}
      // Do NOT eagerly prefetch result rows. The list re-renders on every
      // keystroke with up to MAX_HITS (100) rows; `prefetch` made Next fire an
      // RSC payload fetch (a full server render of each doc route) for EVERY
      // row, EVERY keystroke — fast typing => a prefetch avalanche that froze
      // low-end clients and hammered the server. Navigation on click is
      // unaffected; Next still prefetches on hover/touchstart.
      prefetch={false}
      data-nav-result=""
      onClick={onResultClick}
      onMouseEnter={onHoverEnter}
      onMouseLeave={onHoverLeave}
      onFocus={onHoverEnter}
      onBlur={onBlurOut}
      aria-current={selected ? "page" : undefined}
      className={`${cls}${stateCls} focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-violet-500`}
    >
      {inner}
    </Link>
  );
});

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

  // Stable per-browser session id (localStorage `bp-search-client`). The lazy
  // initialiser returns "" on the server (no window) and the real id on the
  // client's first render — so it threads into the search fetch + feedback POSTs
  // once hydrated, and the SSR markup never depends on it.
  const [sessionId] = useState(() => getSearchSessionId());

  // Master mode: left column inside the (finder) layout; rows open docs in the
  // right @detail slot via in-place navigation (no remount, no full reload).
  const master = variant === "master";
  // Finder → graph bridge: publish the visible result set (with score weights)
  // so the landing graph can emphasize each match by rank and dim the rest. A
  // no-op outside the (finder) layout's provider.
  const { setMatches } = useGraphMatches();
  // Cross-segment keyboard bridge: List →→ Document (open) and Document → List
  // (return). The left grid (Search/Facets/List) is handled inline below.
  const { listFocusNonce, requestDocFocus } = useFinderNav();
  // Keyboard-nav anchors: the finder root (focus queries scope here) and the
  // last-active result index (so a return from the Document lands on it).
  const rootRef = useRef<HTMLElement | null>(null);
  const activeIdxRef = useRef(0);
  // Per-keystroke live search over a direct WebSocket (browser → API, no Vercel
  // hop). Ships dark: `enabled` only when the NEXT_PUBLIC_BARKPARK_WS_* env is
  // provisioned, `ready` only once the channel joins — until then the search
  // effect below keeps using the same-origin `/api/find` path, so nothing is
  // lost when it's off or still connecting.
  const {
    enabled: liveEnabled,
    ready: liveReady,
    search: liveSearch,
  } = useLiveSearch();
  // Live finder params (q/engine/cache/sort/facets) — appended to each row's
  // doc href so the open doc and the search state coexist in the URL path+query.
  const currentQueryString = sp.toString();

  const q = sp.get("q") ?? "";
  // Default to Indx — the landing then showcases native facets + fuzzy recall.
  const engine: SearchEngine = sp.get("engine") === "postgres" ? "postgres" : "indx";
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

  // Input is local + debounced into the URL's `q` (the source of truth). The
  // box OWNS its text; we only pull `q` back in on an EXTERNAL change (back/
  // forward nav, a popular chip, a "did you mean" accept) — never on the echo
  // of our own debounced write, which lags behind what the user has since
  // typed. Adopting that echo is what used to wipe characters typed mid-debounce
  // (type "headl" fast → the "head" echo lands → box snaps back to "head").
  const [input, setInput] = useState(q);
  // `lastSent` = the last q WE pushed (debounce); `prevQ` = the q we last
  // reconciled. Both are STATE so the render-phase reconciliation is React's
  // sanctioned "adjust state during render" pattern (refs can't be read in
  // render). When the incoming q equals `lastSent` it is our own echo → leave
  // the box alone; anything else is an external change → adopt it.
  const [lastSent, setLastSent] = useState(q);
  const [prevQ, setPrevQ] = useState(q);
  if (q !== prevQ) {
    setPrevQ(q);
    if (q !== lastSent) setInput(q);
  }
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => {
    if (input === q) return;
    clearTimeout(timer.current);
    // Adaptive debounce: with the live socket a query is a cheap frame on an
    // open connection, so fire fast for a near-per-keystroke direct feel; on the
    // HTTP fallback stay conservative to avoid hammering the route per keystroke.
    const delay = liveEnabled && liveReady ? 90 : 250;
    timer.current = setTimeout(() => {
      setLastSent(input);
      setParams({ q: input || null });
    }, delay);
    return () => clearTimeout(timer.current);
  }, [input, q, setParams, liveEnabled, liveReady]);

  // Fetch whenever the committed query or engine changes. `loading` is derived
  // (the in-flight key differs from the resolved result's key) so the effect
  // never calls setState synchronously — only inside the async resolution.
  // Identity of the current view: engine + query. No cache/bust dimension —
  // every search goes straight to the engine, always fresh.
  const reqKey = `${engine} ${q}`;
  // Manual refetch trigger (the reindex button) — not a cache; bumping it re-runs
  // the fetch effect for the SAME view to pull freshly-reindexed data.
  const [refreshNonce, setRefreshNonce] = useState(0);
  // Key the server-rendered seed corresponds to: the landing (empty query) on
  // the page's engine. When it matches `reqKey` on mount we use the seed instead
  // of refetching — the first paint already has the results.
  const seedKey = initialData ? `${initialEngine} ` : null;
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
    // Thread the session so the search is recorded against this browser — the
    // X-BP-SEARCH-CLIENT key the API counts for correction auto-promotion.
    if (sessionId) params.set("sid", sessionId);
    const t0 = performance.now();
    // Live socket when it's connected, else the same-origin HTTP route. Both
    // resolve the identical `FindResponse` (shared shaper), so the `.then`/`.catch`
    // below don't care which transport answered. A superseded live reply rejects
    // as an AbortError, which the catch already ignores like a fetch abort.
    const resultP: Promise<FindResponse> =
      liveEnabled && liveReady
        ? liveSearch({ q, engine, browse: !q })
        : fetch(`/api/find?${params.toString()}`, { signal: ctrl.signal }).then(
            (r) => r.json() as Promise<FindResponse>,
          );
    resultP
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
              cache: false,
              upstreamMs: null,
              searchEventId: null,
              correctedTo: null,
              error: (e as Error).message,
            },
          });
        }
      });
    return () => ctrl.abort();
  }, [
    reqKey,
    engine,
    q,
    seedKey,
    sessionId,
    refreshNonce,
    liveEnabled,
    liveReady,
    liveSearch,
  ]);
  const data = result?.data ?? null;
  const roundTripMs = result?.key === reqKey ? result.roundTripMs : null;
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

  // ── engine results, direct ────────────────────────────────────────────────
  // Every keystroke queries Postgres/Indx directly (live socket when joined,
  // else the same-origin HTTP route) — no client-side corpus approximation, no
  // cache. The list shows what the engine actually returned. The previous result
  // stays on screen (dimmed) while the next query is in flight, so typing never
  // flashes empty between fresh engine answers.
  const trimmedInput = input.trim();
  // Cleaned literal query tokens (drop excludes/quotes, len ≥ 2) — the words the
  // user actually typed; used for the exact-match partition + highlight.
  const queryTokens = useMemo(
    () =>
      trimmedInput
        .split(/\s+/)
        .filter((t) => t && !t.startsWith("-"))
        .map((t) => t.replace(/"/g, ""))
        .filter((t) => t.length >= 2),
    [trimmedInput],
  );
  // Engine results get an exact-match-first pass so a fuzzy/widened title match
  // can't outrank a doc that literally contains the term.
  const baseHits = useMemo(
    () => partitionExact(hits, queryTokens),
    [hits, queryTokens],
  );

  // Skeleton only when there is genuinely nothing to show yet — no engine result
  // in hand (first paint before the seed/first query lands).
  const showSkeleton = loading && !data;

  // Vocabulary from the browse seed (all docs' titles/excerpts) — broadens the
  // "did you mean" candidate pool beyond the current query's results + popular.
  const corpusWords = useMemo(
    () =>
      (initialData?.hits ?? []).flatMap((h) =>
        `${h.title} ${h.excerpt ?? ""}`.toLowerCase().split(/[^a-z0-9-]+/),
      ),
    [initialData],
  );

  // "Did you mean …?" — both engines fuzzy-match a typo to docs containing the
  // real term, so the correction is derivable from the results + popular
  // queries + corpus (no engine support needed). Null when nothing's confident.
  const suggestion = useMemo(
    () =>
      q
        ? suggestCorrection({
            query: q,
            parsed: data?.parsedQuery ?? null,
            hits,
            popular,
            corpus: corpusWords,
          })
        : null,
    [q, data, hits, popular, corpusWords],
  );

  // Facet groups: prefer Indx's dataset-wide buckets; fall back to a client
  // type-count over the visible hits when the engine returned none (Postgres path).
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
    for (const h of baseHits) counts.set(h.type, (counts.get(h.type) ?? 0) + 1);
    const buckets = DOC_TYPES.map((t) => ({
      label: t.type,
      count: counts.get(t.type) ?? 0,
    })).filter((b) => b.count > 0);
    return buckets.length ? [{ key: "type", label: "Type", buckets }] : [];
  }, [data, baseHits]);

  const facetCount = Object.values(selectedFacets).reduce((n, s) => n + s.size, 0);

  const visibleHits = useMemo(() => {
    let out = baseHits;
    for (const [dim, vals] of Object.entries(selectedFacets)) {
      out = out.filter((h) => vals.has(h.facets[dim] ?? ""));
    }
    if (sort === "newest") {
      out = [...out].sort((a, b) => (b.date ?? "").localeCompare(a.date ?? ""));
    } else if (sort === "title") {
      out = [...out].sort((a, b) => a.title.localeCompare(b.title));
    }
    return out;
  }, [baseHits, selectedFacets, sort]);

  // Render only the top slice of rows by default. The engine returns up to
  // MAX_HITS (100); mounting all of them as <Link> rows on every keystroke is a
  // heavy DOM + reconcile cost on low-end clients (it compounded the prefetch
  // storm that froze them). The GRAPH still receives the FULL visibleHits as
  // matches (see graphMatches below) — only the visible DOM list is capped.
  const RESULT_RENDER_CAP = 25;
  const [showAllResults, setShowAllResults] = useState(false);
  // Collapse back to the capped view whenever the result set changes (a new
  // search). React's "adjust state during render" pattern (not an effect, which
  // would cascade renders): visibleHits is memoized, so expanding (showAll
  // toggle) doesn't change its identity and won't fight the user's click.
  const [prevHits, setPrevHits] = useState(visibleHits);
  if (prevHits !== visibleHits) {
    setPrevHits(visibleHits);
    setShowAllResults(false);
  }
  const renderedHits = showAllResults
    ? visibleHits
    : visibleHits.slice(0, RESULT_RENDER_CAP);

  // ── keyboard navigation ─────────────────────────────────────────────────
  //   Search  ↕  List  ←→  Facets        List →→ Document (open) · Doc → List
  // Roving DOM focus, NO per-step React state — arrow keys move focus among the
  // live [data-nav-*] elements, so navigating the list never re-renders the
  // Finder shell. The active row's own onFocus publishes its slug to the hover
  // bridge (lighting the graph node + its violet row ring), so the graph sync
  // and active highlight come for free. activeIdxRef remembers the opened row so
  // a ← out of the Document returns focus exactly there.
  const navEls = (sel: string) =>
    Array.from(rootRef.current?.querySelectorAll<HTMLElement>(sel) ?? []);
  const resultEls = () => navEls("[data-nav-result]");
  const facetEls = () => navEls("[data-nav-facet]");
  const indexOfActive = (els: HTMLElement[]) =>
    els.indexOf(document.activeElement as HTMLElement);
  const focusSearch = () => document.getElementById("finder-search")?.focus();
  const focusFacet = (i: number) => {
    const els = facetEls();
    if (els.length) els[Math.max(0, Math.min(i, els.length - 1))].focus();
  };
  const focusResult = (i: number) => {
    const els = resultEls();
    if (!els.length) return;
    const idx = Math.max(0, Math.min(i, els.length - 1));
    activeIdxRef.current = idx;
    els[idx].focus();
  };
  const openActiveResult = () => {
    const els = resultEls();
    const cur = indexOfActive(els);
    const idx = cur >= 0 ? cur : activeIdxRef.current;
    activeIdxRef.current = idx;
    const hit = visibleHits[idx];
    if (!hit?.href) return;
    const href =
      master && currentQueryString
        ? `${hit.href}?${currentQueryString}`
        : hit.href;
    router.push(href);
    requestDocFocus(); // hand whole-doc focus to the Document pane
  };

  const onSearchKeyDown = (e: ReactKeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      focusResult(activeIdxRef.current);
    } else if (e.key === "Enter") {
      e.preventDefault();
      openActiveResult();
    }
  };
  const onListKeyDown = (e: ReactKeyboardEvent) => {
    const cur = indexOfActive(resultEls());
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        focusResult(cur + 1);
        break;
      case "ArrowUp":
        e.preventDefault();
        if (cur <= 0) focusSearch();
        else focusResult(cur - 1);
        break;
      case "ArrowLeft":
        e.preventDefault();
        focusFacet(0);
        break;
      case "ArrowRight":
      case "Enter":
        e.preventDefault();
        openActiveResult();
        break;
    }
  };
  const onFacetsKeyDown = (e: ReactKeyboardEvent) => {
    const cur = indexOfActive(facetEls());
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        focusFacet(cur + 1);
        break;
      case "ArrowUp":
        e.preventDefault();
        if (cur <= 0) focusSearch();
        else focusFacet(cur - 1);
        break;
      case "ArrowRight":
        e.preventDefault();
        focusResult(activeIdxRef.current);
        break;
      // Enter / Space toggles the facet via the button's native click.
    }
  };

  // A new result set resets the keyboard position to the top.
  useEffect(() => {
    activeIdxRef.current = 0;
  }, [visibleHits]);

  // Document → List: a ← out of the doc pane refocuses the row we opened from.
  useEffect(() => {
    if (listFocusNonce > 0) focusResult(activeIdxRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [listFocusNonce]);

  // A filter is "active" when the user has narrowed the corpus — text in the box
  // (the LIVE input, so the graph reacts on the keystroke, not after the debounce
  // commits to the URL) or any facet selection. Idle browse leaves the graph
  // whole rather than dimming it to the browse page.
  const filterActive = trimmedInput.length > 0 || facetCount > 0;

  // Rank → score weight. Both engines return hits in score-descending order, so
  // a hit's index in the (unfiltered, engine-ordered) result list IS its
  // relative search score — independent of the display sort. Map it to a weight
  // in [0.2, 1] with a gentle head bias: the top results clearly dominate while
  // the tail stays visibly above the dimmed non-matches.
  const rankBySlug = useMemo(() => {
    const m = new Map<string, number>();
    baseHits.forEach((h, i) => {
      if (h.slug && !m.has(h.slug)) m.set(h.slug, i);
    });
    return m;
  }, [baseHits]);

  // The visible results as weighted graph matches (null when idle → full graph).
  const graphMatches = useMemo(() => {
    if (!filterActive) return null;
    const n = baseHits.length;
    return visibleHits
      .filter((h) => h.slug)
      .map((h) => {
        const rank = rankBySlug.get(h.slug) ?? n;
        const t = n <= 1 ? 0 : Math.min(rank, n - 1) / (n - 1);
        const w = Math.round((0.2 + 0.8 * Math.pow(1 - t, 1.4)) * 1000) / 1000;
        return { id: h.slug, w };
      });
  }, [filterActive, visibleHits, baseHits.length, rankBySlug]);

  // Publish to the landing graph. While loading, hold the previous publish
  // (don't flash the graph to empty between keystrokes).
  const matchKey = graphMatches
    ? graphMatches.map((m) => `${m.id}:${m.w}`).join(",")
    : "";
  useEffect(() => {
    if (!master) return;
    // Publish on every change — the previous engine result stays in `baseHits`
    // while the next query is in flight, so the graph tracks the visible set in
    // lockstep and never flashes to empty. The context dedupes identical publishes.
    setMatches(graphMatches);
    // matchKey captures the weighted set; graphMatches is read fresh.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [master, matchKey, setMatches]);

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

  // Server-side learned correction (synonym fired). Shown as "Showing results
  // for …" and folded into highlighting so the corrected term lights up.
  const correctedTo =
    data?.correctedTo && data.correctedTo.toLowerCase() !== q.toLowerCase()
      ? data.correctedTo
      : null;
  // Query event id for the current search — attributes result-click signals.
  const searchEventId = data?.searchEventId ?? null;

  const highlightTerms = useMemo(() => {
    const p = data?.parsedQuery;
    // Use the engine's parsed terms when the result for the current box has
    // landed; while a query is still in flight, fall back to the live typed
    // tokens so the highlight tracks the box (parsedQuery reflects the old q).
    const fresh = data != null && !loading && q.trim() === trimmedInput;
    const base = p && fresh ? [...p.terms, ...p.phrases] : queryTokens;
    return correctedTo ? [...base, correctedTo] : base;
  }, [data, loading, q, trimmedInput, correctedTo, queryTokens]);

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
          setRefreshNonce((n) => n + 1);
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

  // Advanced options panel (cache/reindex/syntax) — a stateful toggle rather
  // than <details>, so the interactive Popular chips can share its header row
  // without a click also toggling the panel.
  const [optionsOpen, setOptionsOpen] = useState(false);

  return (
    <main
      ref={rootRef}
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
            Barkpark · Living documentation
          </span>
          <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
            Barkpark, documented in Barkpark.
          </h1>
          <p className="max-w-2xl text-lg leading-relaxed text-zinc-600 dark:text-zinc-300">
            Every page here is a Paper — Barkpark&rsquo;s own documentation plus a
            1:1 mirror of its GitHub docs, stored as structured content and
            rendered live.
          </p>
          <nav className="flex flex-wrap gap-x-5 gap-y-1 text-sm">
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
              onKeyDown={onSearchKeyDown}
              aria-keyshortcuts="ArrowDown"
              // Kill the browser's native autocomplete/history dropdown: it pops
              // over the field AND hijacks ↓/↑ to drive its own suggestion list,
              // fighting the keyboard nav (↓ should enter our results, not the
              // browser popup). The 1Password-style attrs stop password managers
              // and form tooling from attaching too.
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck={false}
              data-1p-ignore
              data-lpignore="true"
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
        {/* Status row (fixed height): Popular shortcuts when idle, parsed-query
            chips when searching, + the fuzzy pill — with the Options toggle on
            the right. The benchmark/advanced controls tuck into the panel below,
            collapsed by default so the primary surface stays clean. */}
        <div className="flex min-h-7 items-center justify-between gap-3 text-sm text-zinc-500 dark:text-zinc-400">
          <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
            {highlightTerms.length > 0 ? (
              <HighlightLegend />
            ) : popular.length > 0 ? (
              // Default (idle) state: Popular shortcuts live HERE instead of the
              // old engine tagline.
              <>
                <span className="text-zinc-400">Popular:</span>
                {popular.map((p) => (
                  <button
                    key={p.query}
                    onClick={() => setParams({ q: p.query })}
                    className="rounded-full border border-zinc-300 px-2.5 py-0.5 text-xs text-zinc-600 transition-colors hover:border-zinc-500 hover:text-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:text-zinc-100"
                  >
                    {p.query}
                  </button>
                ))}
              </>
            ) : null}
            {/* Fuzzy/widened indicator — a compact pill in this same row instead
                of a banner block, so it never shifts the layout. */}
            {data?.recovery ? (
              <span
                className="inline-flex shrink-0 items-center gap-1 rounded bg-blue-100 px-1.5 py-0.5 text-[0.7rem] font-medium text-blue-700 dark:bg-blue-950/40 dark:text-blue-300"
                title={`No exact matches — widened to fuzzy results (${data.recovery})`}
              >
                <svg
                  aria-hidden
                  viewBox="0 0 12 12"
                  className="h-3 w-3"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.3"
                >
                  <path d="M2 4c2 0 2 4 4 4s2-4 4-4" strokeLinecap="round" />
                </svg>
                fuzzy
              </span>
            ) : null}
          </div>
          <button
            type="button"
            onClick={() => setOptionsOpen((o) => !o)}
            aria-expanded={optionsOpen}
            className="flex shrink-0 items-center gap-1 text-xs text-zinc-400 transition-colors hover:text-zinc-600 dark:hover:text-zinc-300"
          >
            Options
            <svg
              aria-hidden
              viewBox="0 0 12 12"
              className={`h-3 w-3 transition-transform ${optionsOpen ? "rotate-180" : ""}`}
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
            >
              <path
                d="M3 4.5 6 7.5 9 4.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </button>
        </div>
        {optionsOpen ? (
          <div className="flex flex-col gap-3 border-l-2 border-zinc-200 pl-3 dark:border-zinc-800">
            <div className="flex flex-wrap items-center gap-2 text-xs">
              <span className="text-zinc-400">
                Every query hits {engine === "indx" ? "Indx" : "Postgres"}{" "}
                directly — always fresh, no cache.
              </span>
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
        ) : null}
      </div>

      {/* Popular shortcuts now live in the status row above (idle state),
          replacing the old engine tagline — no separate line. */}

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
      {/* Recovery/fuzzy-widen is now a compact pill in the engine row above
          (no banner block → no layout shift). */}

      {/* Showing results for — server already auto-corrected via a LEARNED
          synonym. Preferred over the client "Did you mean?" when present. */}
      {correctedTo ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-300">
          Showing results for{" "}
          <strong className="font-medium text-zinc-900 dark:text-zinc-50">
            {correctedTo}
          </strong>
          {" · "}
          <button
            onClick={() => setParams({ q })}
            className="text-zinc-500 underline decoration-dotted underline-offset-2 transition-colors hover:text-zinc-900 hover:decoration-solid dark:hover:text-zinc-200"
          >
            search {q} instead
          </button>
        </p>
      ) : suggestion ? (
        /* did you mean — a client spelling correction (not-yet-learned case) */
        <p className="text-sm text-zinc-600 dark:text-zinc-300">
          Did you mean{" "}
          <button
            onClick={() => {
              // Record the correction-accept BEFORE navigating so distinct
              // sessions accumulate toward synonym auto-promotion.
              recordFindEvent({
                kind: "correction",
                from: q,
                to: suggestion,
                sid: sessionId,
              });
              setParams({ q: suggestion });
            }}
            className="font-medium text-zinc-900 underline decoration-dotted underline-offset-2 transition-colors hover:decoration-solid dark:text-zinc-50"
          >
            {suggestion}
          </button>
          ?
        </p>
      ) : null}

      {/* Parsed-query chips now live in the engine-tagline row above (they
          replace the tagline there), so there's no separate chip line to shift. */}

      {/* The ~720px column is wide enough for the original facet-rail-beside-
          results layout, so master uses the same grid as the standalone page. */}
      <div className="grid gap-8 md:grid-cols-[12rem_1fr]">
        {/* facets — Indx-computed dimensions (type/status/author/category) */}
        <aside
          className="flex flex-col gap-5"
          onKeyDown={onFacetsKeyDown}
          aria-label="Filters — ↑/↓ to move, → to results, Enter to toggle"
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
                        data-nav-facet=""
                        aria-pressed={on}
                        onClick={() => toggleFacet(g.key, b.label)}
                        className={`flex w-full items-center justify-between gap-2 rounded-md px-2 py-1.5 text-left text-sm transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 ${
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
          {/* Fixed single-row header: never wraps, fixed min-height, so the
              sort tabs stay put and the row doesn't grow/shrink between the
              loading and loaded states. The left metadata CLIPS rather than
              pushing the tabs to a second line. */}
          <div className="flex min-h-8 items-center justify-between gap-3 text-sm text-zinc-400">
            {showSkeleton ? (
              <span className="min-w-0 truncate">Searching…</span>
            ) : (
              <span className="flex min-w-0 items-center gap-x-2 overflow-hidden whitespace-nowrap">
                <span className="shrink-0">
                  {visibleHits.length}
                  {data && data.total > hits.length ? ` of ${data.total}` : ""}{" "}
                  {visibleHits.length === 1 ? "result" : "results"}
                </span>
                {data?.engineUsed ? (
                  <span className="font-mono">· {data.engineUsed}</span>
                ) : null}
                {/* engine compute · upstream fetch · client round-trip */}
                {typeof data?.ms === "number" ? (
                  <span className="font-mono" title="engine compute time">
                    · {data.ms}ms
                  </span>
                ) : null}
                {typeof data?.upstreamMs === "number" ? (
                  <span className="font-mono" title="route handler → API">
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
                    title="server-rendered into the first byte"
                  >
                    prerendered
                  </span>
                ) : null}
                {loading ? (
                  <span className="animate-pulse text-zinc-400">
                    · searching…
                  </span>
                ) : null}
              </span>
            )}
            {baseHits.length > 0 ? (
              <div
                role="tablist"
                aria-label="Sort"
                className="flex shrink-0 rounded-md border border-zinc-300 p-0.5 dark:border-zinc-700"
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
              {loading
                ? "Searching…"
                : trimmedInput
                  ? "No documents match your search."
                  : "No documents found."}
            </p>
          ) : (
            <ul
              onKeyDown={onListKeyDown}
              aria-label="Results — ↑/↓ to move, → to open, ← to filters"
              className={`flex flex-col divide-y divide-zinc-200 transition-opacity dark:divide-zinc-800 ${
                loading ? "opacity-50" : "opacity-100"
              }`}
            >
              {renderedHits.map((hit, i) => (
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
                      searchEventId={searchEventId}
                      sessionId={sessionId}
                      position={i}
                      selected={
                        master &&
                        (pathname === hit.href ||
                          pathname === `/d/${hit.type}/${hit.slug}`)
                      }
                    />
                  </li>
                </Fragment>
              ))}
              {!showAllResults && visibleHits.length > RESULT_RENDER_CAP ? (
                <li className="py-3">
                  <button
                    type="button"
                    onClick={() => setShowAllResults(true)}
                    className="w-full rounded-lg border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-600 transition-colors hover:border-zinc-400 hover:text-zinc-900 dark:border-zinc-800 dark:text-zinc-300 dark:hover:border-zinc-600 dark:hover:text-zinc-100"
                  >
                    Show {visibleHits.length - RESULT_RENDER_CAP} more
                  </button>
                </li>
              ) : null}
            </ul>
          )}
        </section>
      </div>
    </main>
  );
}
