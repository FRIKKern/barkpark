"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Listing } from "@/lib/listings-data";
import type { GraphMatch } from "@/lib/hovered-doc-context";
import { canvas } from "@/lib/tokens.gen";
import { safeHref } from "@/lib/safe-href";
import {
  TILE_SUBDOMAINS,
  tileUrlTemplate,
  tilesAllowedByCsp,
  tilesEnabled,
} from "@/lib/map-tiles";

/** Compose an alpha variant of an emitted `hsl(H S% L%)` token for Canvas2D
 *  (`hsl(H S% L% / a)`), so no fixed rgba/hex literal lives in this file. */
const withAlpha = (c: string, a: number) => c.replace(")", ` / ${a})`);

/**
 * The pin popover's "Website ↗" target. `l.url` is CMS-authored listing
 * content, so it is caller-controlled and reaches an `<a href>` — the same
 * class of value `sheet-grid.tsx` routes through `safeHref` — so this does
 * too. It was the one `<a href>` in web/ that skipped the scheme allow-list.
 * A url that is not an allowed scheme (or is protocol-relative, or is not a
 * string at all) yields null and no anchor is rendered.
 */
export function detailHref(l: Listing): string | null {
  return safeHref(l.url) ?? null;
}

/**
 * A self-contained slippy map of listing pins — the directory landing's right
 * pane, drop-in replacement for the old documentation graph.
 *
 * Same house rules as `public/bp-graph.js`: vanilla Canvas2D, ZERO npm map libs
 * (no Leaflet / Mapbox / MapLibre), ZERO build-time tile bundle. The only
 * network it touches is the raster tile server the browser fetches directly at
 * runtime (OpenStreetMap by default), and that is OPTIONAL — with tiles off (or
 * blocked) the pins still render over a calm graticule, so the surface never
 * collapses to a blank box.
 *
 * It honours the EXISTING finder ↔ right-pane bridge verbatim:
 *   - `matches` (the finder's visible result set, with per-result weight) dims
 *     every pin that isn't a current search hit and scales the rest by rank, so
 *     typing in the left rail filters the map.
 *   - `hoveredId` focuses the pin whose `id` matches a hovered result row.
 *   - `onHover` reports the reverse direction (pin → result row).
 * The keys line up only when the map and the finder read the SAME source; with
 * the bundled sample data the bridge is simply inert (every pin stays lit).
 */

const TILE = 256;
const MIN_ZOOM = 2;
const MAX_ZOOM = 18;
/** Mercator clamps near the poles — past this the projection blows up. */
const MAX_LAT = 85.05;
/** Pointer-to-pin hit radius, in CSS px. */
const HIT_RADIUS = 15;

const MARKER = canvas.primary; // evergreen brand — the product-primary map pin
const MARKER_DIM = canvas.mutedText; // muted — a pin filtered out by the search

// Tile config comes from `lib/map-tiles.ts`, which `lib/csp.ts` reads too — the
// policy's `img-src` is built from these exact values, so a host this component
// fetches and a host the browser will allow cannot drift apart. See that
// module's header for the defect that made a shared seam necessary.
const TILE_URL = tileUrlTemplate();
const TILES_ENABLED = tilesEnabled();
/** OSM's tile policy requires visible attribution — shown when tiles are on. */
const SHOWS_OSM_ATTRIBUTION =
  TILES_ENABLED && TILE_URL.includes("openstreetmap.org");

/**
 * Tiles are configured, but the CSP will block every one of them.
 *
 * This is the exact state that shipped: `img-src` named no tile host, so the
 * browser refused each request, this map fell back to its graticule (which it
 * does deliberately and quietly), and the only trace was a console CSP
 * violation nobody was looking for. `tilesAllowedByCsp()` evaluates the SAME
 * predicate `lib/csp.ts` gates the directive on, so if the two ever disagree
 * again — the map mounted outside the landing the policy widens for, say — the
 * component says so instead of drawing a blank basemap.
 */
const TILES_WILL_BE_BLOCKED = TILES_ENABLED && !tilesAllowedByCsp();

/* ── Web-Mercator projection (lng/lat ⇄ world pixels at integer zoom z) ──── */

const clamp = (v: number, lo: number, hi: number) =>
  v < lo ? lo : v > hi ? hi : v;
const clampLat = (lat: number) => clamp(lat, -MAX_LAT, MAX_LAT);

