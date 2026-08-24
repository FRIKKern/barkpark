"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Place } from "@/lib/places";
import { categoryLabel } from "@/lib/categories";
import styles from "./places-map.module.css";

/**
 * A self-contained slippy map of dog-place pins — adapted from the monorepo's
 * `web/components/listings-map.tsx`.
 *
 * House rules kept verbatim: vanilla Canvas2D, ZERO npm map libs (no Leaflet /
 * Mapbox / MapLibre), ZERO build-time tile bundle. The only network it touches
 * is the raster tile server the browser fetches at runtime (OpenStreetMap by
 * default), and that is OPTIONAL — with tiles off (or blocked) pins still draw
 * over a calm graticule, so the surface never collapses to a blank box.
 *
 * Differences from the source:
 *   - The finder↔map bridge (matches / hoveredId / onHover) is dropped — this
 *     directory has no left-rail finder. A single optional `onSelect` remains.
 *   - Pins are terracotta (the Pawtrails accent), styling moved to a CSS module.
 *   - The popover links to the in-app detail page (`/sted/<slug>`) plus OSM
 *     directions, and reads the `Place` shape.
 *   - `initialView` lets the detail page centre tightly on one pin.
 */

const TILE = 256;
const MIN_ZOOM = 2;
const MAX_ZOOM = 18;
/** Mercator clamps near the poles — past this the projection blows up. */
const MAX_LAT = 85.05;
/** Pointer-to-pin hit radius, in CSS px. */
const HIT_RADIUS = 16;

/** Terracotta — the Pawtrails accent. Mirrors `--accent` for canvas use. */
const MARKER = "#A23925";
const MARKER_RING = "rgba(162, 57, 37, 0.18)";

const TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const TILES_ENABLED = process.env.NEXT_PUBLIC_MAP_TILES !== "off";

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

interface View {
  lng: number;
  lat: number;
  zoom: number;
}

export interface PlacesMapProps {
  places: Place[];
  /** A pin was activated (clicked). The map opens its own popover regardless. */
  onSelect?: (place: Place) => void;
  /** Override the initial centre/zoom (the detail page passes one pin's view).
   * When set, the auto-fit is suppressed. */
  initialView?: View;
  className?: string;
}