function lngToWorldX(lng: number, z: number): number {
  return ((lng + 180) / 360) * TILE * 2 ** z;
}
function latToWorldY(lat: number, z: number): number {
  const r = (clampLat(lat) * Math.PI) / 180;
  return (
    ((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * TILE * 2 ** z
  );
}
function worldXToLng(x: number, z: number): number {
  return (x / (TILE * 2 ** z)) * 360 - 180;
}
function worldYToLat(y: number, z: number): number {
  const n = Math.PI - (2 * Math.PI * y) / (TILE * 2 ** z);
  return (180 / Math.PI) * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
}

/* ── bounds on caller-controlled pin geometry ─────────────────────────────── */

/** Longest label a pin will paint, in GRAPHEMES. See `pinLabelText`. */
export const PIN_LABEL_MAX_GRAPHEMES = 64;

/** How many UTF-16 code units to slice off a title before segmenting it.
 *
 * `Intl.Segmenter.segment()` is NOT lazy enough to lean on: measured in
 * Chromium, taking the first 64 graphemes of a 1,000,000-character string costs
 * 1.27ms warm, while taking the first 64 of that string's leading 1024
 * characters costs 0.004ms. So the slice comes first, and the segmenter only
 * ever sees a short head. 16 code units per grapheme clears even the longest
 * ZWJ emoji sequences. */
const PIN_LABEL_SLICE = PIN_LABEL_MAX_GRAPHEMES * 16;

function* graphemesOf(s: string): Generator<string> {
  // Intl.Segmenter is Baseline-wide but not universal (Safari < 16.4); fall
  // back to code points, which at least never splits a surrogate pair.
  if (typeof Intl.Segmenter !== "function") {
    yield* s;
    return;
  }
  const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  for (const { segment } of seg.segment(s)) yield segment;
}

/**
 * The text a pin's canvas label actually paints — the title, elided to a
 * bounded number of graphemes.
 *
 * A listing `title` is CMS-authored and arrives with NO upper bound
 * (`lib/listings.ts`'s `str()` accepts any non-empty string), while `drawLabel`
 * re-measures and repaints its text from scratch on EVERY animation frame that
 * a pin is hovered or its popover is open. Unbounded in meant unbounded work:
 * measured in Chromium at this file's 12px label font, a 1,000,000-character
 * title produced a 6,744,155px-wide label box at 10.25ms per label draw, against
 * a 53px box at 0.01ms for "Mocca" — one such listing drops the whole map to
 * single-digit FPS for as long as that pin stays lit.
 *
 * The popover already bounds each of its own fields (a `line-clamp-3` on the
 * description, a `slice(0, 4)` on the tags); the canvas label was the one field
 * with nothing. It is ELIDED, never dropped — a pin with no label is a worse
 * map than a pin with a shortened one — and it is cut on grapheme boundaries so
 * an emoji or a combining sequence never ends up half-painted.
 */
export function pinLabelText(title: string): string {
  if (typeof title !== "string") return "";
  // ≤N code units can never be more than N graphemes, so short titles — every
  // real one — skip the segmenter entirely and pass through byte-identical.
  if (title.length <= PIN_LABEL_MAX_GRAPHEMES) return title;

  const head = title.slice(0, PIN_LABEL_SLICE);
  const units: string[] = [];
  for (const g of graphemesOf(head)) {
    units.push(g);
    if (units.length > PIN_LABEL_MAX_GRAPHEMES) break;
  }
  // A long-but-few-graphemes title (combining marks, emoji) still fits.
  if (units.length <= PIN_LABEL_MAX_GRAPHEMES && head.length === title.length) {
    return title;
  }
  return `${units.slice(0, PIN_LABEL_MAX_GRAPHEMES).join("")}…`;
}

/** Smallest radius a pin is ever drawn at, in CSS px. See `pinRadius`. */
const PIN_MIN_RADIUS = 1;

/**
 * A pin's canvas radius, in CSS px, from its dim state and its finder weight.
 *
 * `weight` comes from the `matches` prop — caller-controlled — and lands in
 * `ctx.arc`, which THROWS on a negative radius. Measured in Chromium against
 * the unbounded expression this replaces: `w = -10` yields `r = -19.5` and
 * `IndexSizeError: Failed to execute 'arc' on 'CanvasRenderingContext2D': The
 * radius provided (-19.5) is negative.` A throw out of `drawPins` costs the
 * whole frame, so every pin after the offending one goes unpainted. `NaN` and
 * `Infinity` do not throw but paint nothing, which is the same hole seen from
 * the other side; both land on the floor here.
 *
 * REACHABILITY, honestly: the only in-repo caller, `components/finder.tsx`,
 * already bounds `w` to [0.2, 1.0], so `r` there is always in [6.0, 8.0] and
 * this floor never fires. It exists because `ListingsMap` is an EXPORTED
 * component an external consumer can feed any `matches` array — not because
 * the shipped app trips it.
 */
export function pinRadius(dim: boolean, weight: number | undefined): number {
  const r = dim ? 4.5 : 5.5 + (weight ? weight * 2.5 : 0);
  return Number.isFinite(r) ? Math.max(PIN_MIN_RADIUS, r) : PIN_MIN_RADIUS;
}

interface View {
  lng: number;
  lat: number;
  zoom: number;
}

export interface ListingsMapProps {
  listings: Listing[];
  /** Finder's visible results (id + weight). Null = no active filter. */
  matches?: GraphMatch[] | null;
  /** Id hovered elsewhere (a finder row) — the matching pin is focused. */
  hoveredId?: string | null;
  /** Pin hover entered/left — drives the reverse (map → finder) highlight. */
  onHover?: (listing: Listing | null) => void;
  /** A pin was activated (clicked). The map opens its own popover regardless. */
  onSelect?: (listing: Listing) => void;
  className?: string;
}

export function ListingsMap({
  listings,
  matches = null,
  hoveredId = null,
  onHover,
  onSelect,
  className,
}: ListingsMapProps) {
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  // Say it out loud when the basemap is about to be blocked by our own policy.
  // Once per mount, not per tile: a blocked map issues one of these per visible
  // tile per pan, which would bury the line it is trying to make visible.
  useEffect(() => {
    if (!TILES_WILL_BE_BLOCKED) return;
    console.warn(
      `[listings-map] BASEMAP TILES WILL BE BLOCKED BY THIS APP'S OWN CSP — ` +
        `requesting ${TILE_URL} but img-src does not allow its origin, so the ` +
        `map will draw pins over an empty graticule. lib/csp.ts adds the tile ` +
        `origin only when NEXT_PUBLIC_FINDER_LANDING=map; set it, set ` +
        `NEXT_PUBLIC_MAP_TILES=off to drop tiles deliberately, or widen ` +
        `mapLandingActive() in lib/map-tiles.ts if this map now mounts elsewhere.`,
    );
  }, []);

  // View + frame state live in refs so panning/zooming never re-renders React.
  const viewRef = useRef<View>({ lng: 10.5, lat: 64.5, zoom: 3.4 });
  const sizeRef = useRef({ w: 0, h: 0, dpr: 1 });
  // Pin screen positions, INDEXED BY the listings array they were computed
  // from — and carrying that array, because an index only means anything
  // alongside it. See `hitTest` for the window this closes.
  const posRef = useRef<{
    list: readonly Listing[];
    pos: Array<{ x: number; y: number } | null>;
  }>({ list: [], pos: [] });
  const hoverRef = useRef(-1);
  const tilesRef = useRef<Map<string, HTMLImageElement>>(new Map());
  const rafRef = useRef<number | null>(null);
  const didFitRef = useRef(false);
  const dragRef = useRef<{
    active: boolean;
    moved: boolean;
    startX: number;
    startY: number;
    startLng: number;
    startLat: number;
  } | null>(null);

  // Latest props mirrored into refs so the long-lived draw/hit closures read
  // current values without being rebuilt every render.
  const listingsRef = useRef(listings);
  const matchesRef = useRef(matches);
  const extHoverRef = useRef(hoveredId);
  const onHoverRef = useRef(onHover);

  // The marker popover is the one piece of real React state — it's a DOM card,
  // not canvas, and it changes rarely (only on a pin click).
  const [selected, setSelected] = useState<{
    listing: Listing;
    x: number;
    y: number;
  } | null>(null);
  const selectedRef = useRef(selected);

  /* ── draw scheduling ───────────────────────────────────────────────────── */

  // `draw` is defined far below and (via getTile) forms a call cycle with
  // scheduleDraw. Reaching it through a ref keeps scheduleDraw from lexically
  // depending on a not-yet-declared value and keeps the cycle acyclic at the
  // module level. An effect right after `draw` keeps this ref current.
  const drawRef = useRef<() => void>(() => {});
  const scheduleDraw = useCallback(() => {
    if (rafRef.current != null) return;
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = null;
      drawRef.current();
    });
  }, []);

  /* ── tiles ─────────────────────────────────────────────────────────────── */

  const getTile = useCallback(
    (z: number, x: number, y: number): HTMLImageElement | null => {
      const key = `${z}/${x}/${y}`;
      const cache = tilesRef.current;
      const existing = cache.get(key);
      if (existing) return existing;

      const img = new Image();
      const url = TILE_URL.replace("{z}", String(z))
        .replace("{x}", String(x))
        .replace("{y}", String(y))
        // The alphabet is shared with `lib/map-tiles.ts`, which expands the same
        // `{s}` into the origins `img-src` allows — indexing a literal here is
        // how the fetched host and the allowed host would drift apart again.
        .replace("{s}", TILE_SUBDOMAINS[(x + y) % TILE_SUBDOMAINS.length]);
      // Redraw when a tile lands so the basemap fills in progressively.
      img.onload = () => scheduleDraw();
      // On error tombstone briefly (no per-frame refetch), then evict so a
      // transient blip — OSM rate-limit, a momentary offline — doesn't leave a
      // permanent gray square for the whole session; the next draw that needs
      // this tile re-creates the request once.
      img.onerror = () => {
        setTimeout(() => {
          if (tilesRef.current.get(key) === img) tilesRef.current.delete(key);
        }, 5000);
      };
      img.src = url;

      // Bound the cache so a long pan session can't leak Image objects.
      if (cache.size > 512) {
        const oldest = cache.keys().next().value;
        if (oldest) cache.delete(oldest);
      }
      cache.set(key, img);
      return img;
    },
    [scheduleDraw],
  );

  const drawTiles = useCallback(
    (ctx: CanvasRenderingContext2D, w: number, h: number) => {
      const { lng, lat, zoom } = viewRef.current;
      const tz = clamp(Math.round(zoom), MIN_ZOOM, MAX_ZOOM);
      const scale = 2 ** (zoom - tz);
      const n = 2 ** tz;
      const cx = lngToWorldX(lng, tz);
      const cy = latToWorldY(lat, tz);

      // World-pixel coordinate of the canvas's top-left corner.
      const originWX = cx - w / 2 / scale;
      const originWY = cy - h / 2 / scale;

      const tx0 = Math.floor(originWX / TILE);
      const ty0 = Math.floor(originWY / TILE);
      const tx1 = Math.floor((originWX + w / scale) / TILE);
      const ty1 = Math.floor((originWY + h / scale) / TILE);

      for (let ty = ty0; ty <= ty1; ty++) {
        if (ty < 0 || ty >= n) continue; // no vertical wrap (poles)
        for (let tx = tx0; tx <= tx1; tx++) {
          const wx = ((tx % n) + n) % n; // wrap horizontally
          const img = getTile(tz, wx, ty);
          if (!img || !img.complete || img.naturalWidth === 0) continue;
          // Place by the UNWRAPPED tile index so wrapped copies sit seamlessly.
          const sx = (tx * TILE - originWX) * scale;
          const sy = (ty * TILE - originWY) * scale;
          const size = TILE * scale + 1; // +1px overlap hides seams
          ctx.drawImage(img, sx, sy, size, size);
        }
      }
    },
    [getTile],
  );

  const drawGraticule = useCallback(
    (ctx: CanvasRenderingContext2D, w: number, h: number) => {
      const { lng, lat, zoom } = viewRef.current;
      const tz = clamp(Math.round(zoom), MIN_ZOOM, MAX_ZOOM);
      const scale = 2 ** (zoom - tz);
      const cx = lngToWorldX(lng, tz);
      const cy = latToWorldY(lat, tz);
      ctx.strokeStyle = withAlpha(canvas.mutedText, 0.18);
      ctx.lineWidth = 1;
      ctx.beginPath();
      // Meridians/parallels every 5° — enough to read motion, not busy.
      for (let g = -180; g <= 180; g += 5) {
        const x = (lngToWorldX(g, tz) - cx) * scale + w / 2;
        if (x >= 0 && x <= w) {
          ctx.moveTo(x, 0);
          ctx.lineTo(x, h);
        }
      }
      for (let g = -80; g <= 80; g += 5) {
        const y = (latToWorldY(g, tz) - cy) * scale + h / 2;
        if (y >= 0 && y <= h) {
          ctx.moveTo(0, y);
          ctx.lineTo(w, y);
        }
      }
      ctx.stroke();
    },
    [],
  );

  /* ── pins ──────────────────────────────────────────────────────────────── */

  const drawPin = useCallback(
    (
      ctx: CanvasRenderingContext2D,
      x: number,
      y: number,
      r: number,
      fill: string,
      dim: boolean,
      ring: boolean,
    ) => {
      ctx.save();
      if (ring) {
        ctx.beginPath();
        ctx.arc(x, y, r + 4, 0, Math.PI * 2);
        ctx.fillStyle = withAlpha(canvas.primary, 0.18);
        ctx.fill();
      }
      ctx.globalAlpha = dim ? 0.45 : 1;
      ctx.shadowColor = withAlpha(canvas.text, 0.35);
      ctx.shadowBlur = 4;
      ctx.shadowOffsetY = 1;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.shadowColor = "transparent";
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = canvas.surface;
      ctx.stroke();
      ctx.restore();
    },
    [],
  );

  const drawLabel = useCallback(
    (ctx: CanvasRenderingContext2D, x: number, y: number, text: string) => {
      ctx.save();
      ctx.font =
        "600 12px ui-sans-serif, system-ui, -apple-system, Segoe UI, sans-serif";
      const padX = 7;
      // Bound the text BEFORE measuring it — `measureText` and `fillText` both
      // cost time proportional to the string, every frame the pin is lit.
      const label = pinLabelText(text);
      const tw = ctx.measureText(label).width;
      const bw = tw + padX * 2;
      const bh = 22;
      let bx = x - bw / 2;
      const by = y - 14 - bh; // float above the pin
      const { w } = sizeRef.current;
      bx = clamp(bx, 4, Math.max(4, w - bw - 4));
      ctx.fillStyle = withAlpha(canvas.text, 0.92);
      const rr = 6;
      ctx.beginPath();
      ctx.moveTo(bx + rr, by);
      ctx.arcTo(bx + bw, by, bx + bw, by + bh, rr);
      ctx.arcTo(bx + bw, by + bh, bx, by + bh, rr);
      ctx.arcTo(bx, by + bh, bx, by, rr);
      ctx.arcTo(bx, by, bx + bw, by, rr);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = canvas.primaryFg;
      ctx.textBaseline = "middle";
      ctx.fillText(label, bx + padX, by + bh / 2 + 0.5);
      ctx.restore();
    },
    [],
  );

  const drawPins = useCallback(
    (ctx: CanvasRenderingContext2D, w: number, h: number) => {
      const list = listingsRef.current;
      const ms = matchesRef.current;
      const rawMatch = ms ? new Map(ms.map((m) => [m.id, m.w])) : null;
      // Only treat the search as a map filter when it actually overlaps the
      // listings. Otherwise — e.g. the finder reads a different source than the
      // map, as with the bundled sample data — a search would gray out EVERY
      // pin. No overlap ⇒ ignore the filter and keep all pins lit. (A genuinely
      // empty result against a SHARED source therefore also stays lit rather
      // than dimming everything; acceptable until a real shared source is wired,
      // at which point pass an explicit "bridge is live" signal to distinguish.)
      const matchMap =
        rawMatch && list.some((l) => rawMatch.has(l.id)) ? rawMatch : null;
      const { lng, lat, zoom } = viewRef.current;
      const tz = clamp(Math.round(zoom), MIN_ZOOM, MAX_ZOOM);
      const scale = 2 ** (zoom - tz);
      const cx = lngToWorldX(lng, tz);
      const cy = latToWorldY(lat, tz);

      const pos: Array<{ x: number; y: number } | null> = new Array(
        list.length,
      ).fill(null);

      // Which pins are "lit" (drawn on top, with a ring + label): the canvas
      // hover, the externally-hovered finder row, and the open popover.
      const litIds = new Set<string>();
      if (extHoverRef.current) litIds.add(extHoverRef.current);
      if (selectedRef.current) litIds.add(selectedRef.current.listing.id);

      const lit: number[] = [];

      for (let i = 0; i < list.length; i++) {
        const l = list[i];
        const x = (lngToWorldX(l.lng, tz) - cx) * scale + w / 2;
        const y = (latToWorldY(l.lat, tz) - cy) * scale + h / 2;
        if (x < -30 || x > w + 30 || y < -30 || y > h + 30) continue;
        pos[i] = { x, y };

        const isLit = i === hoverRef.current || litIds.has(l.id);
        if (isLit) {
          lit.push(i);
          continue; // drawn in the second pass, on top
        }

        const weight = matchMap?.get(l.id);
        const dim = matchMap != null && weight === undefined;
        drawPin(
          ctx,
          x,
          y,
          pinRadius(dim, weight),
          dim ? MARKER_DIM : MARKER,
          dim,
          false,
        );
      }

      // Second pass: lit pins on top, with label.
      for (const i of lit) {
        const p = pos[i];
        if (!p) continue;
        const l = list[i];
        drawPin(ctx, p.x, p.y, 8, MARKER, false, true);
        drawLabel(ctx, p.x, p.y, l.title);
      }

      posRef.current = { list, pos };
    },
    [drawPin, drawLabel],
  );

  /* ── the frame ─────────────────────────────────────────────────────────── */

  const draw = useCallback(() => {
    const cv = canvasRef.current;
    if (!cv) return;
    const { w, h, dpr } = sizeRef.current;
    if (w === 0 || h === 0) return;
    const ctx = cv.getContext("2d");
    if (!ctx) return;

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    // Sea/landless fallback tint, always under the tiles.
    ctx.fillStyle = canvas.mutedSurface;
    ctx.fillRect(0, 0, w, h);

    if (TILES_ENABLED) drawTiles(ctx, w, h);
    else drawGraticule(ctx, w, h);

    drawPins(ctx, w, h);
  }, [drawTiles, drawGraticule, drawPins]);

  // Keep the scheduler's ref pointed at the latest `draw` closure.
  useEffect(() => {
    drawRef.current = draw;
  }, [draw]);

  // A new/closed popover changes which pin is "lit" — mirror it into the draw
  // ref and repaint. (Done in an effect, never a ref write during render.)
  useEffect(() => {
    selectedRef.current = selected;
    scheduleDraw();
  }, [selected, scheduleDraw]);

  /* ── sizing ────────────────────────────────────────────────────────────── */

  const measure = useCallback(() => {
    const wrap = wrapRef.current;
    const cv = canvasRef.current;
    if (!wrap || !cv) return;
    const rect = wrap.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    sizeRef.current = { w, h, dpr };
    cv.width = Math.floor(w * dpr);
    cv.height = Math.floor(h * dpr);
    cv.style.width = `${w}px`;
    cv.style.height = `${h}px`;
  }, []);

  const fitToListings = useCallback(() => {
    const list = listingsRef.current;
    const { w, h } = sizeRef.current;
    if (w === 0 || h === 0) return;
    setSelected(null); // the view is about to move — drop any stale popover

    if (list.length === 0) {
      viewRef.current = { lng: 10.5, lat: 64.5, zoom: 3.4 };
      scheduleDraw();
      return;
    }
    if (list.length === 1) {
      viewRef.current = { lng: list[0].lng, lat: list[0].lat, zoom: 12 };
      scheduleDraw();
      return;
    }

    let minLng = Infinity,
      maxLng = -Infinity,
      minLat = Infinity,
      maxLat = -Infinity;
    for (const l of list) {
      minLng = Math.min(minLng, l.lng);
      maxLng = Math.max(maxLng, l.lng);
      minLat = Math.min(minLat, l.lat);
      maxLat = Math.max(maxLat, l.lat);
    }
    const centerLng = (minLng + maxLng) / 2;
    const centerLat = (minLat + maxLat) / 2;

    // Largest zoom whose bounds still fit inside ~80% of the viewport.
    let zoom = MIN_ZOOM;
    for (let z = MAX_ZOOM; z >= MIN_ZOOM; z--) {
      const spanX = Math.abs(lngToWorldX(maxLng, z) - lngToWorldX(minLng, z));
      const spanY = Math.abs(latToWorldY(maxLat, z) - latToWorldY(minLat, z));
      if (spanX <= w * 0.8 && spanY <= h * 0.8) {
        zoom = z;
        break;
      }
    }
    viewRef.current = { lng: centerLng, lat: clampLat(centerLat), zoom };
    scheduleDraw();
  }, [scheduleDraw]);

  /** Auto-fit once, the first time we have both a real size and the data — but
   * never after the user has taken the view (didFit latches true). The manual
   * Fit button calls `fitToListings` directly, bypassing the latch. */
  const maybeFit = useCallback(() => {
    if (didFitRef.current) return;
    const { w, h } = sizeRef.current;
    if (w === 0 || h === 0) return;
    fitToListings();
    didFitRef.current = true;
  }, [fitToListings]);

  /* ── interaction ───────────────────────────────────────────────────────── */

  const localPoint = (e: { clientX: number; clientY: number }) => {
    const rect = canvasRef.current!.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  };

  const hitTest = (mx: number, my: number): number => {
    const { list, pos } = posRef.current;
    // A hit index is only meaningful for the array the positions were drawn
    // from. A `listings` prop change writes `listingsRef` IMMEDIATELY but
    // defers the repaint to the next animation frame, so for one frame these
    // coordinates describe a DIFFERENT array than the one the index gets
    // resolved against below — which opens the popover for the WRONG listing,
    // or for `undefined` if the array shrank, and `undefined` then throws in
    // render at `selected.listing.title`. Both halves were reproduced with
    // real pointer input against a transplant of this exact ref/rAF ordering.
    // Refusing the hit costs at most the one frame before the redraw lands.
    if (list !== listingsRef.current) return -1;
    let best = -1;
    let bestD = HIT_RADIUS * HIT_RADIUS;
    for (let i = 0; i < pos.length; i++) {
      const p = pos[i];
      if (!p) continue;
      const dx = p.x - mx;
      const dy = p.y - my;
      const d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  };

  const setHover = useCallback(
    (idx: number) => {
      if (idx === hoverRef.current) return;
      hoverRef.current = idx;
      const cv = canvasRef.current;
      if (cv) cv.style.cursor = idx >= 0 ? "pointer" : "grab";
      onHoverRef.current?.(idx >= 0 ? listingsRef.current[idx] : null);
      scheduleDraw();
    },
    [scheduleDraw],
  );

  const onPointerDown = (e: React.PointerEvent) => {
    const { x, y } = localPoint(e);
    const v = viewRef.current;
    dragRef.current = {
      active: true,
      moved: false,
      startX: x,
      startY: y,
      startLng: v.lng,
      startLat: v.lat,
    };
    canvasRef.current?.setPointerCapture(e.pointerId);
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const { x, y } = localPoint(e);
    const drag = dragRef.current;
    if (drag?.active) {
      const dx = x - drag.startX;
      const dy = y - drag.startY;
      if (!drag.moved && dx * dx + dy * dy > 9) {
        drag.moved = true;
        if (selectedRef.current) setSelected(null); // dragging dismisses popover
        const cv = canvasRef.current;
        if (cv) cv.style.cursor = "grabbing";
      }
      if (drag.moved) {
        const { zoom } = viewRef.current;
        const tz = clamp(Math.round(zoom), MIN_ZOOM, MAX_ZOOM);
        const scale = 2 ** (zoom - tz);
        const cx = lngToWorldX(drag.startLng, tz) - dx / scale;
        const cy = latToWorldY(drag.startLat, tz) - dy / scale;
        viewRef.current = {
          lng: worldXToLng(cx, tz),
          lat: clampLat(worldYToLat(cy, tz)),
          zoom,
        };
        scheduleDraw();
      }
      return;
    }
    setHover(hitTest(x, y));
  };

  const endDrag = (e: React.PointerEvent) => {
    const drag = dragRef.current;
    canvasRef.current?.releasePointerCapture(e.pointerId);
    dragRef.current = null;
    if (drag) {
      const cv = canvasRef.current;
      if (cv) cv.style.cursor = hoverRef.current >= 0 ? "pointer" : "grab";
    }
    if (drag && !drag.moved) {
      // A click (no pan): activate a pin, or clear the popover on empty space.
      const { x, y } = localPoint(e);
      const idx = hitTest(x, y);
      if (idx >= 0) {
        const l = listingsRef.current[idx];
        const p = posRef.current.pos[idx];
        if (p) {
          // Pre-clamp the anchor here (an event handler — ref reads are fine)
          // so the render path never has to touch sizeRef. The card is w-60
          // (240px) and translates -50% x / -100% y off this point.
          const { w } = sizeRef.current;
          setSelected({
            listing: l,
            x: clamp(p.x, 124, Math.max(124, w - 124)),
            y: Math.max(96, p.y - 16),
          });
        } else {
          setSelected(null);
        }
        onSelect?.(l);
      } else {
        setSelected(null);
      }
    }
  };

  const onPointerLeave = () => {
    if (!dragRef.current?.active) setHover(-1);
  };

  const zoomBy = useCallback(
    (delta: number, ax?: number, ay?: number) => {
      setSelected(null); // zooming moves every pin — drop any stale popover
      const { w, h } = sizeRef.current;
      const mx = ax ?? w / 2;
      const my = ay ?? h / 2;
      const v = viewRef.current;
      const zoom = clamp(v.zoom + delta, MIN_ZOOM, MAX_ZOOM);
      // Hold the geographic point under (mx,my) fixed on screen. Do the whole
      // correction in WORLD-PIXEL space (linear) and unproject only at the end:
      // adding a lng/lat-space delta drifts on the non-linear latitude axis
      // (~50px per zoom burst at the Nordic latitudes the data lives at).
      const tz0 = clamp(Math.round(v.zoom), MIN_ZOOM, MAX_ZOOM);
      const s0 = 2 ** (v.zoom - tz0);
      const gLng = worldXToLng(lngToWorldX(v.lng, tz0) + (mx - w / 2) / s0, tz0);
      const gLat = worldYToLat(latToWorldY(v.lat, tz0) + (my - h / 2) / s0, tz0);
      const tz1 = clamp(Math.round(zoom), MIN_ZOOM, MAX_ZOOM);
      const s1 = 2 ** (zoom - tz1);
      const ncx = lngToWorldX(gLng, tz1) - (mx - w / 2) / s1;
      const ncy = latToWorldY(gLat, tz1) - (my - h / 2) / s1;
      viewRef.current = {
        zoom,
        lng: worldXToLng(ncx, tz1),
        lat: clampLat(worldYToLat(ncy, tz1)),
      };
      scheduleDraw();
    },
    [scheduleDraw],
  );

  /* ── effects: mount sizing, wheel, prop sync ───────────────────────────── */

  useEffect(() => {
    measure();
    maybeFit();

    const ro = new ResizeObserver(() => {
      measure();
      maybeFit(); // covers a 0-size first measure (fit lands when size arrives)
      setSelected(null); // pins reproject on resize — drop any stale popover
      scheduleDraw();
    });
    if (wrapRef.current) ro.observe(wrapRef.current);
    return () => ro.disconnect();
    // Mount once; prop-driven redraws are handled by the effects below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Wheel zoom needs a non-passive listener to preventDefault the page scroll.
  useEffect(() => {
    const cv = canvasRef.current;
    if (!cv) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const rect = cv.getBoundingClientRect();
      zoomBy(-e.deltaY * 0.0025, e.clientX - rect.left, e.clientY - rect.top);
    };
    cv.addEventListener("wheel", onWheel, { passive: false });
    return () => cv.removeEventListener("wheel", onWheel);
  }, [zoomBy]);

  // New listings → re-fit (only while the user hasn't taken over the view yet)
  // and always redraw.
  useEffect(() => {
    listingsRef.current = listings;
    maybeFit();
    scheduleDraw();
  }, [listings, maybeFit, scheduleDraw]);

  useEffect(() => {
    matchesRef.current = matches;
    scheduleDraw();
  }, [matches, scheduleDraw]);

  useEffect(() => {
    extHoverRef.current = hoveredId;
    scheduleDraw();
  }, [hoveredId, scheduleDraw]);

  useEffect(() => {
    onHoverRef.current = onHover;
  }, [onHover]);

  /* ── render ────────────────────────────────────────────────────────────── */

  return (
    <div
      ref={wrapRef}
      className={`relative h-full w-full overflow-hidden bg-muted-surface ${className ?? ""}`}
    >
      <canvas
        ref={canvasRef}
        className="absolute inset-0 touch-none select-none"
        style={{ cursor: "grab" }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onPointerLeave={onPointerLeave}
      />

      {/* Zoom + fit controls — quiet, top-right. */}
      <div className="absolute right-3 top-3 z-20 flex flex-col gap-1">
        <button
          type="button"
          aria-label="Zoom in"
          onClick={() => zoomBy(1)}
          className="flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white/95 text-lg leading-none text-zinc-700 shadow-sm hover:bg-white"
        >
          +
        </button>
        <button
          type="button"
          aria-label="Zoom out"
          onClick={() => zoomBy(-1)}
          className="flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white/95 text-lg leading-none text-zinc-700 shadow-sm hover:bg-white"
        >
          −
        </button>
        <button
          type="button"
          aria-label="Fit all locations"
          onClick={() => fitToListings()}
          className="mt-1 flex h-8 w-8 items-center justify-center rounded-md border border-zinc-300 bg-white/95 text-zinc-700 shadow-sm hover:bg-white"
        >
          <svg width="15" height="15" viewBox="0 0 15 15" fill="none" aria-hidden>
            <path
              d="M2 5V2h3M13 5V2h-3M2 10v3h3M13 10v3h-3"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
            />
          </svg>
        </button>
      </div>

      {/* Marker popover — a plain DOM card anchored to the clicked pin. */}
      {selected ? (
        <div
          className="absolute z-30 w-60 -translate-x-1/2 -translate-y-full rounded-xl border border-zinc-200 bg-white p-3 shadow-lg"
          style={{ left: selected.x, top: selected.y }}
        >
          <button
            type="button"
            aria-label="Close"
            onClick={() => setSelected(null)}
            className="absolute right-2 top-2 text-zinc-400 hover:text-zinc-700"
          >
            ✕
          </button>
          <div className="pr-4">
            <p className="text-sm font-semibold text-zinc-900">
              {selected.listing.title}
            </p>
            {selected.listing.category || selected.listing.city ? (
              <p className="mt-0.5 text-xs text-zinc-500">
                {[selected.listing.category, selected.listing.city]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            ) : null}
          </div>
          {selected.listing.description ? (
            <p className="mt-2 line-clamp-3 text-xs leading-5 text-zinc-600">
              {selected.listing.description}
            </p>
          ) : null}
          {selected.listing.tags?.length ? (
            <div className="mt-2 flex flex-wrap gap-1">
              {selected.listing.tags.slice(0, 4).map((t) => (
                <span
                  key={t}
                  className="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-medium text-zinc-600"
                >
                  {t.replace(/_/g, " ")}
                </span>
              ))}
            </div>
          ) : null}
          <div className="mt-3 flex items-center gap-3 text-xs font-medium">
            {detailHref(selected.listing) ? (
              <a
                href={detailHref(selected.listing)!}
                target="_blank"
                rel="noreferrer"
                className="text-rose-600 hover:underline"
              >
                Website ↗
              </a>
            ) : null}
            <a
              href={`https://www.openstreetmap.org/?mlat=${selected.listing.lat}&mlon=${selected.listing.lng}#map=16/${selected.listing.lat}/${selected.listing.lng}`}
              target="_blank"
              rel="noreferrer"
              className="text-zinc-500 hover:underline"
            >
              Directions ↗
            </a>
          </div>
        </div>
      ) : null}

      {SHOWS_OSM_ATTRIBUTION ? (
        <div className="absolute bottom-0 right-0 z-20 rounded-tl bg-white/80 px-1.5 py-0.5 text-[0.6rem] text-zinc-500">
          ©{" "}
          <a
            href="https://www.openstreetmap.org/copyright"
            target="_blank"
            rel="noreferrer"
            className="hover:underline"
          >
            OpenStreetMap
          </a>{" "}
          contributors
        </div>
      ) : null}
    </div>
  );
}