export function PlacesMap({
  places,
  onSelect,
  initialView,
  className,
}: PlacesMapProps) {
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  // View + frame state live in refs so panning/zooming never re-renders React.
  const viewRef = useRef<View>(
    initialView ?? { lng: 13, lat: 64.5, zoom: 3.6 },
  );
  const sizeRef = useRef({ w: 0, h: 0, dpr: 1 });
  const posRef = useRef<Array<{ x: number; y: number } | null>>([]);
  const hoverRef = useRef(-1);
  const tilesRef = useRef<Map<string, HTMLImageElement>>(new Map());
  const rafRef = useRef<number | null>(null);
  const didFitRef = useRef(initialView != null);
  const dragRef = useRef<{
    active: boolean;
    moved: boolean;
    startX: number;
    startY: number;
    startLng: number;
    startLat: number;
  } | null>(null);

  const placesRef = useRef(places);

  const [selected, setSelected] = useState<{
    place: Place;
    x: number;
    y: number;
  } | null>(null);
  const selectedRef = useRef(selected);

  /* ── draw scheduling ───────────────────────────────────────────────────── */

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
        .replace("{y}", String(y));
      img.onload = () => scheduleDraw();
      img.onerror = () => {
        setTimeout(() => {
          if (tilesRef.current.get(key) === img) tilesRef.current.delete(key);
        }, 5000);
      };
      img.src = url;

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

      const originWX = cx - w / 2 / scale;
      const originWY = cy - h / 2 / scale;

      const tx0 = Math.floor(originWX / TILE);
      const ty0 = Math.floor(originWY / TILE);
      const tx1 = Math.floor((originWX + w / scale) / TILE);
      const ty1 = Math.floor((originWY + h / scale) / TILE);

      for (let ty = ty0; ty <= ty1; ty++) {
        if (ty < 0 || ty >= n) continue;
        for (let tx = tx0; tx <= tx1; tx++) {
          const wx = ((tx % n) + n) % n;
          const img = getTile(tz, wx, ty);
          if (!img || !img.complete || img.naturalWidth === 0) continue;
          const sx = (tx * TILE - originWX) * scale;
          const sy = (ty * TILE - originWY) * scale;
          const size = TILE * scale + 1;
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
      ctx.strokeStyle = "rgba(154, 150, 139, 0.28)";
      ctx.lineWidth = 1;
      ctx.beginPath();
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
      ring: boolean,
    ) => {
      ctx.save();
      if (ring) {
        ctx.beginPath();
        ctx.arc(x, y, r + 5, 0, Math.PI * 2);
        ctx.fillStyle = MARKER_RING;
        ctx.fill();
      }
      ctx.shadowColor = "rgba(26, 26, 26, 0.3)";
      ctx.shadowBlur = 4;
      ctx.shadowOffsetY = 1;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fillStyle = MARKER;
      ctx.fill();
      ctx.shadowColor = "transparent";
      ctx.lineWidth = 1.5;
      ctx.strokeStyle = "#FBFAF6";
      ctx.stroke();
      ctx.restore();
    },
    [],
  );

  const drawLabel = useCallback(
    (ctx: CanvasRenderingContext2D, x: number, y: number, text: string) => {
      ctx.save();
      ctx.font =
        '600 12.5px ui-sans-serif, system-ui, -apple-system, "Inter Tight", sans-serif';
      const padX = 8;
      const tw = ctx.measureText(text).width;
      const bw = tw + padX * 2;
      const bh = 24;
      let bx = x - bw / 2;
      const by = y - 16 - bh;
      const { w } = sizeRef.current;
      bx = clamp(bx, 4, Math.max(4, w - bw - 4));
      ctx.fillStyle = "rgba(26, 26, 26, 0.92)";
      const rr = 6;
      ctx.beginPath();
      ctx.moveTo(bx + rr, by);
      ctx.arcTo(bx + bw, by, bx + bw, by + bh, rr);
      ctx.arcTo(bx + bw, by + bh, bx, by + bh, rr);
      ctx.arcTo(bx, by + bh, bx, by, rr);
      ctx.arcTo(bx, by, bx + bw, by, rr);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = "#FBFAF6";
      ctx.textBaseline = "middle";
      ctx.fillText(text, bx + padX, by + bh / 2 + 0.5);
      ctx.restore();
    },
    [],
  );

  const drawPins = useCallback(
    (ctx: CanvasRenderingContext2D, w: number, h: number) => {
      const list = placesRef.current;
      const { lng, lat, zoom } = viewRef.current;
      const tz = clamp(Math.round(zoom), MIN_ZOOM, MAX_ZOOM);
      const scale = 2 ** (zoom - tz);
      const cx = lngToWorldX(lng, tz);
      const cy = latToWorldY(lat, tz);

      const pos: Array<{ x: number; y: number } | null> = new Array(
        list.length,
      ).fill(null);

      const litIds = new Set<string>();
      if (selectedRef.current) litIds.add(selectedRef.current.place.id);

      const lit: number[] = [];

      for (let i = 0; i < list.length; i++) {
        const l = list[i];
        const x = (lngToWorldX(l.lng, tz) - cx) * scale + w / 2;
        const y = (latToWorldY(l.lat, tz) - cy) * scale + h / 2;
        if (x < -30 || x > w + 30 || y < -30 || y > h + 30) continue;
        pos[i] = { x, y };

        if (i === hoverRef.current || litIds.has(l.id)) {
          lit.push(i);
          continue;
        }
        drawPin(ctx, x, y, 6, false);
      }

      for (const i of lit) {
        const p = pos[i];
        if (!p) continue;
        drawPin(ctx, p.x, p.y, 8, true);
        drawLabel(ctx, p.x, p.y, list[i].title);
      }

      posRef.current = pos;
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
    ctx.fillStyle = "#EDE7D6";
    ctx.fillRect(0, 0, w, h);

    if (TILES_ENABLED) drawTiles(ctx, w, h);
    else drawGraticule(ctx, w, h);

    drawPins(ctx, w, h);
  }, [drawTiles, drawGraticule, drawPins]);

  useEffect(() => {
    drawRef.current = draw;
  }, [draw]);

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

  const fitToPlaces = useCallback(() => {
    const list = placesRef.current;
    const { w, h } = sizeRef.current;
    if (w === 0 || h === 0) return;
    setSelected(null);

    if (list.length === 0) {
      viewRef.current = { lng: 13, lat: 64.5, zoom: 3.6 };
      scheduleDraw();
      return;
    }
    if (list.length === 1) {
      viewRef.current = { lng: list[0].lng, lat: list[0].lat, zoom: 13 };
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

    let zoom = MIN_ZOOM;
    for (let z = MAX_ZOOM; z >= MIN_ZOOM; z--) {
      const spanX = Math.abs(lngToWorldX(maxLng, z) - lngToWorldX(minLng, z));
      const spanY = Math.abs(latToWorldY(maxLat, z) - latToWorldY(minLat, z));
      if (spanX <= w * 0.78 && spanY <= h * 0.78) {
        zoom = z;
        break;
      }
    }
    viewRef.current = { lng: centerLng, lat: clampLat(centerLat), zoom };
    scheduleDraw();
  }, [scheduleDraw]);

  const maybeFit = useCallback(() => {
    if (didFitRef.current) return;
    const { w, h } = sizeRef.current;
    if (w === 0 || h === 0) return;
    fitToPlaces();
    didFitRef.current = true;
  }, [fitToPlaces]);

  /* ── interaction ───────────────────────────────────────────────────────── */

  const localPoint = (e: { clientX: number; clientY: number }) => {
    const rect = canvasRef.current!.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  };

  const hitTest = (mx: number, my: number): number => {
    const pos = posRef.current;
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
        if (selectedRef.current) setSelected(null);
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
      const { x, y } = localPoint(e);
      const idx = hitTest(x, y);
      if (idx >= 0) {
        const l = placesRef.current[idx];
        const p = posRef.current[idx];
        if (p) {
          const { w } = sizeRef.current;
          setSelected({
            place: l,
            x: clamp(p.x, 128, Math.max(128, w - 128)),
            y: Math.max(120, p.y - 16),
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
      setSelected(null);
      const { w, h } = sizeRef.current;
      const mx = ax ?? w / 2;
      const my = ay ?? h / 2;
      const v = viewRef.current;
      const zoom = clamp(v.zoom + delta, MIN_ZOOM, MAX_ZOOM);
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
    scheduleDraw();

    const ro = new ResizeObserver(() => {
      measure();
      maybeFit();
      setSelected(null);
      scheduleDraw();
    });
    if (wrapRef.current) ro.observe(wrapRef.current);
    return () => ro.disconnect();
    // Mount once; prop-driven redraws handled below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

  useEffect(() => {
    placesRef.current = places;
    maybeFit();
    scheduleDraw();
  }, [places, maybeFit, scheduleDraw]);

  /* ── render ────────────────────────────────────────────────────────────── */

  return (
    <div
      ref={wrapRef}
      className={`${styles.wrap} ${className ?? ""}`}
    >
      <canvas
        ref={canvasRef}
        className={styles.canvas}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onPointerLeave={onPointerLeave}
      />

      <div className={styles.controls}>
        <button
          type="button"
          aria-label="Zoom inn"
          onClick={() => zoomBy(1)}
          className={styles.ctrl}
        >
          +
        </button>
        <button
          type="button"
          aria-label="Zoom ut"
          onClick={() => zoomBy(-1)}
          className={styles.ctrl}
        >
          −
        </button>
        <button
          type="button"
          aria-label="Vis alle steder"
          onClick={() => fitToPlaces()}
          className={`${styles.ctrl} ${styles.ctrlFit}`}
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

      {selected ? (
        <div
          className={styles.popover}
          style={{ left: selected.x, top: selected.y }}
        >
          <button
            type="button"
            aria-label="Lukk"
            onClick={() => setSelected(null)}
            className={styles.popClose}
          >
            ✕
          </button>
          <div className={styles.popHead}>
            <p className={styles.popTitle}>{selected.place.title}</p>
            {selected.place.category || selected.place.city ? (
              <p className={styles.popMeta}>
                {[categoryLabel(selected.place.category), selected.place.city]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            ) : null}
          </div>
          {selected.place.description ? (
            <p className={styles.popDesc}>{selected.place.description}</p>
          ) : null}
          <div className={styles.popLinks}>
            <a
              href={`/sted/${selected.place.slug}`}
              className={styles.popLink}
            >
              Se stedet →
            </a>
            <a
              href={`https://www.openstreetmap.org/?mlat=${selected.place.lat}&mlon=${selected.place.lng}#map=16/${selected.place.lat}/${selected.place.lng}`}
              target="_blank"
              rel="noreferrer"
              className={styles.popLinkMuted}
            >
              Veibeskrivelse ↗
            </a>
          </div>
        </div>
      ) : null}

      {/* OSM's attribution requirement is the phrase "© OpenStreetMap
          contributors", not the project's name alone: the map data is
          copyright the CONTRIBUTORS, and the Foundation holds no copyright in
          it. Crediting "© OpenStreetMap" names the wrong party — and it is the
          only OSM credit anywhere on this site, so nothing else supplies the
          missing word. The web twin this component was adapted from
          (web/components/listings-map.tsx) has always rendered the full
          phrase; only this copy lost it. */}
      {TILES_ENABLED ? (
        <div className={styles.attribution}>
          ©{" "}
          <a
            href="https://www.openstreetmap.org/copyright"
            target="_blank"
            rel="noreferrer"
          >
            OpenStreetMap
          </a>{" "}
          contributors
        </div>
      ) : null}
    </div>
  );
}
