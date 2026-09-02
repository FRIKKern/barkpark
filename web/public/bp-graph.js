// ─────────────────────────────────────────────────────────────────────────
// MIRROR SET — canonical lives at api/priv/static/assets/bp-graph.js
// This file is kept BYTE-IDENTICAL across four surfaces:
//   • api/priv/static/assets/bp-graph.js           (canonical — Studio blast-radius pane)
//   • web/public/bp-graph.js                       (mirror — Next.js web demo landing)
//   • templates/search-starter/public/bp-graph.js  (mirror — Next search template)
//   • templates/astro-search-starter/public/bp-graph.js (mirror — Astro search template)
// Edit the canonical copy, then copy it verbatim to every mirror. Never
// hand-edit one side alone — the first two drifted to 0.79 similarity once and
// had to be reconciled (Cody duplication finding, task-e94f519629c2dc52), and
// the template snapshots later went 19 lines stale (missing setTheme), which
// shipped a dead theme toggle. Verify: md5 -q <all four> | sort -u | wc -l → 1.
// ─────────────────────────────────────────────────────────────────────────
// bp-graph.js — Obsidian-style graph renderer for the Studio blast-radius
// pane. Self-contained vanilla Canvas2D + a hand-rolled velocity-Verlet force
// simulation. ZERO npm, ZERO network-fetched libs, ZERO font fetch (Golden
// Rule). Cytoscape is fully gutted.
//
// PUBLIC SURFACE (the integration contract):
//   window.BarkparkGraphRenderer(containerEl, {nodes, edges}, opts)
//       -> { update(nodes, edges), destroy(), fit() }   (pure renderer)
//   window.BarkparkGraph = Hooks.GraphPane                (thin phx wrapper)
//
// The renderer creates its own <canvas>, owns ONE rAF loop (sim-tick + draw),
// and tears down every listener / rAF / observer on destroy(). The phx hook
// reads data-nodes / data-edges / data-rev off #studio-graph and delegates;
// it parses in a try/catch and renders an authored amber PARSE-ERROR state
// instead of the old silent JSON.parse -> [] swallow.
//
// THE THESIS: restraint. Small flat dots, thin faint threads, near-monochrome,
// generous empty space, a calm sim that settles to rest. Structure legible at
// a glance — Obsidian's graph view, not a glowing nebula. The root/active node
// wears the accent and is only slightly larger; hovering a node lifts it and
// its 1-hop neighbors while everything else fades back.
(function () {
  "use strict";

  // ───────────────────────────────────────────────────────────── constants ──
  // Obsidian-faithful restyle: small flat dots, thin faint threads, near-
  // monochrome, generous void. Beauty through restraint. The luminous-nebula
  // language (orbs, corona, blast-rings, vignette, glyphs) is gone.
  var ACCENT = "#9a8cff"; // root / active / selection — soft Obsidian violet
  var ACCENT_RGB = [154, 140, 255];
  var A11Y_RING = "#60A5FA"; // keyboard-focus ring, kept DISTINCT from accent
  var SLATE = "#94A3B8"; // _unknown + phantom + ash mix target
  var AMBER = "#FBBF24"; // the only warm pixel — parse-error state

  // Monochrome node tint — one muted desaturated lavender-grey for EVERY node
  // on dark (the default look). Per-type color is the opt-in "Full color" toggle.
  var MONO_DARK = "#a6adc0"; // dark-theme resting node fill (soft cool blue-grey)
  var MONO_LIGHT = "#5a5f6e"; // light-theme resting node fill (dark dot on white)
  var NODE_WHITE = "#f2f3f8"; // hovered/neighbor brighten target (dark)

  // Flat theme backgrounds (no gradient, no vignette).
  var BG_DARK = "#16161a";
  var BG_LIGHT = "#f4f4f6";

  // Link base color/opacity — very faint thin threads.
  var LINK_RGB_DARK = "170,180,205";
  var LINK_RGB_LIGHT = "40,44,58";
  var LINK_A_DARK = 0.09; // resting link alpha (dark) — very faint thread
  var LINK_A_LIGHT = 0.14; // resting link alpha (light)
  var LINK_A_FOCUS = 0.5; // incident-to-hover link alpha (bright)
  var LINK_A_DIM = 0.03; // non-incident link alpha under hover (dim hard)

  // Node radius range (gentle sqrt scale with degree). Small flat dots.
  var NODE_R_MIN = 3.5;
  var NODE_R_MAX = 6;

  // On-screen drawn-radius cap (px): even zoomed in, a dot never becomes a disc.
  var NODE_R_SCREEN_MAX = 10;

  // Hover focus: non-focus nodes fade to this; their links to LINK_A_DIM.
  var HOVER_DIM_ALPHA = 0.15; // dim hard so the focused ego-network pops

  // ── z-depth ──────────────────────────────────────────────────────────────
  // A SEPARATE channel from opacity: each node carries an animated `depth`
  // (1 = forward/full-size, < 1 = receded/smaller) driven by its FOCUS DISTANCE
  // — BFS hops from the hovered node, or match-weakness under a search. Because
  // it keys off hover-distance (set identically by canvas hover AND the list→
  // graph bridge), the recede reads the same whichever surface drives focus, and
  // it never double-counts the search-dim the way an opacity-coupled scale did.
  var DEPTH_FAR = 0.5; // floor: a fully-distant / unmatched dot draws at half size
  var DEPTH_RING = 0.58; // per-ring recede factor past the 1-hop ego (smaller = steeper)
  // Focus-distance → target scale. Ego (hovered + 1-hop) stays full; rings 2+
  // recede geometrically toward the floor; unreachable (undefined) sits at floor.
  function depthForDist(d) {
    if (d === 0 || d === 1) return 1;
    if (d === undefined) return DEPTH_FAR;
    return DEPTH_FAR + (1 - DEPTH_FAR) * Math.pow(DEPTH_RING, d - 1);
  }

  // Label color (muted grey) + zoom-fade thresholds.
  var LABEL_COLOR_DARK = "#8b92a3"; // muted grey
  var LABEL_COLOR_LIGHT = "#5a5f6e";
  // Obsidian text-fade is FIT-RELATIVE: the auto-fit scale for a spread layout
  // can land well below any fixed value, so we gate labels off the ratio of the
  // current camera scale to the captured fitScale rather than absolute scale.
  //   currentScale <= fitScale * LABEL_FADE_LO_MULT  -> opacity 0  (default/wide = clean)
  //   ramp (easeOutCubic) to opacity 1 by fitScale * LABEL_FADE_HI_MULT
  // On first load cam.scale == fitScale, so the ratio is 1.0 < 1.2 → no labels.
  // Hovered node + its 1-hop neighbors are the ONLY always-on exceptions.
  var LABEL_FADE_LO_MULT = 1.2; // <= fitScale*this → hidden (default view)
  var LABEL_FADE_HI_MULT = 2.4; // >= fitScale*this → fully in (~2.4x zoom-in)

  var FONT_STACK =
    "Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', ui-sans-serif, system-ui, sans-serif";

  // Per-type hues — used ONLY when the optional "Full color" toggle is on.
  // The default look is monochrome (MONO_DARK/MONO_LIGHT), so this is capacity,
  // not a mandate. Every node is a plain filled circle; type is not a shape or
  // glyph channel anymore (Obsidian draws plain dots).
  var TYPE_HEX = {
    post: "#7C8CEF",
    page: "#9B82ED",
    paper: "#38BDF8",
    task: "#FB7185",
    author: "#34D399",
    category: "#4ADE80",
    book: "#FBBF24",
    asset: "#FB923C",
    mediaAsset: "#FB923C",
    sheet: "#22D3EE",
    project: "#A3E635",
    "game-data": "#E879F9",
    // Live dogfood-corpus types (search-starter flagship). Same Tailwind-400
    // family as the rest of the palette; each hue is distinct from every type
    // it actually co-occurs with (task=rose, paper=sky dominate that corpus).
    tag: "#2DD4BF",
    command: "#C084FC",
    metric: "#FACC15",
    session: "#F472B6",
    _unknown: SLATE
  };

  // ─────────────────────────────────────────────────────────── color utils ──
  function hexToRgb(hex) {
    var h = hex.replace("#", "");
    if (h.length === 3) {
      h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    }
    return [
      parseInt(h.slice(0, 2), 16),
      parseInt(h.slice(2, 4), 16),
      parseInt(h.slice(4, 6), 16)
    ];
  }
  function rgbToHex(r, g, b) {
    function c(v) {
      var s = Math.max(0, Math.min(255, Math.round(v))).toString(16);
      return s.length === 1 ? "0" + s : s;
    }
    return "#" + c(r) + c(g) + c(b);
  }
  function rgba(hex, a) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a + ")";
  }
  // Mix hexA toward hexB by t in [0,1].
  function mixHex(hexA, hexB, t) {
    var a = hexToRgb(hexA);
    var b = hexToRgb(hexB);
    return rgbToHex(
      a[0] + (b[0] - a[0]) * t,
      a[1] + (b[1] - a[1]) * t,
      a[2] + (b[2] - a[2]) * t
    );
  }
  // Rank → highlight colour. Mirrors the finder list's `highlightColors` red→
  // emerald sweep (lib/fuzzy.ts) so a node's colour matches the highlight tint of
  // its result row: top of the list = vivid emerald, weakest visible = warm red.
  // `mw` is the rank-derived match weight (≈0.2 tail → 1 top); normalize across
  // that visible band to drive the full hue sweep. Opaque + lifted for a dark dot.
  function rankColor(mw) {
    var t = clamp((mw - 0.2) / 0.8, 0, 1); // 0 = weakest visible → 1 = top hit
    var h = (t * 162) / 360; // 0 red → 162 emerald (same hue sweep as the list)
    var s = (58 + t * 37) / 100; // 58% → 95% (vivid head)
    var l = (58 - t * 4) / 100; // 58% → 54% (legible on the dark bed)
    // HSL → hex so it composes with mixHex.
    function h2(p, q, x) {
      if (x < 0) x += 1;
      if (x > 1) x -= 1;
      if (x < 1 / 6) return p + (q - p) * 6 * x;
      if (x < 1 / 2) return q;
      if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
      return p;
    }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    var p = 2 * l - q;
    return rgbToHex(h2(p, q, h + 1 / 3) * 255, h2(p, q, h) * 255, h2(p, q, h - 1 / 3) * 255);
  }
  // Perceptual-ish lighten/darken via HSL-L offset (good enough for rims).
  function shiftL(hex, dl) {
    var c = hexToRgb(hex);
    var r = c[0] / 255,
      g = c[1] / 255,
      b = c[2] / 255;
    var max = Math.max(r, g, b),
      min = Math.min(r, g, b);
    var l = (max + min) / 2;
    var h = 0,
      s = 0;
    if (max !== min) {
      var d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
    }
    l = Math.max(0, Math.min(1, l + dl));
    function hue2rgb(p, q, t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }
    var R, G, B;
    if (s === 0) {
      R = G = B = l;
    } else {
      var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      var p = 2 * l - q;
      R = hue2rgb(p, q, h + 1 / 3);
      G = hue2rgb(p, q, h);
      B = hue2rgb(p, q, h - 1 / 3);
    }
    return rgbToHex(R * 255, G * 255, B * 255);
  }

  function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
  }
  function easeOutCubic(t) {
    return 1 - Math.pow(1 - t, 3);
  }
  function easeOutExpo(t) {
    return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t);
  }
  function easeInOutCubic(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }
  function easeOutBack(t) {
    // Canonical overshoot constant (~10%): 1.08 gave only ~3%, imperceptible —
    // the orbs effectively arrived with a plain decelerate. Only consumer is
    // entrance scaleK, so raising it is isolated.
    var c1 = 1.7,
      c3 = c1 + 1;
    return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
  }
  // Frame-rate-independent lerp factor.
  function kStep(baseK, dt) {
    return 1 - Math.pow(1 - baseK, dt / 16.67);
  }

  // ───────────────────────────────────────────── client type-resolution ──
  // graph.ex:194 emits type:nil,title:slug for EVERY drafts node. Resolve so
  // the palette is reachable on both paths; monochrome ash is CORRECT, not a
  // bug. Order: explicit type -> doc_id prefix -> published-sibling -> slate.
  var PREFIX_RX = /^([A-Za-z][A-Za-z0-9_-]*)[.:]/;
  function resolveType(node, prefixHint) {
    if (typeof node.type === "string" && node.type !== "") return node.type;
    var s = String(node.doc_id || node.id || "").replace(/^drafts\./, "");
    var m = s.match(PREFIX_RX);
    if (m && TYPE_HEX[m[1]]) return m[1];
    if (prefixHint && TYPE_HEX[prefixHint]) return prefixHint;
    return "_unknown";
  }

  // ════════════════════════════════════════════════════════════ RENDERER ══
  function BarkparkGraphRenderer(containerEl, data, opts) {
    opts = opts || {};

    // ── theme + motion resolution ──
    var prefersDark = true;
    try {
      prefersDark = !window.matchMedia("(prefers-color-scheme: light)").matches;
    } catch (e) {}
    var themeChoice = opts.theme || "auto";
    var theme = themeChoice === "auto" ? (prefersDark ? "dark" : "light") : themeChoice;

    var reduceMQ = safeMQ("(prefers-reduced-motion: reduce)");
    var forcedMQ = safeMQ("(forced-colors: active)");
    var reduced = opts.reducedMotion != null ? !!opts.reducedMotion : !!(reduceMQ && reduceMQ.matches);
    var forced = !!(forcedMQ && forcedMQ.matches);

    function safeMQ(q) {
      try {
        return window.matchMedia(q);
      } catch (e) {
        return null;
      }
    }

    // ── DOM scaffold ──
    var canvas = document.createElement("canvas");
    // Keyboard entry point: the canvas is focusable so Tab lands ON the graph,
    // and its focus delegates into the parallel a11y tree (role=tree) so arrow
    // keys traverse nodes. Without this, the clipped tree had no real entry.
    canvas.setAttribute("tabindex", "0");
    canvas.setAttribute("role", "application");
    canvas.setAttribute("aria-label", "Document blast-radius graph. Press Tab to enter, arrow keys to traverse.");
    canvas.style.cssText =
      "display:block;width:100%;height:100%;position:absolute;inset:0;touch-action:none;outline:none;";
    var ctx;
    try {
      ctx = canvas.getContext("2d");
    } catch (e) {
      ctx = null;
    }
    if (!ctx) {
      containerEl.textContent = "graph unavailable";
      return { update: function () {}, destroy: function () {}, fit: function () {} };
    }

    var prevPos = getComputedStyle(containerEl).position;
    if (prevPos === "static" || !prevPos) containerEl.style.position = "relative";
    containerEl.appendChild(canvas);

    // Chrome overlay layer (DOM, never canvas-drawn).
    var overlay = document.createElement("div");
    overlay.style.cssText =
      "position:absolute;inset:0;pointer-events:none;font-family:" +
      FONT_STACK +
      ";z-index:10;";
    containerEl.appendChild(overlay);

    // a11y tree (parallel invisible DOM).
    var a11yRoot = document.createElement("div");
    a11yRoot.setAttribute("role", "tree");
    a11yRoot.setAttribute("aria-label", "Document graph");
    a11yRoot.style.cssText =
      "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;";
    containerEl.appendChild(a11yRoot);

    var liveRegion = document.createElement("div");
    liveRegion.setAttribute("aria-live", "polite");
    liveRegion.style.cssText = a11yRoot.style.cssText;
    containerEl.appendChild(liveRegion);

    // DOM tooltip (anchored to node, flip-and-clamp).
    var tooltip = document.createElement("div");
    tooltip.style.cssText =
      "position:absolute;pointer-events:none;z-index:20;opacity:0;transition:opacity .12s;" +
      "max-width:240px;padding:8px 11px;border-radius:8px;font-family:" +
      FONT_STACK +
      ";font-size:12px;line-height:1.4;";
    containerEl.appendChild(tooltip);

    // ── camera + view ──
    var dpr = Math.min(window.devicePixelRatio || 1, 3);
    var W = 0,
      H = 0; // CSS px
    var cam = { tx: 0, ty: 0, scale: 1 };

    // ── state ──
    var nodes = [],
      edges = [];
    var byId = {};
    var adj = {}; // id -> Set neighbor ids
    var adjEdges = {}; // id -> Set edge objs
    var depthMap = {}; // id -> BFS depth from root
    var rootId = null;
    var dataRev = 0;
    var nodeSetHash = "";

    var hoverId = null;
    var focusIdx = -1; // keyboard focus index into a11y order
    var a11yOrder = [];

    var glowTier = 0; // 0..3 (T0 best)
    var frameTimes = [];
    var lastFrame = 0;
    // Idle "breathing" — OFF by default for Obsidian-grade calm. When enabled,
    // a settled graph keeps the loop awake at BREATH_FPS and draw() applies a
    // tiny render-only sway. Default: a settled, un-hovered graph holds perfectly
    // still and the rAF loop fully parks (re-woken on any interaction). Flip
    // IDLE_BREATH to bring back the old gentle drift.
    var IDLE_BREATH = false;
    var BREATH_FPS = 12;
    var lastBreathDraw = 0;
    var demoteRun = 0,
      promoteRun = 0;

    var alpha = 1.0;
    var alphaTarget = 1.0;
    var alphaDecay = 0.008;
    var velocityDecay = 0.55;
    var alphaMin = 0.001;

    var R_RING = 0; // recomputed on layout = 0.22*min(W,H)
    var flowOn = !!opts.flow;
    // Monochrome is the DEFAULT — the elegant near-monochrome Obsidian look is
    // the resting state, so the first impression is the calm desaturated one.
    // Per-type "Full color" is the opt-in toggle, flipped from the legend.
    var fullColor = opts.fullColor != null ? !!opts.fullColor : false;
    var nowT = 0;

    // ── eased camera scale (luxe wheel/button zoom) ──
    var camTargetScale = 1; // scale glides toward this; cursor world-point pinned
    var camZoomAnchor = null; // {wx, wy, px, py} kept fixed during the glide
    var camAnimating = false; // animateCam (fit) in flight

    // Auto-fit ("default/wide") zoom baseline — captured every time fitInternal
    // computes its target scale. Labels are gated RELATIVE to this: at/near
    // fitScale the view is clean (no labels); the ramp fades them in only once
    // the user has zoomed IN past it. null until the first fit runs, in which
    // case label code falls back to the live cam.scale as the baseline.
    var fitScale = null;

    // One-shot auto-fit: the sim settles as a small centroid clump, so frame it
    // ONCE when alpha first cools below the settle threshold. Never again (so a
    // user's pan/zoom isn't yanked). Suppressed when a saved view was restored
    // or the user has already interacted with the camera.
    var _autoFitDone = true; // armed (set false) only on a fresh, unsaved load
    var _userMovedCam = false; // any manual pan/zoom disqualifies the auto-fit

    // ── hover corona spring (fast-in / slow-out asymmetry) ──
    var hoverCoronaK = 0; // 0..1 corona intensity, springs per the luxe tell

    // ── selection-ring pulse (snappy click trigger) ──
    var selectId = null;
    var selectPulse = 0; // 1 -> 0, drives a brief ring pop on click

    var rafId = null;
    var running = false;
    var destroyed = false;

    // pan inertia
    var panVX = 0,
      panVY = 0;
    var lastMoves = [];
    var dragging = false;
    var spaceDown = false;
    var pointerStart = null;

    // node drag
    var dragNode = null;

    // entrance choreography
    var mountTime = perfNow();
    var sparseMode = false;

    // morph (nav recenter-then-morph)
    var morph = null;

    function perfNow() {
      return (window.performance && performance.now()) || Date.now();
    }

    // ── view-state persistence ──
    function storageKey() {
      return "bpgraph:" + (rootId || "anon");
    }
    function camFinite(c) {
      return (
        c &&
        isFinite(c.tx) && isFinite(c.ty) && isFinite(c.scale) &&
        Math.abs(c.tx) < 1e7 && Math.abs(c.ty) < 1e7 &&
        c.scale > 0 && c.scale < 100
      );
    }
    function saveView() {
      try {
        // Never persist a diverged camera (a runaway sim could write ~1e44 here,
        // which would then be restored every load and paint the graph off-canvas).
        if (!camFinite(cam)) return;
        localStorage.setItem(
          storageKey(),
          JSON.stringify({
            cam: cam,
            theme: themeChoice === "auto" ? null : theme,
            full: fullColor,
            flow: flowOn,
            hash: nodeSetHash
          })
        );
      } catch (e) {}
    }
    var saveViewTimer = null;
    function scheduleSaveView() {
      // Coalesce per-wheel-tick persistence. saveView() does a synchronous
      // JSON.stringify + localStorage.setItem; calling it on EVERY wheel event
      // (dozens fire per scroll gesture, each a blocking main-thread disk write)
      // stutters the zoom. Debounce to one write ~250ms after the gesture rests.
      if (saveViewTimer) clearTimeout(saveViewTimer);
      saveViewTimer = setTimeout(function () {
        saveViewTimer = null;
        saveView();
      }, 250);
    }
    function loadView() {
      try {
        var raw = localStorage.getItem(storageKey());
        if (!raw) return null;
        var v = JSON.parse(raw);
        // Drop a persisted diverged camera (written by a pre-fix blowup) so we
        // fall back to a fresh auto-fit instead of restoring an off-canvas view.
        if (v && v.cam && !camFinite(v.cam)) return null;
        return v;
      } catch (e) {
        return null;
      }
    }

    // ─────────────────────────────────────────────── data ingest + index ──
    function ingest(rawNodes, rawEdges, explicitRootId) {
      rawNodes = rawNodes || [];
      rawEdges = rawEdges || [];
      if (explicitRootId == null) explicitRootId = opts.rootId;
      truncCache = {}; // bounded: cleared on every data-rev (no cross-nav creep)
      _bgGrad = null; // node set changed -> root anchor moved; rebuild vignette

      // Build a published-sibling type hint map (doc_id -> type) for resolution.
      var siblingType = {};
      rawNodes.forEach(function (n) {
        if (typeof n.type === "string" && n.type !== "" && n.doc_id) {
          siblingType[n.doc_id] = n.type;
        }
      });

      var oldPos = {};
      nodes.forEach(function (n) {
        oldPos[n.id] = { x: n.x, y: n.y };
      });

      var nextNodes = [];
      var nextById = {};
      // broken_id -> phantom node, for O(1) edge-target resolution (published
      // phantoms are uniq_by(broken_id) server-side). Avoids the O(edges*nodes)
      // scan that was the only working path before.
      var phantomByBrokenId = {};

      rawNodes.forEach(function (raw) {
        var id, key;
        if (raw.phantom) {
          // Real wire: id:nil, broken_id, via_field, refType, source, title:to_id.
          var via = (raw.via_field || "").trim();
          key = (raw.broken_id || raw.title || "") + "|" + via;
          id = "phantom:" + key;
        } else {
          id = raw.id;
          key = id;
        }
        if (id == null || id === "") return;
        if (nextById[id]) return; // server pre-dedupes; belt + braces

        var rtype = raw.phantom
          ? "_unknown"
          : resolveType(raw, siblingType[raw.doc_id]);

        var node = {
          id: id,
          key: key,
          raw: raw,
          phantom: !!raw.phantom,
          type: rtype,
          title: raw.title || raw.doc_id || raw.broken_id || id,
          doc_id: raw.doc_id || null,
          broken_id: raw.broken_id || null,
          via: (raw.via_field || "").trim(),
          refType: (raw.refType || "").trim(),
          status: raw.status || (raw.label_status || null),
          degree: 0,
          // physics
          x: 0,
          y: 0,
          vx: 0,
          vy: 0,
          // animation state
          alpha: 0,
          alphaTarget: 1,
          scaleK: 0,
          scaleTarget: 1,
          depth: 1,
          depthTarget: 1,
          frosted: false,
          phaseSeed: Math.random() * Math.PI * 2,
          r: 8,
          _enterAt: 0
        };
        nextNodes.push(node);
        nextById[id] = node;
        if (node.phantom && node.broken_id != null) {
          // first-writer-wins: matches server uniq_by(broken_id) ordering
          if (!phantomByBrokenId[node.broken_id]) phantomByBrokenId[node.broken_id] = node;
        }
      });

      // Resolve root: the gravitational sun the whole layout is built around.
      // The server emits it authoritatively (graph.ex root: field) and the hook
      // threads it here. The fallback (degree-based) is deferred until AFTER
      // degree is computed below — see "root fallback" block.
      var newRootId =
        explicitRootId && nextById[explicitRootId] && !nextById[explicitRootId].phantom
          ? explicitRootId
          : null;
      var rootWasSupplied = !!explicitRootId;

      // Edges — coerce + normalize weight; key by id; drop self-NaN risk.
      var nextEdges = [];
      var pairSeen = {};
      rawEdges.forEach(function (e) {
        if (!e.from_id || !e.to_id) return;
        var src = nextById[e.from_id];
        // target may be a phantom keyed differently — resolve target id.
        var dstId = e.to_id;
        if (!nextById[dstId]) {
          // Phantom target. Published edges carry NO via on the edge while the
          // phantom node owns the via_field, so the composite key cannot match;
          // resolve by broken_id directly through the prebuilt map (O(1)). The
          // composite is tried first ONLY for the rare drafts case where the
          // edge does carry via and two phantoms share a broken_id.
          var via = (e.via_field || e.field || "").trim();
          var pk = "phantom:" + dstId + "|" + via;
          if (via && nextById[pk]) dstId = pk;
          else if (phantomByBrokenId[e.to_id]) dstId = phantomByBrokenId[e.to_id].id;
          else if (nextById[pk]) dstId = pk;
        }
        var dst = nextById[dstId];
        if (!src || !dst) return;

        var w = typeof e.weight === "number" && isFinite(e.weight) ? e.weight : 1;
        var kind = (e.kind || "") === "" ? "reference" : e.kind;
        var eid = "e:" + e.from_id + ":" + dstId + ":" + kind;

        var bidiKey = e.from_id < dstId ? e.from_id + "~" + dstId : dstId + "~" + e.from_id;
        pairSeen[bidiKey] = (pairSeen[bidiKey] || 0) + 1;

        nextEdges.push({
          id: eid,
          src: src,
          dst: dst,
          srcId: e.from_id,
          dstId: dstId,
          kind: kind,
          phantom: dst.phantom,
          selfLoop: e.from_id === dstId,
          weight: w,
          plugin_source: e.plugin_source || "",
          bidiKey: bidiKey,
          parallelIndex: pairSeen[bidiKey] - 1,
          alpha: 0,
          alphaTarget: 1,
          phaseSeed: Math.random() * 4500,
          // weight normalization (mandatory)
          wNorm: 0,
          wBand: 0
        });
      });

      // weight normalization band
      nextEdges.forEach(function (e) {
        var w = e.weight;
        var wNorm = clamp(w <= 0 ? 1 : w > 5 ? 5 * (1 + Math.log10(w / 5)) : w, 0, 8);
        e.wNorm = wNorm;
        e.wBand = clamp(wNorm / 8, 0, 1); // 0..1
      });

      // degree (undirected, non-phantom counts both ways; phantom counts toward
      // src). Self-loops are EXCLUDED — a node is not "connected to itself" for
      // sizing, BFS depth, connection-count, or aria. They still render.
      nextEdges.forEach(function (e) {
        if (e.selfLoop) return;
        e.src.degree++;
        if (!e.dst.phantom) e.dst.degree++;
      });

      // adjacency + edge sets (self-loops excluded from adjacency to keep BFS
      // and the connection-count truthful)
      var nadj = {},
        nadjE = {};
      nextNodes.forEach(function (n) {
        nadj[n.id] = {};
        nadjE[n.id] = [];
      });
      nextEdges.forEach(function (e) {
        if (e.selfLoop) {
          nadjE[e.srcId].push(e); // keep for drawing only
          return;
        }
        nadj[e.srcId][e.dstId] = true;
        nadj[e.dstId][e.srcId] = true;
        nadjE[e.srcId].push(e);
        nadjE[e.dstId].push(e);
      });

      // ── root fallback (deferred until degree exists) ──
      // If the supplied root is missing, degrade to the highest-degree real
      // node — a plausible hub, never a random array-order leaf.
      if (!newRootId) {
        if (rootWasSupplied) {
          try {
            console.warn(
              "[bp-graph] root id '" + explicitRootId +
                "' not found in graph; falling back to highest-degree node. " +
                "This usually means data-root drifted from the node set."
            );
          } catch (e) {}
        }
        var bestDeg = -1;
        for (var ri = 0; ri < nextNodes.length; ri++) {
          var rn = nextNodes[ri];
          if (rn.phantom) continue;
          if (rn.degree > bestDeg) {
            bestDeg = rn.degree;
            newRootId = rn.id;
          }
        }
      }

      // BFS depth from root
      var ndepth = {};
      if (newRootId) {
        var q = [newRootId];
        ndepth[newRootId] = 0;
        while (q.length) {
          var cur = q.shift();
          var nb = nadj[cur];
          for (var nid in nb) {
            if (ndepth[nid] == null) {
              ndepth[nid] = ndepth[cur] + 1;
              q.push(nid);
            }
          }
        }
      }
      // unreached nodes -> sentinel depth = maxDepth+1
      var maxD = 0;
      for (var dk in ndepth) maxD = Math.max(maxD, ndepth[dk]);
      nextNodes.forEach(function (n) {
        if (ndepth[n.id] == null) ndepth[n.id] = maxD + 1;
      });

      // node radii: small flat dots, gentle sqrt scale with degree (4..9px).
      // Obsidian's read — a leaf is a tiny dot, a hub is only modestly bigger.
      var n = nextNodes.length;
      var degs = nextNodes.filter(function (x) { return !x.phantom; }).map(function (x) { return x.degree; });
      var dMax = degs.length ? Math.max.apply(null, degs) : 0;
      function radiusForDegree(deg) {
        // sqrt ramp from NODE_R_MIN (deg 0) toward NODE_R_MAX, normalized by the
        // graph's own max degree so the range is used regardless of scale.
        if (dMax <= 0) return NODE_R_MIN + 1;
        var t = Math.sqrt(deg) / Math.sqrt(dMax); // 0..1
        return NODE_R_MIN + (NODE_R_MAX - NODE_R_MIN) * clamp(t, 0, 1);
      }
      nextNodes.forEach(function (node) {
        if (node.phantom) {
          node.r = NODE_R_MIN; // phantom: a dim hollow dot, smallest tier
        } else if (node.id === newRootId) {
          node.r = 0; // set just below
        } else {
          node.r = radiusForDegree(node.degree);
        }
      });
      // root is only SLIGHTLY larger — ~+1px over a normal dot, never a sun.
      // Obsidian's open-note highlight is understated: accent fill + a hair
      // bigger, not a dominant ball.
      var rootNode = nextById[newRootId];
      if (rootNode) {
        rootNode.r = clamp(radiusForDegree(rootNode.degree) + 1, NODE_R_MIN + 1, NODE_R_MAX + 1);
      }

      // hash for view-state restore
      var hashArr = nextNodes.map(function (x) { return x.id; }).sort();
      var newHash = hashArr.join(",");

      // ── transition decision ──
      var hadData = nodes.length > 0;
      var rootChanged = rootId && newRootId && rootId !== newRootId;

      nodes = nextNodes;
      byId = nextById;
      edges = nextEdges;
      adj = nadj;
      adjEdges = nadjE;
      depthMap = ndepth;
      rootId = newRootId;
      nodeSetHash = newHash;
      sparseMode = n <= 3 && n >= 1;

      // initial positions
      var cx = W / 2,
        cy = H / 2;
      // Deterministic radial-by-BFS-depth seed: place fresh nodes at
      // depth*R_RING on their golden-angle slot so they spawn NEAR their
      // settled ring. This cheap seed lets the pre-warm be SHORT (the sim only
      // relaxes a near-correct layout) instead of untangling a centroid blob,
      // which is what made the old blocking warm-up a multi-hundred-ms freeze.
      R_RING = 0.22 * Math.min(W, H);
      var GOLDEN = Math.PI * (3 - Math.sqrt(5));
      var seedIdx = 0;
      // UNREACHED nodes (no path from the root — depthMap holds the maxD+1
      // sentinel) have no true ring. Seeding them ALL at that one sentinel
      // radius built a dense distant annulus that center-gravity collapsed
      // into the frozen "hairball" at corpus scale (n≈1800, most nodes outside
      // the root's component). Scatter them instead across an area-uniform
      // phyllotaxis disc sized near the sim's gravity/repulsion equilibrium
      // (r³ ≈ repel·n/gravity), which is already close to its settled spread —
      // the short synchronous settle then RELAXES it instead of failing to
      // untangle it. Reached nodes keep the proven radial-by-depth seed.
      var unreachedCount = 0;
      nodes.forEach(function (node) {
        if (!(oldPos[node.id] && hadData) && depthMap[node.id] > maxD) unreachedCount++;
      });
      var discR = Math.cbrt((800 * Math.max(nodes.length, 8)) / 0.009);
      var discIdx = 0;
      nodes.forEach(function (node) {
        var op = oldPos[node.id];
        if (op && hadData) {
          node.x = op.x;
          node.y = op.y;
          node._enterAt = 0; // PERSIST never replays entrance
          node.alpha = 1;
          node.scaleK = 1;
        } else {
          var ang, rad;
          if (depthMap[node.id] > maxD && unreachedCount > 0) {
            ang = discIdx * GOLDEN;
            rad = discR * Math.sqrt((discIdx + 0.5) / unreachedCount) + (Math.random() - 0.5) * 16;
            discIdx++;
          } else {
            var depth = Math.max(1, depthMap[node.id] || 1);
            ang = seedIdx * GOLDEN;
            seedIdx++;
            rad = depth * R_RING + (Math.random() - 0.5) * 20;
          }
          node.x = cx + rad * Math.cos(ang);
          node.y = cy + rad * Math.sin(ang);
          node.alpha = 0;
          node.scaleK = 1; // appear at full size — no scale pop (Obsidian-quiet)
          // Very subtle entrance: a short UNIFORM opacity fade, no per-ring stagger
          // ripple and no easeOutBack scale overshoot. Nodes simply fade in at rest
          // size while the sim gently relaxes the seeded layout.
          node._enterAt = perfNow();
        }
      });

      buildA11yTree();
      recomputeTopDegree(); // at-rest label allow-set (root + top-4 by degree)

      if (sparseMode) {
        layoutSparse();
      } else if (reduced || !hadData) {
        // Reduced-motion OR FIRST LOAD: settle the layout SYNCHRONOUSLY so the
        // graph appears already in place — no live "entrance" drift while the sim
        // relaxes. The whole settle happens off-screen before first paint, so
        // nodes never slide into position (Obsidian-quiet).
        settleSync();
      } else {
        // In-session re-ingest (navigation): a brief, gentle live settle. Node
        // positions are morph-eased from the prior layout by startMorph, so this
        // stays soft rather than a swarm from full energy.
        var warm = clamp(Math.round(2000 / Math.max(1, n)), 6, 60);
        for (var w2 = 0; w2 < warm; w2++) tick(16.67, true);
        alpha = 0.3;
        alphaTarget = 0.03;
        applyAngularFan();
      }

      // view restore
      if (!hadData) {
        var saved = loadView();
        if (saved && saved.hash === newHash && saved.cam) {
          cam = saved.cam;
          camTargetScale = cam.scale;
          camZoomAnchor = null;
          _autoFitDone = true; // a restored view is authoritative — don't refit
          // honor an explicit saved choice in BOTH directions (the default is
          // now monochrome, so a saved `true` must still restore to full-color)
          if (saved.full != null) fullColor = !!saved.full;
          if (saved.flow != null) flowOn = saved.flow;
        } else {
          // The layout is already fully settled (settleSync / layoutSparse ran
          // synchronously above), so frame it ONCE, instantly, and mark auto-fit
          // done — no eased post-settle reframe (that camera zoom was itself an
          // entrance animation). First paint shows the final, static graph.
          fitInternal(false);
          _autoFitDone = true;
          _userMovedCam = false;
        }
      }
      buildChrome();
      // A re-ingest rebuilds the node objects, clearing their searchDim flags —
      // re-stamp the active external match so a data update never drops the
      // finder-driven dimming.
      applyExternalMatch();
    }

    // ── sparse deterministic layout (n<=3) ──
    function layoutSparse() {
      var n = nodes.length;
      var cx = W / 2,
        cy = H / 2;
      var real = nodes.filter(function (x) { return !x.phantom; });
      real.forEach(function (node) {
        node.alpha = 1;
        node.scaleK = 1;
        node._enterAt = 0;
      });
      // Pin the ROOT dead-center and orbit dependents around it so the
      // gravitational-sun thesis (and the root-anchored vignette) holds on the
      // smallest, most-scrutinized graphs. Falls back to the old array-order
      // placement only when no root is present among the ≤3.
      var rootN = rootId
        ? real.filter(function (x) { return x.id === rootId; })[0]
        : null;
      if (n === 1) {
        real[0].x = cx;
        real[0].y = cy;
      } else if (rootN) {
        rootN.x = cx;
        rootN.y = cy;
        var deps = real.filter(function (x) { return x.id !== rootId; });
        var Rdep = 0.3 * Math.min(W, H);
        if (deps.length === 1) {
          // single dependent on a pleasing off-axis angle (not flat-horizontal)
          var ang0 = -Math.PI / 2.6;
          deps[0].x = cx + Rdep * Math.cos(ang0);
          deps[0].y = cy + Rdep * Math.sin(ang0);
        } else {
          deps.forEach(function (d, i) {
            var a = -Math.PI / 2 + ((i + 0.5) / deps.length) * Math.PI * 1.1 - Math.PI * 0.05;
            d.x = cx + Rdep * Math.cos(a);
            d.y = cy + Rdep * Math.sin(a);
          });
        }
      } else if (real.length === 2) {
        var gap = 0.56 * Math.min(W, H);
        real[0].x = cx - gap / 2;
        real[0].y = cy;
        real[1].x = cx + gap / 2;
        real[1].y = cy;
      } else {
        var cr = 0.3 * Math.min(W, H);
        real.forEach(function (node, i) {
          var ang = -Math.PI / 2 + (i * 2 * Math.PI) / real.length;
          node.x = cx + cr * Math.cos(ang);
          node.y = cy + cr * Math.sin(ang);
        });
      }
      // phantoms ride near their source
      nodes.filter(function (x) { return x.phantom; }).forEach(function (p) {
        p.x = cx + (Math.random() - 0.5) * 60;
        p.y = cy + 80 + (Math.random() - 0.5) * 30;
        p.alpha = 1;
        p.scaleK = 1;
      });
      edges.forEach(function (e) {
        e.alpha = 1;
      });
    }

    // ── synchronous settle (first load + reduced-motion) ──
    // ADAPTIVE budget. The old fixed 40ms wall exited after ~1 tick of the
    // O(n^2) repulsion at n≈1800 and then hard-zeroed alpha — the "hairball"
    // was a FROZEN, unrelaxed layout wearing a settled graph's stillness. The
    // budget now scales with node count (capped so mount never janks), alpha
    // genuinely cools toward rest (so small graphs exit early on REAL
    // convergence, not just the clock), and the banding pass is time-guarded
    // (40 unguarded ticks at corpus scale was itself a multi-hundred-ms stall).
    function settleSync() {
      var start = perfNow();
      var iters = 0;
      var n = nodes.length || 1;
      var budget = clamp(60 + n * 0.13, 60, 250); // ms — ~250 at corpus scale
      alpha = 1.0;
      alphaTarget = 0;
      R_RING = 0.22 * Math.min(W, H);
      while (alpha > alphaMin && perfNow() - start < budget && iters < 600) {
        tick(16.67, true);
        iters++;
      }
      applyAngularFan();
      // apply blast-ring banding firmly (time-guarded)
      var bandStart = perfNow();
      for (var b = 0; b < 40 && perfNow() - bandStart < 90; b++) {
        tick(16.67, true);
        iters++;
      }
      nodes.forEach(function (nd) {
        nd.alpha = nd.phantom ? 1 : 1;
        nd.scaleK = 1;
        nd._enterAt = 0;
      });
      edges.forEach(function (e) {
        e.alpha = 1;
      });
      // Instrumented settle line (debug level — silent in default consoles).
      // This is the convergence truth a harness can assert on: iterations
      // actually run + the alpha the sim reached before the freeze.
      try {
        console.debug(
          "[bp-graph] settleSync n=" + n + " iters=" + iters +
            " alpha=" + alpha.toFixed(4) + " ms=" + Math.round(perfNow() - start)
        );
      } catch (e) {}
      alpha = 0;
      alphaTarget = 0;
    }

    // ── root-incident angular fan (anti-hairball) ──
    function applyAngularFan() {
      if (!rootId || sparseMode) return;
      var root = byId[rootId];
      if (!root) return;
      // first-ring neighbors of root
      var firstRing = [];
      for (var nid in adj[rootId]) {
        var nd = byId[nid];
        if (nd && !nd.phantom) firstRing.push(nd);
      }
      if (firstRing.length < 6) return;
      firstRing.sort(function (a, b) {
        return Math.atan2(a.y - root.y, a.x - root.x) - Math.atan2(b.y - root.y, b.x - root.x);
      });
      var count = firstRing.length;
      var ringR = R_RING;
      firstRing.forEach(function (nd, i) {
        var ang = (i / count) * Math.PI * 2 - Math.PI / 2;
        // even tangential nudge toward fanned angle, gentle
        var tx = root.x + ringR * Math.cos(ang);
        var ty = root.y + ringR * Math.sin(ang);
        nd.x += (tx - nd.x) * 0.25;
        nd.y += (ty - nd.y) * 0.25;
      });
    }

    // ════════════════════════════════════════════════════════════ PHYSICS ══
    function tick(dt, warming) {
      // (1) alpha cooling
      alpha += (alphaTarget - alpha) * alphaDecay;
      if (alpha < alphaMin && alphaTarget <= alphaMin) alpha = 0;

      var n = nodes.length;
      var root = rootId ? byId[rootId] : null;
      // Airier field: a touch more repulsion so the smaller dots still sit in
      // generous dark space (Obsidian's whole-graph breathing room).
      var repel = n < 12 ? -1050 : -780;

      // (2) link springs
      for (var i = 0; i < edges.length; i++) {
        var e = edges[i];
        if (e.selfLoop) continue;
        var a = e.src,
          b = e.dst;
        var dx = b.x - a.x,
          dy = b.y - a.y;
        var dist = Math.sqrt(dx * dx + dy * dy) || 0.0001;
        var rest = 240 * (0.7 + 0.3 * e.wBand);
        var k = 0.6 * alpha;
        var force = ((dist - rest) / dist) * k * 0.5;
        var fx = dx * force,
          fy = dy * force;
        a.vx += fx;
        a.vy += fy;
        b.vx -= fx;
        b.vy -= fy;
      }

      // (3) many-body repulsion (naive O(n^2); brief allows Barnes-Hut >150 —
      // we cap repulsion work but keep naive for correctness/feasibility)
      for (var p = 0; p < n; p++) {
        var np = nodes[p];
        for (var q = p + 1; q < n; q++) {
          var nq = nodes[q];
          var ddx = np.x - nq.x,
            ddy = np.y - nq.y;
          var l2 = ddx * ddx + ddy * ddy;
          var dmin = (np.r + nq.r);
          if (l2 < dmin * dmin) l2 = dmin * dmin;
          if (l2 < 1) l2 = 1;
          var f = (repel * alpha) / l2;
          var l = Math.sqrt(l2);
          var ux = ddx / l,
            uy = ddy / l;
          np.vx -= ux * f;
          np.vy -= uy * f;
          nq.vx += ux * f;
          nq.vy += uy * f;
        }
      }

      // (4) HARD collision (only for smaller graphs — it is a second O(n^2) loop;
      // above ~150 nodes the stronger repulsion already keeps nodes apart, so we
      // drop it to halve the per-tick physics bill). The push is near-rigid (0.85)
      // with a small padding gap so dots NEVER overlap — the airy Obsidian look
      // demands clear separation even on small-degree leaves. Runs down to a very
      // low alpha so the settled layout stays overlap-free, not just the warm one.
      if (alpha > 0.005 && n <= 150) {
        for (var c = 0; c < n; c++) {
          var nc = nodes[c];
          for (var d = c + 1; d < n; d++) {
            var nd = nodes[d];
            var cdx = nc.x - nd.x,
              cdy = nc.y - nd.y;
            var cl = Math.sqrt(cdx * cdx + cdy * cdy) || 0.0001;
            var minD = nc.r + nd.r + 5; // hard radius + small padding gap
            if (cl < minD) {
              var push = ((minD - cl) / cl) * 0.85;
              nc.vx += cdx * push;
              nc.vy += cdy * push;
              nd.vx -= cdx * push;
              nd.vy -= cdy * push;
            }
          }
        }
      }

      // (5) center gravity (alpha-independent)
      var cx = W / 2,
        cy = H / 2;
      for (var g = 0; g < n; g++) {
        var ng = nodes[g];
        ng.vx += (cx - ng.x) * 0.009;
        ng.vy += (cy - ng.y) * 0.009;
      }

      // (6) gentle depth bias — a WEAK pull keeping deeper nodes a little
      // farther from the root so the cluster has organic radial order WITHOUT
      // the old hard concentric blast-rings. Far weaker (0.008) and it decays
      // with alpha, so the layout reads as an Obsidian organic clump, not bands.
      if (!sparseMode && root && R_RING > 0 && alpha >= 0.05) {
        for (var rr = 0; rr < n; rr++) {
          var nr = nodes[rr];
          if (nr.id === rootId) continue;
          var rdx = nr.x - root.x,
            rdy = nr.y - root.y;
          var rlen = Math.sqrt(rdx * rdx + rdy * rdy) || 0.0001;
          var depth = depthMap[nr.id] || 1;
          var target = depth * R_RING;
          var fr = -0.008 * (rlen - target) * alpha;
          nr.vx += (rdx / rlen) * fr;
          nr.vy += (rdy / rlen) * fr;
        }
      }

      // (7) integrate (velocity FIRST then position — semi-implicit)
      for (var z = 0; z < n; z++) {
        var nz = nodes[z];
        if (nz.id === rootId) {
          // root pinned dead-center
          nz.x = cx;
          nz.y = cy;
          nz.vx = 0;
          nz.vy = 0;
          continue;
        }
        if (nz === dragNode) {
          nz.vx = 0;
          nz.vy = 0;
          continue;
        }
        nz.vx *= 1 - velocityDecay;
        nz.vy *= 1 - velocityDecay;
        // Stability guard. A near-zero inter-node distance can spike the 1/dist
        // repulsion and blow this velocity-Verlet step up to ~1e45 — then
        // fitInternal frames empty space, the canvas reads blank, AND the
        // diverged camera gets persisted to localStorage (so it stays blank on
        // reload). Cap per-step speed; sanitize any non-finite / runaway
        // position back near centre with a deterministic per-node spread so the
        // next frame has a non-zero distance and can't re-diverge.
        var MAXV = 120;
        if (nz.vx > MAXV) nz.vx = MAXV;
        else if (nz.vx < -MAXV) nz.vx = -MAXV;
        if (nz.vy > MAXV) nz.vy = MAXV;
        else if (nz.vy < -MAXV) nz.vy = -MAXV;
        nz.x += nz.vx;
        nz.y += nz.vy;
        if (
          !isFinite(nz.x) || !isFinite(nz.y) ||
          nz.x < -1e5 || nz.x > 1e5 || nz.y < -1e5 || nz.y > 1e5
        ) {
          var spread = 40 + ((nz.id ? nz.id.length * 17 + nz.id.charCodeAt(0) : 0) % 240);
          nz.x = cx + (z % 2 ? spread : -spread);
          nz.y = cy + ((z % 4) < 2 ? spread : -spread);
          nz.vx = 0;
          nz.vy = 0;
        }
      }
    }

    // ════════════════════════════════════════════════════════════════ DRAW ══

    // FLAT background — Obsidian's calm dark (or near-white in light mode). No
    // gradient, no vignette, no root-anchored cast. Just the theme floor so the
    // dots and threads read against generous empty space. `_bgGrad` is retained
    // as a no-op cache slot only because ingest()/resize() clear it; the value
    // returned is a plain CSS color string.
    var _bgGrad = null;
    function bgGradient() {
      return theme === "light" ? BG_LIGHT : BG_DARK;
    }

    function worldToScreen(x, y) {
      return [x * cam.scale + cam.tx, y * cam.scale + cam.ty];
    }

    // Obsidian focus behavior with a BFS HOP CASCADE. Hovering a node lights its
    // OWN links to 100%, then steps down to 25% for the neighbours' onward links
    // and halves from there: 12.5%, 6.25%, … floored to the resting thread
    // (LINK_A_DIM). An edge's ring = the hop-distance of its NEARER endpoint from
    // the hovered node (so links touching the hover = ring 0 = full).
    // Nodes lag the links by one ring — hovered + 1-hop stay full, then halve — so
    // a link is never brighter than the nodes it joins AND the touched nodes stay
    // visible enough to read. Distances are BFS-cached per hovered node; only the
    // cheap per-frame target-set runs each frame, the BFS only on hover change.
    var hoverDist = {}; // id -> hops from the hovered node (undefined = unreachable)
    var _hoverDistFor = null;
    function recomputeHoverDist() {
      hoverDist = {};
      _hoverDistFor = hoverId;
      if (hoverId == null) return;
      hoverDist[hoverId] = 0;
      var q = [hoverId],
        head = 0;
      while (head < q.length) {
        var cur = q[head++];
        var d = hoverDist[cur] + 1;
        var nb = adj[cur];
        if (!nb) continue;
        for (var k in nb) {
          if (hoverDist[k] === undefined) {
            hoverDist[k] = d;
            q.push(k);
          }
        }
      }
    }
    // Nodes: hovered (0) + 1-hop (1) full, then halve per ring, floored. Lagging
    // the links by one ring keeps the cascade reading on the LINES while the nodes
    // it reaches stay legible.
    function nodeHoverAlpha(d) {
      if (d === 0 || d === 1) return 1;
      if (d === undefined) return HOVER_DIM_ALPHA;
      return Math.max(HOVER_DIM_ALPHA, Math.pow(0.5, d - 1));
    }
    // Links: ring 0 (the hovered node's OWN lines) = 100%, then a step DOWN to
    // 25% at ring 1 and halving outward — 12.5%, 6.25%, … So relationship 2
    // (the neighbours' onward links) starts at 25%, not 50%. Floored to the
    // resting thread (LINK_A_DIM).
    function edgeHoverAlpha(ring) {
      if (ring === undefined) return LINK_A_DIM;
      if (ring === 0) return 1;
      return Math.max(LINK_A_DIM, Math.pow(0.5, ring + 1));
    }
    function computeAlphaTargets() {
      var matchOn = externalMatch != null;
      if (hoverId == null) {
        if (_hoverDistFor !== null) recomputeHoverDist();
        var ba = linkBaseAlpha();
        nodes.forEach(function (n) {
          n.alphaTarget = 1;
          n.frosted = false;
          // No focus: depth keys off the search instead — weak/unmatched results
          // recede, the strongest hits sit forward. No search → all flat (1).
          n.depthTarget = !matchOn
            ? 1
            : n.searchDim
            ? DEPTH_FAR
            : DEPTH_FAR + (1 - DEPTH_FAR) * (n.matchW || 0);
        });
        edges.forEach(function (e) {
          e.alphaTarget = ba;
        });
        return;
      }
      if (_hoverDistFor !== hoverId) recomputeHoverDist();
      var focusNode = focusIdx >= 0 && a11yOrder[focusIdx] ? a11yOrder[focusIdx] : null;
      nodes.forEach(function (n) {
        if (focusNode && n.id === focusNode.id) {
          // keyboard focus has parity with hover: always lit, never frosted
          n.alphaTarget = 1;
          n.frosted = false;
          n.depthTarget = 1;
          return;
        }
        var d = hoverDist[n.id];
        n.alphaTarget = nodeHoverAlpha(d);
        n.frosted = !(d === 0 || d === 1); // hovered + 1-hop crisp; ring 2+ frosted
        // Depth tracks the SAME hop distance as the opacity cascade — so size and
        // dimming recede together, and a hover from the list reads identically to
        // a hover on the canvas (both set hoverId → same hoverDist).
        n.depthTarget = depthForDist(d);
      });
      edges.forEach(function (e) {
        var ds = hoverDist[e.srcId];
        var dd = hoverDist[e.dstId];
        var ring = ds === undefined ? dd : dd === undefined ? ds : Math.min(ds, dd);
        e.alphaTarget = edgeHoverAlpha(ring);
      });
    }

    // _lerpDirty: count of channels still settling. lerpAlphas maintains it so
    // the keep-alive check (isFocusLerping) is O(1) instead of O(n+e) — exactly
    // when we most want to be cheap (deciding whether to park).
    var _lerpDirty = 0;
    function lerpAlphas(dt) {
      // ~150ms smooth opacity ramp both ways (the Obsidian focus crossfade).
      var kin = kStep(0.22, dt);
      var kout = kStep(0.18, dt);
      var dirty = 0;
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var k = n.alphaTarget > n.alpha ? kin : kout;
        n.alpha += (n.alphaTarget - n.alpha) * k;
        n.scaleK += (n.scaleTarget - n.scaleK) * kin;
        // Depth eases on the same crossfade as opacity so the recede is smooth
        // (no per-ring snapping) and stays locked to the focus transition.
        n.depth += (n.depthTarget - n.depth) * (n.depthTarget > n.depth ? kin : kout);
        if (Math.abs(n.alpha - n.alphaTarget) > 0.01) dirty++;
        if (Math.abs(n.depth - n.depthTarget) > 0.01) dirty++;
      }
      for (var j = 0; j < edges.length; j++) {
        var e = edges[j];
        var bound = Math.min(e.src.alpha, e.dst.alpha);
        var tgt = Math.min(e.alphaTarget, bound);
        var ek = tgt > e.alpha ? kin : kout;
        e.alpha += (tgt - e.alpha) * ek;
        if (Math.abs(e.alpha - tgt) > 0.01) dirty++;
      }
      _lerpDirty = dirty;
    }

    // Very subtle entrance: a SINGLE short opacity fade, no scale channel. Scale
    // is fixed at 1 (nodes never pop in), so the only motion is a gentle fade to
    // full opacity. Set ENTER_MS to 0 for an instant (no-animation) appearance.
    var ENTER_MS = 0;
    function entranceProgress(node, now) {
      if (node._enterAt === 0 || ENTER_MS <= 0) return { scale: 1, alpha: 1, done: true };
      var ta = (now - node._enterAt) / ENTER_MS;
      var alphaP = ta < 0 ? 0 : ta >= 1 ? 1 : ta;
      var done = alphaP >= 1;
      if (done) node._enterAt = 0;
      return { scale: 1, alpha: alphaP, done: done };
    }

    function draw(now) {
      var t = now;
      nowT = now;

      // full-canvas clear in device space (plain transform so the bg always
      // covers — the breath sway below must not leave an uncovered sliver).
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.fillStyle = bgGradient();
      ctx.fillRect(0, 0, W, H);

      // Idle "breathing": a tiny render-only sway (~2px Lissajous over ~15-20s)
      // so a settled graph feels alive without moving any node (positions and
      // hit-testing are untouched — this is purely the draw transform). Disabled
      // under reduced-motion. The throttle in frame() keeps the cost ~1/5 of a
      // 60fps redraw, so this never reintroduces the perpetual-burn Windows cost.
      var _bx = 0,
        _by = 0;
      if (IDLE_BREATH && !reduced) {
        _bx = 2.2 * Math.sin(now / 2600);
        _by = 1.6 * Math.cos(now / 3300);
      }
      ctx.setTransform(dpr, 0, 0, dpr, dpr * _bx, dpr * _by);

      // ── authored empty / error states share this bed ──
      if (errorState) {
        drawCenterMessage(AMBER, 0.8, "Couldn't load graph data");
        return;
      }
      if (nodes.length === 0) {
        if (fetching) {
          drawFetchRing(t);
        } else {
          drawCenterMessage(SLATE, 0.65, "No connections yet");
        }
        return;
      }

      // morph progress (nav)
      if (morph) {
        stepMorph(now);
      }

      // entrance ramp — a subtle opacity-only fade (scale stays 1, no pop)
      nodes.forEach(function (n) {
        if (n._enterAt) {
          var ep = entranceProgress(n, now);
          n.scaleK = 1;
          n.alpha = easeOutCubic(ep.alpha);
        }
      });

      // ── edges (grouped, dimmed under lit) ──
      drawEdges(now);

      // ── nodes: dimmed (frosted) first, then lit ──
      // Classify by INTENT (n.frosted, set once in computeAlphaTargets), NOT by
      // transient lerped alpha. Crossing 0.45 mid-lerp would flicker the
      // core/glyph pass-set on every hover; the flag keeps the pass-set stable
      // for the whole hover while only OPACITY eases. Indexed loops, no closures.
      for (var di = 0; di < nodes.length; di++) {
        if (nodes[di].frosted) drawNode(nodes[di], now, true);
      }
      for (var li = 0; li < nodes.length; li++) {
        if (!nodes[li].frosted) drawNode(nodes[li], now, false);
      }

      // ── labels (screen-space) ──
      drawLabels(now);

      // a11y focus ring
      if (focusIdx >= 0 && a11yOrder[focusIdx]) {
        drawFocusRing(a11yOrder[focusIdx]);
      }

      updateTooltip();
    }

    function drawFetchRing(t) {
      var cx = W / 2,
        cy = H / 2;
      // 3.5s sine breathing (period = 2π/0.0028 ≈ 3.5s): alpha 0.30->0.55,
      // scale 0.96->1.04. Under reduced-motion this is a SINGLE STATIC frame
      // (mid-rest alpha 0.45, scale 1.0) — a perpetual non-essential animation
      // would violate the motion-preference guarantee (WCAG 2.3.3).
      var s = reduced ? 0.5 : (Math.sin(t * 0.0028) + 1) / 2;
      var a = 0.30 + 0.25 * s;
      var scale = 0.96 + 0.08 * s;
      var r = 0.22 * Math.min(W, H) * scale;
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      ctx.strokeStyle = rgba(ACCENT, a);
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    function drawCenterMessage(color, a, text) {
      var cx = W / 2,
        cy = H / 2;
      var t = clamp((perfNow() - mountTime) / 400, 0, 1);
      var ease = easeOutCubic(t);
      ctx.save();
      ctx.globalAlpha = a * ease;
      // glass plate
      ctx.font = "500 14px " + FONT_STACK;
      var tw = ctx.measureText(text).width;
      var pad = 18;
      var bw = tw + pad * 2,
        bh = 44;
      var bx = cx - bw / 2,
        by = cy - bh / 2 + (1 - ease) * 12;
      roundRect(ctx, bx, by, bw, bh, 10);
      ctx.fillStyle = theme === "light" ? "rgba(255,255,255,0.6)" : "rgba(19,20,27,0.55)";
      ctx.fill();
      ctx.strokeStyle = "rgba(255,255,255,0.07)";
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = color;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(text, cx, by + bh / 2);
      ctx.restore();
    }

    // ── EDGES ──
    function drawEdges(now) {
      for (var i = 0; i < edges.length; i++) {
        var e = edges[i];
        if (e.alpha < 0.01) continue;
        if (e.selfLoop) {
          drawSelfLoop(e);
          continue;
        }
        drawEdge(e, now);
      }
    }

    // Straight-line endpoints (screen space). No bezier control point — Obsidian
    // draws plain segments. Kept as {p0,p2} so flow's bezierAt(p0,c,p2) with
    // c==midpoint degenerates to a straight interpolation.
    function edgeGeom(e) {
      var p0 = worldToScreen(e.src.x, e.src.y);
      var p2 = worldToScreen(e.dst.x, e.dst.y);
      var c = [(p0[0] + p2[0]) / 2, (p0[1] + p2[1]) / 2];
      var dx = p2[0] - p0[0],
        dy = p2[1] - p0[1];
      return { p0: p0, p2: p2, c: c, len: Math.sqrt(dx * dx + dy * dy) || 0.0001 };
    }

    function bezierAt(p0, c, p2, t) {
      var u = 1 - t;
      return [
        u * u * p0[0] + 2 * u * t * c[0] + t * t * p2[0],
        u * u * p0[1] + 2 * u * t * c[1] + t * t * p2[1]
      ];
    }

    // Resting link color/opacity for the current theme.
    function linkRGB() {
      return theme === "light" ? LINK_RGB_LIGHT : LINK_RGB_DARK;
    }
    function linkBaseAlpha() {
      return theme === "light" ? LINK_A_LIGHT : LINK_A_DARK;
    }

    // Thin, faint, straight, no arrowhead. e.alpha carries the hover focus
    // (1 for incident links, LINK_A_DIM/base for the dimmed field). Weight
    // modulates width subtly (0.75–1.5px on-screen). Phantom links: dim dashed.
    function drawEdge(e, now) {
      var g = edgeGeom(e);
      var rgbStr = linkRGB();
      var incident = e.srcId === hoverId || e.dstId === hoverId;

      ctx.save();
      if (e.phantom) {
        ctx.setLineDash([3, 4]);
        ctx.strokeStyle = forced
          ? "GrayText"
          : "rgba(" + rgbStr + "," + clamp(e.alpha * 1.4, 0, 1) + ")";
        ctx.lineWidth = 1;
      } else {
        // e.alpha is the ABSOLUTE link alpha — the BFS hop cascade lives there
        // (ring 0 / touching the hover = 100%, then 50/25/12.5/… per ring out),
        // floored to the resting thread. No base-multiply, no incident override.
        var ea = e.alpha;
        // Under a finder filter (and not hovering, which owns its own cascade),
        // lift threads BETWEEN two matches so the result set reads as a connected
        // constellation, and recede threads that touch a dimmed non-match.
        if (externalMatch != null && hoverId == null) {
          var sm = e.src && e.src.matchW > 0,
            dm = e.dst && e.dst.matchW > 0;
          if (sm && dm) ea = Math.max(ea, 0.16 + 0.22 * Math.min(e.src.matchW, e.dst.matchW));
          else ea = ea * 0.22;
        }
        ctx.strokeStyle = forced ? "GrayText" : "rgba(" + rgbStr + "," + clamp(ea, 0, 1) + ")";
        // width: 0.75 → 1.5px on weight, brighten incident links a touch wider.
        var lw = 0.75 + 0.75 * e.wBand;
        if (incident && hoverId != null) lw += 0.4;
        ctx.lineWidth = lw;
      }
      ctx.beginPath();
      ctx.moveTo(g.p0[0], g.p0[1]);
      ctx.lineTo(g.p2[0], g.p2[1]);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.restore();

      // Optional, OFF by default: a single very subtle flow dot along the link.
      if (flowOn && !e.phantom && cam.scale > 0.35 && e.alpha > 0.04 && !reduced) {
        drawFlowParticles(e, g, now, rgbStr);
      }
    }

    function drawFlowParticles(e, g, now, rgbStr) {
      // A lone, very faint dot drifting from the shallower (more-relevant) end
      // toward the leaf. Kept minimal — Obsidian's flow toggle is a whisper, not
      // a marquee. No 'lighter' bloom; just a small low-alpha dot.
      var period = 8000;
      var srcDepth = depthMap[e.srcId] == null ? 99 : depthMap[e.srcId];
      var dstDepth = depthMap[e.dstId] == null ? 99 : depthMap[e.dstId];
      var forward = srcDepth <= dstDepth;
      var raw = (((now - e.phaseSeed) % period) + period) % period / period;
      var tt = forward ? raw : 1 - raw;
      var pos = bezierAt(g.p0, g.c, g.p2, tt);
      var edgeFade = clamp(Math.sin(raw * Math.PI), 0, 1);
      ctx.save();
      ctx.fillStyle = "rgba(" + rgbStr + "," + 0.28 * e.alpha * edgeFade + ")";
      ctx.beginPath();
      ctx.arc(pos[0], pos[1], 1.2, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    function drawSelfLoop(e) {
      var a = e.src;
      var p = worldToScreen(a.x, a.y);
      var r = a.r * 0.9 * cam.scale;
      var ox = p[0] + a.r * cam.scale,
        oy = p[1] - a.r * cam.scale;
      ctx.save();
      ctx.strokeStyle = forced
        ? "GrayText"
        : "rgba(" + linkRGB() + "," + clamp(e.alpha * 1.6, 0, 1) + ")";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.arc(ox, oy, r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // ── NODE FILL ──
    // DEFAULT: near-monochrome (one muted lavender-grey for every node). The
    // root/active node wears the accent. "Full color" toggle restores per-type
    // hue. Phantoms get the slate tint (drawn hollow/dim in drawNode).
    function nodeFill(node) {
      var mono = theme === "light" ? MONO_LIGHT : MONO_DARK;
      if (node.phantom) return mono;
      if (node.id === rootId) return ACCENT;
      if (fullColor) {
        var hex = TYPE_HEX[node.type] || SLATE;
        return theme === "light" ? shiftL(hex, -0.22) : hex;
      }
      return mono;
    }

    // Small FLAT filled circle. No glow, no gradient, no ring. Anti-aliased
    // edge only. The active/root node wears the accent and is only slightly
    // larger; the hovered node + its 1-hop neighbors brighten toward white.
    // Phantom/broken nodes: a dim hollow dot. node.alpha carries the hover
    // focus dim. frosted (dimmed context) is the same dot at lower alpha — no
    // depth-of-field bloom.
    function drawNode(node, now, frosted) {
      if (node.alpha < 0.02) return;
      var p = worldToScreen(node.x, node.y);
      var matchOn = externalMatch != null;
      var mw = node.matchW || 0;
      // Effective opacity. Resolved up here because the phantom branch reads it.
      // Search dims unmatched nodes (×0.18) — but a hover/focus OVERRUNS it: while
      // any node is focused, the hovered node + its related (1-hop) network show at
      // full opacity (the hover cascade in node.alpha already lights the ego-net
      // and dims the rest), and the search-dim is suspended so the focused
      // neighborhood is never double-dimmed. No active focus → search-dim applies.
      var a = node.alpha;
      if (node.searchDim && hoverId == null) a *= 0.18;
      var r = node.r * node.scaleK * cam.scale;
      // Score-scaled emphasis: under an active finder filter, the better a
      // result's rank the larger its dot — and we lift the on-screen cap for
      // matches so the top hits can actually grow past the resting clamp.
      var screenCap = NODE_R_SCREEN_MAX;
      if (matchOn && mw > 0) {
        r *= 1 + 0.9 * mw;
        screenCap = NODE_R_SCREEN_MAX + 9 * mw;
      }
      // Cap the on-screen radius so even zoomed all the way in a node never
      // becomes a big disc — Obsidian's dots stay tiny at every zoom.
      if (r > screenCap) r = screenCap;
      // ── z-depth (FINAL multiplier): recede by focus distance. Applied after
      // importance-growth + cap, so it's a clean "push into z" independent of how
      // prominent the dot is — importance sets size, focus distance sets depth.
      // node.depth is the animated focus-distance scale (1 forward → DEPTH_FAR
      // back), driven identically by canvas hover and the list→graph bridge.
      r *= node.depth;
      if (r < 0.4) return;
      var isRoot = node.id === rootId;
      var hovered = hoverId != null && node.id === hoverId;
      var neighbor = hoverId != null && adj[hoverId] && adj[hoverId][node.id];

      // ── PHANTOM: dim hollow ring, no fill ──
      if (node.phantom) {
        ctx.save();
        ctx.globalAlpha = a * 0.7;
        ctx.strokeStyle = forced
          ? "GrayText"
          : theme === "light"
          ? rgba(MONO_LIGHT, 0.5)
          : rgba(MONO_DARK, 0.45);
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
        return;
      }

      // selection-ring pulse (kept — a calm thin accent ring on click).
      if (!frosted && selectPulse > 0 && node.id === selectId && !reduced) {
        var sp = easeOutCubic(1 - selectPulse);
        var ringR = r + (3 + 9 * sp) * cam.scale;
        ctx.save();
        ctx.globalAlpha = (1 - sp) * (1 - sp) * 0.7;
        ctx.strokeStyle = forced ? "CanvasText" : ACCENT;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(p[0], p[1], ringR, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      // resolve fill — brighten the hovered node + neighbors toward white/accent.
      var fill;
      if (forced) {
        fill = isRoot ? "Highlight" : "CanvasText";
      } else if (isRoot) {
        // active node: accent, lifting toward a lighter accent on hover.
        fill = hovered || neighbor ? shiftL(ACCENT, 0.1) : ACCENT;
      } else if (hovered) {
        // hovered node brightens toward white (dark) / dark (light).
        fill = theme === "light" ? "#2a2e3a" : NODE_WHITE;
      } else if (neighbor) {
        fill = theme === "light" ? mixHex(nodeFill(node), "#2a2e3a", 0.4) : mixHex(nodeFill(node), NODE_WHITE, 0.45);
      } else {
        fill = nodeFill(node);
      }
      // Rank-coloured matches: under a finder filter, a match takes the SAME
      // red→emerald highlight colour as its result row (top of the list = vivid
      // emerald, weakest visible = warm red), so the graph and list share one
      // ranking encoding. Mixed in by weight so the strongest hits commit fully to
      // their colour while tail hits stay a softer tint. Root keeps its own accent;
      // hovered/neighbor/forced paths are left untouched.
      if (matchOn && mw > 0 && !isRoot && !hovered && !neighbor && !forced) {
        fill = mixHex(fill, rankColor(mw), 0.45 + 0.5 * mw);
      }

      ctx.save();
      ctx.globalAlpha = a;
      ctx.fillStyle = fill;
      ctx.beginPath();
      ctx.arc(p[0], p[1], r, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();

      // ACTIVE NODE: a subtle 1px brighter accent ring — Obsidian's understated
      // open-note highlight. Not a glow, not a halo, just a thin lift.
      if (isRoot && !forced && !frosted) {
        ctx.save();
        ctx.globalAlpha = a;
        ctx.strokeStyle = shiftL(ACCENT, 0.18);
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + 0.5, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      // in_progress task badge — a single thin accent quarter-ring (kept, calm).
      if (!frosted && node.type === "task" && node.status === "in_progress" && !forced) {
        ctx.save();
        ctx.globalAlpha = a;
        ctx.strokeStyle = ACCENT;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + 2, -Math.PI / 2, 0);
        ctx.stroke();
        ctx.restore();
      }
    }

    // Top-degree allow-set for at-rest labels, recomputed only when the node
    // set changes (cheap: a single sort of the real nodes by degree). At rest
    // we label ONLY the root + these few, then collision-skip the rest, so a
    // settled constellation reads clean instead of an overlapping word-pile.
    var REST_TOP_N = 4;
    var _topDegIds = {};
    function recomputeTopDegree() {
      _topDegIds = {};
      var real = [];
      for (var i = 0; i < nodes.length; i++) {
        if (!nodes[i].phantom && nodes[i].id !== rootId) real.push(nodes[i]);
      }
      real.sort(function (a, b) { return b.degree - a.degree; });
      for (var j = 0; j < real.length && j < REST_TOP_N; j++) {
        _topDegIds[real[j].id] = true;
      }
    }

    // ── LABELS (screen-space, FIT-RELATIVE zoom-fade + degree bias + declutter) ──
    // Obsidian text-fade: labels are HIDDEN at the default/wide auto-fit view and
    // fade in (easeOutCubic) only as the user zooms IN past it. The window is
    // RELATIVE to fitScale (the captured auto-fit baseline), not absolute scale,
    // because the auto-fit scale for a spread layout can land far below any fixed
    // value. The ONLY always-on exception is the hovered node + its 1-hop
    // neighbors — the active/root node is marked by accent color, NOT a label,
    // until hovered or zoomed (Obsidian-pure). Greedy collision-skip keeps it calm.
    function drawLabels(now) {
      var s = cam.scale;
      // Baseline: the auto-fit scale. Until the first fit runs, fall back to the
      // live scale so the ratio is 1.0 (default view = clean) and nothing breaks.
      var base = fitScale != null ? fitScale : s;
      var lo = base * LABEL_FADE_LO_MULT; // <= this scale → labels hidden
      var hi = base * LABEL_FADE_HI_MULT; // >= this scale → labels fully in
      var hovering = hoverId != null || focusIdx >= 0;
      // calm void: at/under the wide default with no hover, draw nothing.
      if (s <= lo && !hovering) return;
      var focusNode = focusIdx >= 0 && a11yOrder[focusIdx] ? a11yOrder[focusIdx] : null;
      // normalize the zoom-in distance past the floor into 0..1, then ease.
      // zoomT rises only as s climbs from lo→hi, so zooming IN reveals labels and
      // zooming OUT (back toward fitScale) hides them. Direction is correct by
      // construction: larger s → larger zoomT → higher opacity.
      var zoomT = hi > lo ? clamp((s - lo) / (hi - lo), 0, 1) : (s >= hi ? 1 : 0);
      zoomT = easeOutCubic(zoomT);
      // degree bias: hubs surface earlier. Bias the effective fade-in per node
      // by its share of the max degree so high-degree labels appear first.
      var maxDeg = 1;
      for (var di = 0; di < nodes.length; di++) {
        if (!nodes[di].phantom && nodes[di].degree > maxDeg) maxDeg = nodes[di].degree;
      }
      // Finder filter active? Then the visible results OWN the labels: every
      // match is labeled (regardless of zoom), scaled by its score, and the
      // dimmed non-matches stay text-free so the result set's titles read clean.
      var matchOn = externalMatch != null;
      // ── pass 1: collect eligible labels with their fade alpha ──
      var cand = [];
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var isFocused = focusNode && node.id === focusNode.id;
        if (node.alpha < 0.3 && !isFocused) continue;
        var isRoot = node.id === rootId;
        var isHov = isFocused || node.id === hoverId || (hoverId != null && adj[hoverId] && adj[hoverId][node.id]);
        var mw = node.matchW || 0;
        var isMatch = matchOn && mw > 0;
        // Under a filter, non-matches carry no label (unless the pointer is on
        // their ego-network) — keeps the matched titles uncluttered.
        if (matchOn && !isMatch && !isHov) continue;
        var deg = node.degree;
        var show = false;
        var labelA = 1;
        if (isHov) {
          // hovered node + its 1-hop neighbors: ALWAYS shown, full opacity, even
          // at the wide default zoom. This is the focused ego-network reveal.
          show = true;
        } else if (isMatch) {
          // a visible result — always labeled, opacity ramped by search score so
          // the best hits read strongest even at the wide default zoom.
          show = true;
          labelA = clamp(0.45 + 0.55 * mw, 0, 1);
        } else if (s <= lo) {
          // at/under the fit-relative floor, only the hovered ego-net carries
          // labels — the wide view reads as clean dots + faint threads. The
          // root is NOT exempt here: it's marked by accent color, not a label.
          continue;
        } else {
          // per-node fade: shift the zoom ramp earlier for hubs (degree bias)
          // so high-degree nodes label SLIGHTLY first. degBias in [0, ~0.25] —
          // kept gentle so even the biggest hub is still hidden at the fade
          // floor (zoomT≈0) and only surfaces once the user zooms past it.
          var degBias = 0.25 * (Math.sqrt(deg) / Math.sqrt(maxDeg));
          labelA = clamp(zoomT + degBias, 0, 1);
          if (labelA > 0.05) show = true;
        }
        if (!show || labelA <= 0.001) continue;
        if (node.phantom && s < hi && !isHov) continue;
        // importance: root > hovered/adjacent > strong match (by score) > degree.
        // High importance wins contested space in the greedy declutter below.
        var prio = isRoot ? 3 : isHov ? 2.6 : isMatch ? 1.6 + mw : deg / 1000;
        // Only the very top matches are never decluttered away — their title
        // must always show. Everything below still yields to collisions, so a
        // dense result cluster can't pile its labels into an unreadable stack.
        var forceKeep = isMatch && mw >= 0.8;
        cand.push({ node: node, isRoot: isRoot, isHov: isHov, isMatch: isMatch, forceKeep: forceKeep, labelA: labelA, prio: prio });
      }
      // ── pass 2: priority-greedy declutter ──
      // Iterate high-importance first; skip any non-root/non-hover label whose
      // estimated AABB overlaps an already-placed one. Keeps the constellation
      // legible at every zoom on real data without a quadtree (O(n*k), k tiny
      // since most frames have <40 visible labels). Root/hover never suppressed.
      cand.sort(function (a, b) { return b.prio - a.prio; });
      var placed = [];
      for (var c = 0; c < cand.length; c++) {
        var it = cand[c];
        var nd = it.node;
        var ndW = nd.matchW || 0;
        var p = worldToScreen(nd.x, nd.y);
        var rBoost = it.isMatch && ndW > 0 ? 1 + 0.9 * ndW : 1;
        var r = Math.min(nd.r * cam.scale * rBoost, NODE_R_SCREEN_MAX + 9 * ndW);
        var x = Math.round(p[0]);
        var y = Math.round(p[1] + r + (it.isRoot ? 12 : 10));
        var fontPx = it.isRoot ? 11 : nd.phantom ? 9 : it.isMatch ? 10 + Math.round(2 * ndW) : 10;
        var label = nd.phantom ? nd.broken_id || nd.title : nd.title;
        var halfW = Math.min(String(label).length * fontPx * 0.3, it.isMatch ? 80 : 55);
        var box = [x - halfW, y - 7, x + halfW, y + 7];
        if (!it.isRoot && !it.isHov && !it.forceKeep) {
          var hit = false;
          for (var k = 0; k < placed.length; k++) {
            var pb = placed[k];
            if (box[0] < pb[2] && box[2] > pb[0] && box[1] < pb[3] && box[3] > pb[1]) {
              hit = true;
              break;
            }
          }
          if (hit) continue;
        }
        placed.push(box);
        drawLabel(nd, it.isRoot, it.isHov, it.labelA);
      }
    }

    var truncCache = {};
    function truncate(text, font, maxW, track) {
      track = track || "0px";
      var key = text + "|" + font + "|" + maxW + "|" + track;
      if (truncCache[key]) return truncCache[key];
      ctx.font = font;
      // Measure WITH the same tracking the draw will use, or long titles
      // mis-truncate by ~1 char. Save/restore the canvas letterSpacing so this
      // measurement doesn't leak into other draws.
      var prevLS = ctx.letterSpacing;
      if ("letterSpacing" in ctx) ctx.letterSpacing = track;
      var result;
      if (ctx.measureText(text).width <= maxW) {
        result = text;
      } else {
        var lo = 0,
          hi = text.length;
        while (lo < hi) {
          var mid = (lo + hi) >> 1;
          var s = text.slice(0, mid) + "…";
          if (ctx.measureText(s).width <= maxW) lo = mid + 1;
          else hi = mid;
        }
        result = text.slice(0, Math.max(0, lo - 1)) + "…";
      }
      if ("letterSpacing" in ctx) ctx.letterSpacing = prevLS;
      truncCache[key] = result;
      return result;
    }

    // Obsidian label: small system-UI text, muted grey, just under the dot, NO
    // pill background — only a very subtle 1px dark shadow for legibility.
    function drawLabel(node, isRoot, isHov, labelA) {
      if (labelA == null) labelA = 1;
      var p = worldToScreen(node.x, node.y);
      var mw = externalMatch != null ? node.matchW || 0 : 0;
      var rBoost = mw > 0 ? 1 + 0.9 * mw : 1;
      var r = Math.min(node.r * cam.scale * rBoost, NODE_R_SCREEN_MAX + 9 * mw);
      var baseColor = theme === "light" ? LABEL_COLOR_LIGHT : LABEL_COLOR_DARK;
      var font, color, track;
      if (isRoot) {
        // active node label — accent-tinted, a hair larger. Not a sun, just
        // gently distinguished.
        font = "500 11px " + FONT_STACK;
        color = ACCENT;
        track = "0.005em";
      } else if (node.phantom) {
        font = "italic 400 9px " + FONT_STACK;
        color = theme === "light" ? rgba(MONO_LIGHT, 0.65) : rgba(MONO_DARK, 0.5);
        track = "0.01em";
      } else if (mw > 0) {
        // a visible result — score-scaled: the better the rank, the larger and
        // brighter the title (node carries the accent; the label stays in the
        // high-legibility grey→white family).
        font = (mw >= 0.55 ? "500 " : "400 ") + (10 + Math.round(2 * mw)) + "px " + FONT_STACK;
        color = isHov
          ? (theme === "light" ? "#2a2e3a" : "#e6e7f0")
          : mixHex(baseColor, theme === "light" ? "#1e2230" : "#e8e9f2", 0.35 + 0.5 * mw);
        track = "0.006em";
      } else {
        font = "400 10px " + FONT_STACK;
        // hovered node + neighbors brighten their label toward the node color.
        color = isHov
          ? (theme === "light" ? "#2a2e3a" : "#d8dae6")
          : baseColor;
        track = "0.008em";
      }
      if (forced) color = "CanvasText";

      var label = node.phantom ? node.broken_id || node.title : node.title;
      // Matched results get more room for their title (the user wants to read
      // them); the strongest match shows the most.
      var maxW = isHov ? 9999 : mw > 0 ? 150 + Math.round(110 * mw) : 120;
      var text = isHov ? label : truncate(label, font, maxW, track);

      var x = Math.round(p[0]);
      var y = Math.round(p[1] + r + (isRoot ? 12 : mw > 0 ? 11 : 10));
      ctx.save();
      ctx.font = font;
      if ("letterSpacing" in ctx) ctx.letterSpacing = track;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      // Fade with zoom (labelA) on top of the node's own alpha.
      ctx.globalAlpha = node.alpha * labelA;
      // Subtle 1px dark drop shadow for legibility — no pill. Skip in light/forced.
      if (!forced && theme !== "light") {
        ctx.fillStyle = "rgba(10,10,14,0.85)";
        ctx.fillText(text, x + 0.6, y + 0.8);
      } else if (theme === "light" && !forced) {
        ctx.fillStyle = "rgba(255,255,255,0.85)";
        ctx.fillText(text, x + 0.6, y + 0.8);
      }
      ctx.fillStyle = color;
      ctx.fillText(text, x, y);
      ctx.restore();
    }

    function drawFocusRing(node) {
      var p = worldToScreen(node.x, node.y);
      var r = node.r * cam.scale + 4;
      ctx.save();
      ctx.strokeStyle = A11Y_RING;
      ctx.lineWidth = 3;
      if (!reduced) {
        ctx.shadowColor = A11Y_RING;
        ctx.shadowBlur = 8;
      }
      ctx.beginPath();
      ctx.arc(p[0], p[1], r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // ── TOOLTIP ──
    function updateTooltip() {
      if (hoverId == null) {
        tooltip.style.opacity = "0";
        return;
      }
      var node = byId[hoverId];
      if (!node) {
        tooltip.style.opacity = "0";
        return;
      }
      var p = worldToScreen(node.x, node.y);
      var html = "";
      var title = node.phantom ? node.broken_id || node.title : node.title;
      // Hairline the title underline with the node's resolved hue for a bespoke
      // feel (vs. a generic popover). Title text stays high-contrast per theme
      // (white was invisible on the light tooltip's white glass).
      var hue = node.phantom ? SLATE : TYPE_HEX[node.type] || SLATE;
      var light = theme === "light";
      html +=
        "<div style='font-weight:600;color:" + (light ? "#16161a" : "#fff") + ";margin-bottom:4px;padding-bottom:3px;" +
        "border-bottom:1.5px solid " + rgba(hue, 0.55) + "'>" + esc(title) + "</div>";
      if (node.phantom) {
        var line = node.via
          ? esc(node.broken_id) + " · via " + esc(node.via)
          : esc(node.broken_id) + " · broken reference";
        html += "<div style='color:" + (light ? MONO_LIGHT : SLATE) + "'>" + line + "</div>";
      } else {
        html += "<div style='color:" + (light ? shiftL(ACCENT, -0.22) : rgba(ACCENT, 0.9)) + "'>" + esc(node.type) + "</div>";
        var cc = Object.keys(adj[node.id] || {}).length;
        html += "<div style='color:" + (light ? "rgba(15,17,23,0.6)" : "rgba(226,232,240,0.7)") + ";margin-top:2px'>" + cc + " connection" + (cc === 1 ? "" : "s") + "</div>";
      }
      tooltip.innerHTML = html;
      tooltip.style.background = light ? "rgba(255,255,255,0.92)" : "rgba(19,20,27,0.92)";
      tooltip.style.border = "1px solid " + (light ? "rgba(15,17,23,0.10)" : "rgba(255,255,255,0.08)");
      tooltip.style.backdropFilter = "blur(14px)";
      tooltip.style.opacity = "1";

      // flip-and-clamp
      var rect = containerEl.getBoundingClientRect();
      var tw = tooltip.offsetWidth || 200,
        th = tooltip.offsetHeight || 60;
      var tx = p[0] + 16,
        ty = p[1] - th - 8;
      if (tx + tw > W - 8) tx = p[0] - tw - 16;
      if (ty < 8) ty = p[1] + 16;
      tx = clamp(tx, 8, W - tw - 8);
      ty = clamp(ty, 8, H - th - 8);
      tooltip.style.left = tx + "px";
      tooltip.style.top = ty + "px";
    }

    function esc(s) {
      return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
      });
    }

    // ════════════════════════════════════════════════════════ RENDER LOOP ══
    function frame(now) {
      if (destroyed) return;
      var dt = lastFrame ? Math.min(now - lastFrame, 50) : 16.67;
      lastFrame = now;

      // frame budget monitor (glow degrade ladder)
      frameTimes.push(dt);
      if (frameTimes.length > 30) frameTimes.shift();
      monitorTier();

      if (!reduced && !morph) {
        // physics accumulate, cap 3 ticks/frame. The sim is FROZEN while a nav
        // morph eases (stepMorph owns positions then). Idle (alpha<0.05) is
        // draw-only: the O(n^2) sim is gated off below the ring-engage
        // threshold so a settled constellation costs one draw, not draw+sim.
        var ticks = Math.min(3, Math.max(1, Math.round(dt / 16.67)));
        if (!sparseMode && alpha >= 0.05) {
          for (var i = 0; i < ticks; i++) tick(16.67, false);
        }
      }

      // One-shot auto-fit: the sim has now first cooled below the settle
      // threshold, so the settled clump is framed ONCE. Skipped if the user has
      // panned/zoomed in the meantime (their view wins) or a fit is mid-flight.
      if (!_autoFitDone && alpha < 0.05 && !morph) {
        _autoFitDone = true;
        if (!_userMovedCam) fitInternal(!reduced); // reduced → instant, no ease
      }

      computeAlphaTargets();
      lerpAlphas(dt);

      // eased zoom: glide cam.scale toward camTargetScale, keeping the cursor
      // world-point pinned (luxe register ~350-450ms). Snap when reduced.
      if (!camAnimating && Math.abs(cam.scale - camTargetScale) > 0.0005) {
        if (reduced) {
          cam.scale = camTargetScale;
        } else {
          cam.scale += (camTargetScale - cam.scale) * kStep(0.16, dt);
          if (Math.abs(cam.scale - camTargetScale) < 0.0008) cam.scale = camTargetScale;
        }
        if (camZoomAnchor) {
          cam.tx = camZoomAnchor.px - camZoomAnchor.wx * cam.scale;
          cam.ty = camZoomAnchor.py - camZoomAnchor.wy * cam.scale;
        }
      }

      // hover corona spring — SNAPPY in (~100ms), LUXE out (~350ms). This is
      // the named "fast-in/slow-out" luxe tell, on the most-used interaction.
      var coronaTarget = hoverId != null ? 1 : 0;
      if (reduced) {
        hoverCoronaK = coronaTarget;
      } else {
        var ck = coronaTarget > hoverCoronaK ? kStep(0.30, dt) : kStep(0.10, dt);
        hoverCoronaK += (coronaTarget - hoverCoronaK) * ck;
        if (Math.abs(hoverCoronaK - coronaTarget) < 0.002) hoverCoronaK = coronaTarget;
      }

      // selection-ring pulse decay (snappy trigger half of the asymmetry)
      if (selectPulse > 0) {
        selectPulse = reduced ? 0 : Math.max(0, selectPulse - dt / 420);
      }

      // pan inertia (frame-rate-independent decay). 0.95/frame ≈ 20-frame
      // half-life for a longer, weighted "ice" coast (premium-canvas feel),
      // then a clean low-velocity snap so the glide ends crisply instead of
      // asymptotically smearing the last sub-pixel for many frames.
      if (!dragging && (Math.abs(panVX) > 0.1 || Math.abs(panVY) > 0.1)) {
        cam.tx += panVX;
        cam.ty += panVY;
        var pd = Math.pow(0.95, dt / 16.67);
        panVX *= pd;
        panVY *= pd;
        if (Math.abs(panVX) < 0.25 && Math.abs(panVY) < 0.25) {
          panVX = panVY = 0;
        }
      }

      // ── settle / breathe / park decision ──────────────────────────────────
      // Active motion (sim cooling, drag/pan/zoom, focus or hover crossfade,
      // fetch ring) redraws every frame. Otherwise the SETTLED graph "breathes":
      // the loop stays awake but draw() is throttled to BREATH_FPS and applies a
      // tiny render-only sway, so it feels alive at ~1/5 the cost of the old
      // 60fps idle burn. Off-screen OR reduced-motion → no breathing, full park.
      var stillFocus = isFocusLerping();
      var alive = !reduced && (alpha >= 0.05 || alphaTarget >= 0.05);
      var hasBreathingNode =
        !reduced && !errorState && fetching && nodes.length === 0;
      var interacting =
        dragging ||
        Math.abs(panVX) > 0.1 ||
        Math.abs(panVY) > 0.1 ||
        morph ||
        camAnimating ||
        Math.abs(cam.scale - camTargetScale) > 0.0005;
      var activeMotion =
        alive ||
        interacting ||
        stillFocus ||
        hasBreathingNode ||
        hoverCoronaK > 0.001 ||
        selectPulse > 0;
      // Idle breathing off (Obsidian-quiet): a settled, un-hovered graph parks
      // the rAF loop entirely — no perpetual redraw. Only re-enabled by IDLE_BREATH.
      var breathing =
        IDLE_BREATH && !reduced && visible && _autoFitDone && !errorState && nodes.length > 0;

      if (activeMotion) {
        draw(now);
      } else if (breathing) {
        // throttle the idle redraw — the sway is slow, so ~12fps reads smooth
        if (now - lastBreathDraw >= 1000 / BREATH_FPS) {
          lastBreathDraw = now;
          draw(now);
        }
      } else {
        draw(now); // one last frame as it comes to rest, then park below
      }

      var keepGoing = activeMotion || breathing;
      // Off-screen: park UNLESS mid-interaction/morph (those must complete) OR
      // the one-shot auto-fit hasn't run yet. The IntersectionObserver can report
      // not-visible on its FIRST async callback when the canvas is in-flow inside
      // overflow/scroll ancestors (e.g. a React pane), which would park the loop
      // before the sim ever settles + frames — leaving a blank canvas that never
      // re-wakes (the element's visibility never CHANGES, so no wake fires). Hold
      // the loop alive until the initial fit completes; normal off-screen parking
      // (CPU saving) resumes after that.
      if (!visible && !interacting && !stillFocus && _autoFitDone) keepGoing = false;
      if (keepGoing) {
        rafId = requestAnimationFrame(frame);
      } else {
        running = false;
        rafId = null;
      }
    }

    function isFocusLerping() {
      return _lerpDirty > 0;
    }

    function wake() {
      if (destroyed) return;
      if (reduced) {
        // one tick-free redraw, then park
        requestAnimationFrame(function (now) {
          if (destroyed) return;
          computeAlphaTargets();
          // snap focus alphas (k=1)
          nodes.forEach(function (n) {
            n.alpha = n.alphaTarget;
            n.depth = n.depthTarget;
          });
          edges.forEach(function (e) {
            e.alpha = Math.min(e.alphaTarget, Math.min(e.src.alpha, e.dst.alpha));
          });
          draw(now);
        });
        return;
      }
      if (!running) {
        running = true;
        lastFrame = 0;
        rafId = requestAnimationFrame(frame);
      }
    }

    function reheat(target) {
      if (reduced) {
        wake();
        return;
      }
      // Re-energize the CURRENT heat (alpha) so the layout responds, but keep the
      // cooling FLOOR at the resting warmth (0.03, matching init) — do NOT pin
      // alphaTarget to `target`. Pinning it (e.g. reheat(0.3) on hover/drag) left
      // alphaTarget ≥ 0.05 permanently, so `alive` above never went false and the
      // loop never re-parked after the first interaction. Bumping alpha alone
      // re-runs the sim briefly, then it cools back to rest and parks.
      if (alpha < target) alpha = target;
      alphaTarget = 0.03;
      wake();
    }

    // ── glow tier monitor ──
    // DPR-aware ceiling: the cost driver is device-pixel node AREA, not raw
    // count, so a high-DPR retina session starts at a safer tier instead of
    // waiting ~0.5s for the time-based demote to react. Effective load ≈
    // n * dpr^2 (avg radius is roughly constant), so scale the thresholds down.
    function ceilingTier() {
      var n = nodes.length;
      var load = n * dpr * dpr;
      if (load > 1600) return 3; // ~800 @ dpr 1.4, ~400 @ dpr 2
      if (load > 600) return 2; // ~300 @ dpr 1.4, ~150 @ dpr 2
      return 0;
    }
    function monitorTier() {
      if (reduced) {
        glowTier = Math.max(1, ceilingTier());
        return;
      }
      var ceil = ceilingTier();
      if (glowTier < ceil) glowTier = ceil;
      if (frameTimes.length < 30) return;
      var sorted = frameTimes.slice().sort(function (a, b) { return a - b; });
      var med = sorted[15];
      if (med > 22) {
        demoteRun++;
        promoteRun = 0;
        if (demoteRun >= 30 && glowTier < 3) {
          glowTier++;
          demoteRun = 0;
        }
      } else if (med < 12) {
        promoteRun++;
        demoteRun = 0;
        if (promoteRun >= 120 && glowTier > ceil) {
          glowTier--;
          promoteRun = 0;
        }
      } else {
        demoteRun = 0;
        promoteRun = 0;
      }
    }

    // ════════════════════════════════════════════════ NAV MORPH (data-rev) ══
    // NAV MORPH — "glides, never teleports". ingest() pre-warms the sim so
    // every PERSIST node is already at its NEW settled target; we snapshot
    // those targets, snap nodes BACK to their old coords, then ease each node
    // from old -> target over 480ms with the sim FROZEN (stepMorph skips
    // tick()). New (non-PERSIST) nodes keep their entrance choreography.
    // Reduced-motion: zero duration (instant).
    function startMorph(oldPos) {
      if (reduced) {
        morph = null;
        return;
      }
      var from = {},
        to = {};
      var any = false;
      nodes.forEach(function (nd) {
        var op = oldPos[nd.id];
        if (op) {
          from[nd.id] = { x: op.x, y: op.y };
          to[nd.id] = { x: nd.x, y: nd.y }; // settled target from pre-warm
          nd.x = op.x; // start the glide from the old position
          nd.y = op.y;
          any = true;
        }
      });
      if (!any) {
        morph = null;
        return;
      }
      morph = { start: perfNow(), dur: 480, from: from, to: to };
    }
    function stepMorph(now) {
      var t = clamp((now - morph.start) / morph.dur, 0, 1);
      var e = easeInOutCubic(t);
      var from = morph.from,
        to = morph.to;
      nodes.forEach(function (nd) {
        var f = from[nd.id],
          g = to[nd.id];
        if (f && g) {
          nd.x = f.x + (g.x - f.x) * e;
          nd.y = f.y + (g.y - f.y) * e;
          nd.vx = 0;
          nd.vy = 0;
        }
      });
      if (t >= 1) {
        morph = null;
        reheat(0.03);
      }
    }

    // ════════════════════════════════════════════════════════ HIT TESTING ══
    function clientToWorld(clientX, clientY) {
      var rect = canvas.getBoundingClientRect();
      var sx = (clientX - rect.left) * (W / rect.width);
      var sy = (clientY - rect.top) * (H / rect.height);
      return [(sx - cam.tx) / cam.scale, (sy - cam.ty) / cam.scale];
    }
    function hitTest(clientX, clientY) {
      var w = clientToWorld(clientX, clientY);
      var best = null,
        bestD = Infinity;
      for (var i = nodes.length - 1; i >= 0; i--) {
        var n = nodes[i];
        if (n.alpha < 0.1) continue;
        var dx = w[0] - n.x,
          dy = w[1] - n.y;
        var slop = n.r + 8;
        var d2 = dx * dx + dy * dy;
        if (d2 < slop * slop && d2 < bestD) {
          best = n;
          bestD = d2;
        }
      }
      return best;
    }

    // ════════════════════════════════════════════════════════════ EVENTS ══
    function onPointerMove(ev) {
      if (dragging) {
        var rect = canvas.getBoundingClientRect();
        var dx = ev.movementX != null ? ev.movementX * (W / rect.width) : 0;
        var dy = ev.movementY != null ? ev.movementY * (H / rect.height) : 0;
        if (dragNode) {
          // Only move the node once the pointer crosses the click→drag threshold,
          // so a plain click never nudges it under the cursor. Matches onPointerUp's
          // wasDrag test — below 4px it's a click (opens the node), not a drag.
          var movedFar =
            pointerStart &&
            (Math.abs(ev.clientX - pointerStart.x) > 4 || Math.abs(ev.clientY - pointerStart.y) > 4);
          if (movedFar) {
            var w = clientToWorld(ev.clientX, ev.clientY);
            dragNode.x = w[0];
            dragNode.y = w[1];
          }
        } else {
          cam.tx += dx;
          cam.ty += dy;
          _userMovedCam = true; // manual pan disqualifies the one-shot auto-fit
          lastMoves.push({ x: dx, y: dy, t: perfNow() });
          if (lastMoves.length > 3) lastMoves.shift();
        }
        wake();
        return;
      }
      var hit = hitTest(ev.clientX, ev.clientY);
      var newHover = hit ? hit.id : null;
      if (newHover !== hoverId) {
        hoverId = newHover;
        canvas.style.cursor = hit && !hit.phantom ? "pointer" : spaceDown ? "grab" : "grab";
        if (hit && opts.onNodeHover) opts.onNodeHover(hit.raw);
        else if (opts.onNodeHover) opts.onNodeHover(null);
        // Obsidian-quiet: hover must NOT move nodes. Just wake the loop for the
        // opacity/depth crossfade (kept alive by isFocusLerping); never reheat the
        // physics sim — that drifted the whole layout under the cursor.
        wake();
      }
    }

    // Clear hover when the pointer LEAVES the canvas. onPointerMove only clears
    // hoverId on a move to empty space; if the mouse leaves the canvas while over
    // a node (onto the finder rail, another window) no move fires, so hoverId
    // stays set and the hover-corona keep-alive pins the rAF loop at 60fps
    // forever — re-opening the exact perpetual-redraw we just closed. One redraw
    // of the cleared state, then the loop re-parks.
    function onPointerLeave() {
      if (dragging || hoverId == null) return;
      hoverId = null;
      if (opts.onNodeHover) opts.onNodeHover(null);
      wake();
    }

    function onPointerDown(ev) {
      canvas.setPointerCapture && canvas.setPointerCapture(ev.pointerId);
      var hit = hitTest(ev.clientX, ev.clientY);
      pointerStart = { x: ev.clientX, y: ev.clientY, t: perfNow() };
      dragging = true;
      lastMoves = [];
      panVX = panVY = 0;
      if (hit && !hit.phantom && hit.id !== rootId && !spaceDown && ev.button === 0) {
        dragNode = hit;
        // Wake for the press/drag, but do NOT reheat the sim — a click (or even a
        // drag) must not re-energize the layout and set every node drifting. The
        // dragged node follows the cursor directly in onPointerMove; the rest hold.
        wake();
      } else {
        dragNode = null;
        canvas.style.cursor = "grabbing";
      }
    }

    function onPointerUp(ev) {
      canvas.releasePointerCapture && canvas.releasePointerCapture(ev.pointerId);
      var wasDrag = pointerStart && (Math.abs(ev.clientX - pointerStart.x) > 4 || Math.abs(ev.clientY - pointerStart.y) > 4);
      dragging = false;
      if (dragNode) {
        dragNode = null;
        reheat(0.03);
      } else if (!wasDrag) {
        // click
        var hit = hitTest(ev.clientX, ev.clientY);
        if (hit && !hit.phantom) {
          selectId = hit.id;
          selectPulse = reduced ? 0 : 1;
          if (opts.onNodeClick) opts.onNodeClick(hit.raw);
        }
      } else {
        // inertia from rolling velocity
        if (lastMoves.length) {
          var last = lastMoves[lastMoves.length - 1];
          // Scale the flick (×1.4) so a gentle release still carries under the
          // longer 0.95 decay instead of feeling sluggish.
          panVX = reduced ? 0 : last.x * 1.4;
          panVY = reduced ? 0 : last.y * 1.4;
        }
      }
      canvas.style.cursor = "grab";
      wake();
    }

    function onWheel(ev) {
      ev.preventDefault();
      var delta = ev.deltaY;
      if (ev.deltaMode === 1) delta *= 8;
      else if (ev.deltaMode === 2) delta *= 24;
      delta = clamp(delta, -24, 24);
      var rect = canvas.getBoundingClientRect();
      var px = (ev.clientX - rect.left) * (W / rect.width);
      var py = (ev.clientY - rect.top) * (H / rect.height);
      // anchor the world-point under the cursor; the frame loop keeps it pinned
      // while cam.scale eases toward the new target (luxe glide, no snap).
      var wx = (px - cam.tx) / cam.scale,
        wy = (py - cam.ty) / cam.scale;
      camAnimating = false; // a fit-glide is interrupted by a manual wheel
      _userMovedCam = true; // manual zoom disqualifies the one-shot auto-fit
      camZoomAnchor = { wx: wx, wy: wy, px: px, py: py };
      var factor = Math.exp(-delta * 0.0015);
      camTargetScale = clamp(camTargetScale * factor, 0.08, 4.0);
      if (reduced) {
        cam.scale = camTargetScale;
        cam.tx = px - wx * cam.scale;
        cam.ty = py - wy * cam.scale;
      }
      wake();
      scheduleSaveView();
    }

    // Canvas focus delegates into the a11y tree — Tab into the graph lands on
    // the last-focused node (or root) so arrow keys immediately traverse.
    function onCanvasFocus() {
      var divs = a11yRoot.children;
      if (!divs.length) return;
      var idx = focusIdx >= 0 && focusIdx < divs.length ? focusIdx : 0;
      if (divs[idx]) divs[idx].focus();
    }

    function onKeyDown(ev) {
      if (ev.code === "Space") {
        spaceDown = true;
        canvas.style.cursor = "grab";
      }
    }
    function onKeyUp(ev) {
      if (ev.code === "Space") spaceDown = false;
    }

    function onResize() {
      resize();
      wake();
    }

    function onVVChange() {
      resize();
      wake();
    }

    function onReduceChange() {
      reduced = reduceMQ ? reduceMQ.matches : reduced;
      if (reduced) {
        if (rafId) cancelAnimationFrame(rafId);
        running = false;
        settleSyncIfNeeded();
      }
      wake();
    }
    function settleSyncIfNeeded() {
      // park into static frame
      alphaTarget = 0;
    }
    function onForcedChange() {
      forced = forcedMQ ? forcedMQ.matches : forced;
      // Rebuild chrome so legend swatches/toggles use system colors in forced
      // mode (colored swatches would be overridden unpredictably otherwise).
      buildChrome();
      wake();
    }

    // ════════════════════════════════════════════════════════ RESIZE/DPR ══
    var _lastBackW = -1,
      _lastBackH = -1;
    function resize() {
      var rect = containerEl.getBoundingClientRect();
      W = rect.width || 800;
      H = rect.height || 600;
      // Clamp the effective render scale: at high DPR the full-canvas glow +
      // vignette over a large pane is the dominant fill cost, and the bloom
      // hides the resolution loss — so cap the backing store at 2x (rather than
      // the device's 3x) for the glow layer's worst case.
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      var bw = Math.round(W * dpr),
        bh = Math.round(H * dpr);
      // Skip the canvas.width reassignment (which clears + reallocs the backing
      // store) when the rounded device dimensions are unchanged — avoids realloc
      // thrash on sub-pixel LiveView layout reflows.
      if (bw !== _lastBackW || bh !== _lastBackH) {
        canvas.width = bw;
        canvas.height = bh;
        _lastBackW = bw;
        _lastBackH = bh;
        _bgGrad = null; // backing store changed -> rebuild cached vignette
      }
      R_RING = 0.22 * Math.min(W, H);
    }

    // ════════════════════════════════════════════════════════ FIT TO VIEW ══
    function fitInternal(animate) {
      var real = nodes.filter(function (n) { return !n.phantom && n.alpha > 0.01; });
      if (!real.length) {
        cam = { tx: 0, ty: 0, scale: 1 };
        return;
      }
      var minX = Infinity,
        minY = Infinity,
        maxX = -Infinity,
        maxY = -Infinity;
      real.forEach(function (n) {
        minX = Math.min(minX, n.x - n.r);
        minY = Math.min(minY, n.y - n.r);
        maxX = Math.max(maxX, n.x + n.r);
        maxY = Math.max(maxY, n.y + n.r);
      });
      var inset = 48;
      var bw = maxX - minX,
        bh = maxY - minY;
      // Fit MAX-ZOOM cap is 2.0 (was 4.0): the default fit view stays zoomed
      // OUT, so dots stay small with lots of dark space, and a sparse 3-node
      // graph can't over-zoom its compact layout into big discs.
      var scale = Math.min((W - inset * 2) / bw, (H - inset * 2) / bh, 2.0);
      scale = clamp(scale, 0.08, 2.0);
      // Record the default/wide zoom baseline. Both the animated and the
      // instant (settle / reduced-motion) paths funnel through here, so this
      // is the single capture point for the fit-relative label gate.
      fitScale = scale;
      var cx = (minX + maxX) / 2,
        cy = (minY + maxY) / 2;
      var target = {
        scale: scale,
        tx: W / 2 - cx * scale,
        ty: H / 2 - cy * scale
      };
      if (animate && !reduced) {
        animateCam(target);
      } else {
        cam.scale = target.scale;
        cam.tx = target.tx;
        cam.ty = target.ty;
        camTargetScale = target.scale;
        camZoomAnchor = null;
      }
      wake();
    }

    var camAnimToken = 0;
    function animateCam(target) {
      // A fresh fit cancels any in-flight glide so two easing curves never
      // stack and fight (rapid double-click / refit). The eased-zoom frame
      // path is suppressed via camAnimating while this owns the camera.
      var myToken = ++camAnimToken;
      camAnimating = true;
      camZoomAnchor = null;
      camTargetScale = target.scale;
      var start = { tx: cam.tx, ty: cam.ty, scale: cam.scale };
      var t0 = perfNow();
      // 360ms expo-out: shares one perceived "physics" with the wheel-zoom
      // (now ~180ms via kStep(0.16)) — fast initial response, long graceful
      // settle, consistent ~180-360ms band, so both camera paths read as the
      // same operator rather than two different hands.
      var dur = 360;
      function step() {
        if (destroyed || myToken !== camAnimToken) return;
        var t = clamp((perfNow() - t0) / dur, 0, 1);
        var e = easeOutExpo(t);
        cam.tx = start.tx + (target.tx - start.tx) * e;
        cam.ty = start.ty + (target.ty - start.ty) * e;
        cam.scale = start.scale + (target.scale - start.scale) * e;
        if (t < 1) {
          requestAnimationFrame(step);
        } else {
          camAnimating = false;
        }
      }
      requestAnimationFrame(step);
    }

    // Bring a node comfortably into view for keyboard focus. Pans the camera
    // to center it and zooms IN if it would render below a legible on-screen
    // radius. Animated normally, snapped under reduced-motion.
    function centerOnNode(node) {
      if (!node) return;
      var minOnScreen = 22; // px; below this the node is too small to read
      var targetScale = cam.scale;
      if (node.r * cam.scale < minOnScreen) {
        targetScale = clamp(minOnScreen / Math.max(node.r, 1), cam.scale, 1.6);
      }
      var target = {
        scale: targetScale,
        tx: W / 2 - node.x * targetScale,
        ty: H / 2 - node.y * targetScale
      };
      if (reduced) {
        cam.scale = target.scale;
        cam.tx = target.tx;
        cam.ty = target.ty;
        camTargetScale = target.scale;
        camZoomAnchor = null;
      } else {
        animateCam(target);
      }
    }

    // ════════════════════════════════════════════════════════════ A11Y ══
    function buildA11yTree() {
      a11yRoot.innerHTML = "";
      a11yOrder = [];
      var visited = {};
      function sortNb(a, b) {
        if (b.degree !== a.degree) return b.degree - a.degree;
        return String(a.title).localeCompare(String(b.title));
      }
      // root first, DFS
      if (rootId && byId[rootId]) {
        var stack = [byId[rootId]];
        while (stack.length) {
          var n = stack.pop();
          if (visited[n.id]) continue;
          visited[n.id] = true;
          a11yOrder.push(n);
          var nbs = [];
          for (var nid in adj[n.id]) {
            if (!visited[nid] && byId[nid]) nbs.push(byId[nid]);
          }
          nbs.sort(sortNb);
          for (var i = nbs.length - 1; i >= 0; i--) stack.push(nbs[i]);
        }
      }
      // append all unvisited present nodes
      var rest = nodes.filter(function (n) { return !visited[n.id]; });
      rest.sort(sortNb);
      rest.forEach(function (n) { a11yOrder.push(n); });

      a11yOrder.forEach(function (n, i) {
        var div = document.createElement("div");
        div.setAttribute("role", "treeitem");
        div.setAttribute("tabindex", i === 0 ? "0" : "-1");
        var nb = Object.keys(adj[n.id] || {}).length;
        if (n.phantom) {
          div.setAttribute("aria-disabled", "true");
          div.setAttribute(
            "aria-label",
            n.via ? "Broken reference: " + n.broken_id + " via " + n.via : "Broken reference: " + n.broken_id
          );
        } else {
          var statusPart =
            n.type === "task" && n.status ? ". Status: " + n.status : "";
          div.setAttribute(
            "aria-label",
            n.title + ". " + n.type + statusPart + ". " + nb + " connections."
          );
        }
        div.addEventListener("focus", function () {
          focusIdx = i;
          centerOnNode(n); // bring the focused node comfortably into view
          announce(n);
          wake();
        });
        div.addEventListener("keydown", function (ev) {
          if (ev.key === "Enter" || ev.key === " ") {
            ev.preventDefault();
            if (!n.phantom && opts.onNodeClick) opts.onNodeClick(n.raw);
          } else if (ev.key === "ArrowDown" || ev.key === "ArrowRight") {
            ev.preventDefault();
            moveFocus(1);
          } else if (ev.key === "ArrowUp" || ev.key === "ArrowLeft") {
            ev.preventDefault();
            moveFocus(-1);
          } else if (ev.key === "Escape") {
            focusIdx = -1;
            wake();
          }
        });
        a11yRoot.appendChild(div);
      });
    }
    function moveFocus(dir) {
      var ni = clamp(focusIdx + dir, 0, a11yOrder.length - 1);
      var divs = a11yRoot.children;
      if (divs[focusIdx]) divs[focusIdx].setAttribute("tabindex", "-1");
      focusIdx = ni;
      if (divs[focusIdx]) {
        divs[focusIdx].setAttribute("tabindex", "0");
        divs[focusIdx].focus();
      }
    }
    var announceTimer = null;
    function announce(n) {
      if (announceTimer) clearTimeout(announceTimer);
      announceTimer = setTimeout(function () {
        var nbNames = [];
        for (var nid in adj[n.id]) {
          if (byId[nid]) nbNames.push(byId[nid].title);
        }
        var cc = nbNames.length;
        liveRegion.textContent =
          "Focused: " + n.title + ". Connected to: " + nbNames.slice(0, 5).join(", ") + ". " + cc + " connections.";
      }, 80);
    }

    // ════════════════════════════════════════════════════════════ CHROME ══
    var chromeEls = [];
    var _chromeRevealed = false;
    // Chrome palette for the CURRENT theme. The overlay chrome (legend, zoom
    // strip, toggles, search) was hard-coded dark glass, which read as a stuck
    // dark island once hosts went theme-aware (setTheme re-skins the canvas
    // live). Dark keeps the exact original values; light mirrors them on a
    // white glass. setTheme() rebuilds the chrome so both flip together.
    function chromeC() {
      if (theme === "light") {
        return {
          panelBg: "rgba(255,255,255,0.72)",
          panelBorder: "rgba(15,17,23,0.10)",
          title: "rgba(15,17,23,0.45)",
          row: "rgba(15,17,23,0.68)",
          rowDim: "rgba(15,17,23,0.52)",
          btnBg: "rgba(255,255,255,0.72)",
          btnBgHover: "rgba(255,255,255,0.95)",
          btnBorder: "rgba(15,17,23,0.10)",
          btnBorderHover: "rgba(15,17,23,0.20)",
          btnText: "rgba(15,17,23,0.72)",
          btnTextHover: "rgba(15,17,23,0.95)",
          togBgOn: "rgba(226,229,238,0.8)",
          togBgOff: "rgba(226,229,238,0.45)",
          togBorderOn: "rgba(15,17,23,0.14)",
          togBorderOff: "rgba(15,17,23,0.07)",
          togTextOn: "rgba(15,17,23,0.85)",
          togTextOff: "rgba(15,17,23,0.55)",
          dotOff: "rgba(15,17,23,0.25)",
          inputText: "#16161a",
          mono: MONO_LIGHT,
          phantomRing: "rgba(90,95,110,0.55)"
        };
      }
      return {
        panelBg: "rgba(15,17,23,0.55)",
        panelBorder: "rgba(255,255,255,0.07)",
        title: "rgba(255,255,255,0.45)",
        row: "rgba(255,255,255,0.65)",
        rowDim: "rgba(255,255,255,0.5)",
        btnBg: "rgba(15,17,23,0.55)",
        btnBgHover: "rgba(24,27,36,0.72)",
        btnBorder: "rgba(255,255,255,0.07)",
        btnBorderHover: "rgba(255,255,255,0.14)",
        btnText: "rgba(255,255,255,0.75)",
        btnTextHover: "rgba(255,255,255,0.95)",
        togBgOn: "rgba(40,44,58,0.7)",
        togBgOff: "rgba(40,44,58,0.4)",
        togBorderOn: "rgba(255,255,255,0.12)",
        togBorderOff: "rgba(255,255,255,0.06)",
        togTextOn: "rgba(255,255,255,0.85)",
        togTextOff: "rgba(255,255,255,0.6)",
        dotOff: "rgba(255,255,255,0.25)",
        inputText: "#fff",
        mono: MONO_DARK,
        phantomRing: "rgba(148,163,184,0.5)"
      };
    }
    function buildChrome() {
      // On first build, fade the whole chrome layer in AFTER the constellation
      // has kindled (delay matches the ~600ms guide-circle fade) so the controls
      // feel summoned by the graph rather than bolted on. The guard keeps
      // toggle-click rebuilds from re-fading. Skipped under reduced-motion.
      if (!_chromeRevealed && !reduced) {
        _chromeRevealed = true;
        overlay.style.opacity = "0";
        overlay.style.transition = "opacity .5s ease .35s";
        requestAnimationFrame(function () {
          requestAnimationFrame(function () { overlay.style.opacity = "1"; });
        });
      } else if (!_chromeRevealed) {
        _chromeRevealed = true;
      }
      chromeEls.forEach(function (el) {
        if (el.parentNode) el.parentNode.removeChild(el);
      });
      chromeEls = [];
      var n = nodes.length;
      var cc = chromeC();

      // zoom strip (always)
      var strip = mkPanel("position:absolute;right:16px;bottom:16px;display:flex;flex-direction:column;gap:6px;");
      [
        ["＋", function () { zoomBy(1.25); }, "Zoom in"],
        ["－", function () { zoomBy(0.8); }, "Zoom out"],
        ["⤢", function () { fitInternal(true); }, "Fit to view"],
        ["↺", function () { fitInternal(true); }, "Reset view"]
      ].forEach(function (pair) {
        var b = document.createElement("button");
        b.textContent = pair[0];
        // aria-label + native title: closes the icon-only a11y gap and gives a
        // free hover tooltip (zero JS).
        b.setAttribute("aria-label", pair[2]);
        b.title = pair[2];
        b.style.cssText =
          "width:32px;height:32px;border-radius:8px;cursor:pointer;pointer-events:auto;" +
          "background:" + cc.btnBg + ";border:1px solid " + cc.btnBorder + ";" +
          "color:" + cc.btnText + ";font-size:16px;line-height:1;backdrop-filter:blur(14px);outline:none;" +
          "transition:background .14s ease, border-color .14s ease, transform .08s ease, box-shadow .14s ease;";
        b.addEventListener("click", pair[1]);
        // live pointer states — the difference between "functional" and
        // "crafted" chrome (no new paint cost).
        b.addEventListener("pointerenter", function () {
          b.style.background = cc.btnBgHover;
          b.style.borderColor = cc.btnBorderHover;
          b.style.color = cc.btnTextHover;
        });
        b.addEventListener("pointerleave", function () {
          b.style.background = cc.btnBg;
          b.style.borderColor = cc.btnBorder;
          b.style.color = cc.btnText;
        });
        b.addEventListener("pointerdown", function () { b.style.transform = "scale(0.92)"; });
        b.addEventListener("pointerup", function () { b.style.transform = "scale(1)"; });
        // keyboard focus ring in the distinct A11Y_RING color.
        b.addEventListener("focus", function () { b.style.boxShadow = "0 0 0 2px " + A11Y_RING; });
        b.addEventListener("blur", function () { b.style.boxShadow = "none"; });
        strip.appendChild(b);
      });
      overlay.appendChild(strip);
      chromeEls.push(strip);

      // legend (always). In the DEFAULT monochrome look there is nothing to key
      // by color, so we show a single muted dot. When "Full color" is on, the
      // per-type color key appears — small round swatches, no glyph letters.
      // OVERLAY OWNERSHIP CONTRACT: the renderer owns TOP-LEFT (this legend)
      // and BOTTOM-RIGHT (the zoom strip); TOP-RIGHT is the in-canvas search,
      // suppressed under opts.externalSearch. A hosting app may overlay its own
      // chrome ONLY in a corner the renderer leaves free (the search-starter
      // caption sits bottom-left) — exactly one owner per corner, never two.
      var presentTypes = {};
      nodes.forEach(function (nd) {
        if (!nd.phantom) presentTypes[nd.type] = (presentTypes[nd.type] || 0) + 1;
      });
      // Most-present types first, so the slice(0,8) cap always keeps the types
      // the eye actually meets (count desc, then name for determinism).
      var typeList = Object.keys(presentTypes).sort(function (a, b) {
        return presentTypes[b] - presentTypes[a] || (a < b ? -1 : a > b ? 1 : 0);
      });
      var legend = mkPanel("position:absolute;left:12px;top:12px;padding:9px 11px;max-width:200px;");
      var title = document.createElement("div");
      title.style.cssText = "font-size:10px;letter-spacing:0.04em;text-transform:uppercase;color:" + cc.title + ";margin-bottom:6px;";
      title.textContent = fullColor ? "Types" : "Legend";
      legend.appendChild(title);
      if (fullColor) {
        typeList.slice(0, 8).forEach(function (ty) {
          var row = document.createElement("div");
          row.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;font-size:11px;color:" + cc.row + ";letter-spacing:0.03em;";
          // Swatch matches the DRAWN fill exactly — nodeFill darkens hues on
          // light (shiftL -0.22), so the key must too or the legend lies.
          var swHex = TYPE_HEX[ty] || SLATE;
          if (theme === "light") swHex = shiftL(swHex, -0.22);
          var swStyle = "width:9px;height:9px;flex:0 0 auto;border-radius:50%;background:" + swHex + ";";
          row.innerHTML = "<span style='" + swStyle + "'></span>" + esc(ty);
          legend.appendChild(row);
        });
      } else {
        var mrow = document.createElement("div");
        mrow.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;font-size:11px;color:" + cc.row + ";";
        mrow.innerHTML = "<span style='width:9px;height:9px;flex:0 0 auto;border-radius:50%;background:" + cc.mono + "'></span> document";
        legend.appendChild(mrow);
        var arow = document.createElement("div");
        arow.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;font-size:11px;color:" + cc.row + ";";
        arow.innerHTML = "<span style='width:9px;height:9px;flex:0 0 auto;border-radius:50%;background:" + ACCENT + "'></span> active";
        legend.appendChild(arow);
      }
      // phantom ghost entry
      var prow = document.createElement("div");
      prow.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;font-size:11px;color:" + cc.rowDim + ";font-style:italic;";
      prow.innerHTML = "<span style='width:9px;height:9px;border-radius:50%;border:1px solid " + cc.phantomRing + "'></span> broken ref";
      legend.appendChild(prow);

      // full-color toggle (pill with state dot)
      var fcBtn = mkToggle("Full color", fullColor, function () {
        fullColor = !fullColor;
        saveView();
        buildChrome();
        wake();
      });
      legend.appendChild(fcBtn);
      // flow toggle (pill with state dot)
      var flBtn = mkToggle("Flow", flowOn, function () {
        flowOn = !flowOn;
        saveView();
        buildChrome();
        wake();
      });
      legend.appendChild(flBtn);
      overlay.appendChild(legend);
      chromeEls.push(legend);

      // search (medium+; ghost). Suppressed when an EXTERNAL search owns the
      // query — e.g. the web finder's left rail drives the graph via
      // setMatches(), so a second in-canvas box would be a confusing duplicate.
      if (n > 30 && !opts.externalSearch) {
        var sw = document.createElement("input");
        sw.placeholder = "Search…";
        sw.style.cssText =
          "position:absolute;right:16px;top:12px;width:160px;pointer-events:auto;" +
          "padding:6px 10px;border-radius:8px;background:" + cc.panelBg + ";" +
          "border:1px solid " + cc.panelBorder + ";color:" + cc.inputText + ";font-size:12px;backdrop-filter:blur(14px);font-family:" + FONT_STACK + ";";
        var deb = null;
        sw.addEventListener("input", function () {
          if (deb) clearTimeout(deb);
          deb = setTimeout(function () { applySearch(sw.value); }, 120);
        });
        overlay.appendChild(sw);
        chromeEls.push(sw);
      }
    }

    function mkPanel(extra) {
      var cc = chromeC();
      var d = document.createElement("div");
      d.style.cssText =
        "background:" + cc.panelBg + ";backdrop-filter:blur(14px) saturate(180%);" +
        "border:1px solid " + cc.panelBorder + ";border-radius:10px;pointer-events:auto;" + extra;
      return d;
    }
    // Pill toggle with a state dot (on = accent-lit, off = dim) — reads as
    // premium chrome rather than a debug control with a checkmark-in-label.
    function mkToggle(label, on, fn) {
      var cc = chromeC();
      var b = document.createElement("button");
      b.setAttribute("role", "switch");
      b.setAttribute("aria-checked", on ? "true" : "false");
      b.style.cssText =
        "margin-top:8px;display:flex;align-items:center;gap:7px;width:100%;padding:5px 9px;" +
        "border-radius:7px;cursor:pointer;text-align:left;" +
        "background:" + (on ? cc.togBgOn : cc.togBgOff) + ";" +
        "border:1px solid " + (on ? cc.togBorderOn : cc.togBorderOff) + ";" +
        "color:" + (on ? cc.togTextOn : cc.togTextOff) + ";" +
        "font-size:11px;pointer-events:auto;font-family:" + FONT_STACK + ";" +
        "transition:background .14s ease, border-color .14s ease, transform .08s ease, box-shadow .14s ease;";
      var dot = document.createElement("span");
      dot.style.cssText =
        "width:7px;height:7px;border-radius:50%;flex:0 0 auto;" +
        (on
          ? "background:" + ACCENT + ";box-shadow:0 0 6px " + rgba(ACCENT, 0.8) + ";"
          : "background:" + cc.dotOff + ";");
      var txt = document.createElement("span");
      txt.textContent = label;
      b.appendChild(dot);
      b.appendChild(txt);
      b.addEventListener("click", fn);
      return b;
    }

    function applySearch(q) {
      q = (q || "").toLowerCase().trim();
      if (!q) {
        nodes.forEach(function (n) { n.searchDim = false; });
        wake();
        return;
      }
      nodes.forEach(function (n) {
        n.searchDim = String(n.title).toLowerCase().indexOf(q) === -1;
      });
      wake();
    }

    // ── external match (finder ↔ graph) ──
    // The host app (web finder) publishes the docs currently visible in its
    // result list, each with a WEIGHT in (0..1] derived from its search rank
    // (1 = the top hit). The graph dims everything else AND scales each match's
    // emphasis — dot size, accent warmth, label prominence — by that weight, so
    // the strongest results read loudest. `externalMatch === null` = no filter
    // (full graph, undimmed). Matching mirrors the hover bridge: by doc_id, with
    // id as a fallback. `node.matchW` (0 when unmatched) carries the weight into
    // drawNode/drawLabels.
    var externalMatch = null;
    function matchWeight(n) {
      if (!externalMatch) return -1;
      var w = externalMatch[n.doc_id];
      if (w === undefined) w = externalMatch[n.id];
      return w === undefined ? -1 : w; // -1 → not a match
    }
    function applyExternalMatch() {
      if (!externalMatch) {
        nodes.forEach(function (n) { n.searchDim = false; n.matchW = 0; });
        return;
      }
      nodes.forEach(function (n) {
        var w = matchWeight(n);
        if (w < 0) { n.searchDim = true; n.matchW = 0; }
        else { n.searchDim = false; n.matchW = w; }
      });
    }

    function zoomBy(factor) {
      var px = W / 2,
        py = H / 2;
      var wx = (px - cam.tx) / cam.scale,
        wy = (py - cam.ty) / cam.scale;
      camAnimating = false;
      camZoomAnchor = { wx: wx, wy: wy, px: px, py: py };
      camTargetScale = clamp(camTargetScale * factor, 0.08, 4.0);
      if (reduced) {
        cam.scale = camTargetScale;
        cam.tx = px - wx * cam.scale;
        cam.ty = py - wy * cam.scale;
      }
      wake();
      saveView();
    }

    // ─────────────────────────────────────────────────── error/empty state ──
    var fetching = false;
    var errorState = false;

    // ════════════════════════════════════════════════════════════ WIRING ══
    resize();
    ingest(data && data.nodes, data && data.edges);

    canvas.addEventListener("pointermove", onPointerMove);
    canvas.addEventListener("pointerleave", onPointerLeave);
    canvas.addEventListener("pointerdown", onPointerDown);
    canvas.addEventListener("pointerup", onPointerUp);
    canvas.addEventListener("pointercancel", onPointerUp);
    canvas.addEventListener("wheel", onWheel, { passive: false });
    canvas.addEventListener("dblclick", function () { fitInternal(true); });
    canvas.addEventListener("focus", onCanvasFocus);
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    canvas.style.cursor = "grab";

    var ro = null;
    try {
      ro = new ResizeObserver(onResize);
      ro.observe(containerEl);
    } catch (e) {}

    // Park the loop when the pane is scrolled out of view. rAF throttles
    // background TABS but not an on-screen-but-occluded/scrolled pane, so the
    // "alive at rest" perpetual loop would keep paying sim+draw off-screen.
    var io = null,
      visible = true;
    try {
      io = new IntersectionObserver(function (entries) {
        var wasVisible = visible;
        visible = entries[0] && entries[0].isIntersecting;
        if (visible && !wasVisible) wake(); // resume on re-entry
      });
      io.observe(containerEl);
    } catch (e) {}

    var vv = window.visualViewport || null;
    if (vv) {
      vv.addEventListener("resize", onVVChange);
      vv.addEventListener("scroll", onVVChange);
    }
    if (reduceMQ && reduceMQ.addEventListener) reduceMQ.addEventListener("change", onReduceChange);
    if (forcedMQ && forcedMQ.addEventListener) forcedMQ.addEventListener("change", onForcedChange);

    wake();

    // ════════════════════════════════════════════════════════════ PUBLIC ══
    return {
      update: function (newNodes, newEdges, opts2) {
        errorState = false;
        fetching = false;
        // Re-root on navigation: a fresh rootId arrives per-update from the
        // hook's data-root attr. Refresh the captured opts so ingest() reads
        // the CURRENT root, not the stale construction-time closure value.
        if (opts2 && opts2.rootId != null) opts.rootId = opts2.rootId;
        var oldPos = {};
        nodes.forEach(function (n) { oldPos[n.id] = { x: n.x, y: n.y }; });
        ingest(newNodes, newEdges, opts.rootId);
        if (Object.keys(oldPos).length) startMorph(oldPos);
        reheat(0.3);
      },
      fit: function () {
        fitInternal(true);
      },
      setError: function (on) {
        errorState = !!on;
        wake();
      },
      setFetching: function (on) {
        fetching = !!on;
        wake();
      },
      // Drive the graph from an external search/filter (the web finder's left
      // rail). `list` is the visible results — either plain doc-id strings or
      // `{ id, w }` objects where `w` ∈ (0..1] is the rank-derived weight (1 =
      // top hit). The graph dims everything else and scales each match's
      // emphasis by `w`. Pass `null` (or omit) to clear the filter and show the
      // full corpus undimmed. Idempotent and safe before/after data loads.
      setMatches: function (list) {
        if (list == null) {
          externalMatch = null;
        } else {
          var m = {};
          for (var i = 0; i < list.length; i++) {
            var it = list[i];
            if (it == null) continue;
            if (typeof it === "string") m[it] = 1;
            else if (it.id != null) m[it.id] = typeof it.w === "number" ? it.w : 1;
          }
          externalMatch = m;
        }
        applyExternalMatch();
        wake();
      },
      setHovered: function (docId) {
        // External hover bridge — the finder result list hovers a row and the
        // graph focuses the matching node with the SAME hop-cascade + corona as
        // a real canvas hover. Keyed by doc_id (== a finder hit's slug — the same
        // key the graph→list direction publishes). Does NOT echo through
        // opts.onNodeHover (the finder is the source here; echoing is redundant
        // and risks a feedback loop). No-op when it resolves to the current hover
        // (e.g. the user is already hovering that very node on the canvas).
        var nextId = null;
        if (docId != null) {
          for (var i = 0; i < nodes.length; i++) {
            if (!nodes[i].phantom && nodes[i].doc_id === docId) {
              nextId = nodes[i].id;
              break;
            }
          }
        }
        if (nextId === hoverId) return;
        hoverId = nextId;
        // Match the canvas-hover path: wake for the crossfade, never reheat the
        // sim — a list hover should focus the node, not stir the layout.
        wake();
      },
      // Re-skin to a new theme in place. The host reads the site's real theme
      // from document.documentElement.dataset.theme — which our "auto" never
      // sees, since it resolves via matchMedia ONLY — and pushes it here on
      // every toggle. Reassigns the closure `theme` the paint helpers read (same
      // resolution as construction), rebuilds the DOM chrome (legend/zoom/
      // search flip with the theme), then repaints; no destroy/recreate, so the
      // layout, camera, hover and filter state are all untouched.
      setTheme: function (next) {
        var choice = next || "auto";
        if (choice === "auto") {
          var pd = true;
          try {
            pd = !window.matchMedia("(prefers-color-scheme: light)").matches;
          } catch (e) {}
          theme = pd ? "dark" : "light";
        } else {
          theme = choice;
        }
        buildChrome();
        wake();
      },
      destroy: function () {
        destroyed = true;
        if (rafId) cancelAnimationFrame(rafId);
        rafId = null;
        canvas.removeEventListener("pointermove", onPointerMove);
        canvas.removeEventListener("pointerleave", onPointerLeave);
        canvas.removeEventListener("pointerdown", onPointerDown);
        canvas.removeEventListener("pointerup", onPointerUp);
        canvas.removeEventListener("pointercancel", onPointerUp);
        canvas.removeEventListener("wheel", onWheel);
        canvas.removeEventListener("focus", onCanvasFocus);
        window.removeEventListener("keydown", onKeyDown);
        window.removeEventListener("keyup", onKeyUp);
        if (ro) ro.disconnect();
        if (io) io.disconnect();
        if (vv) {
          vv.removeEventListener("resize", onVVChange);
          vv.removeEventListener("scroll", onVVChange);
        }
        if (reduceMQ && reduceMQ.removeEventListener) reduceMQ.removeEventListener("change", onReduceChange);
        if (forcedMQ && forcedMQ.removeEventListener) forcedMQ.removeEventListener("change", onForcedChange);
        if (announceTimer) clearTimeout(announceTimer);
        if (saveViewTimer) clearTimeout(saveViewTimer);
        try {
          if (canvas.parentNode) canvas.parentNode.removeChild(canvas);
          if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
          if (a11yRoot.parentNode) a11yRoot.parentNode.removeChild(a11yRoot);
          if (liveRegion.parentNode) liveRegion.parentNode.removeChild(liveRegion);
          if (tooltip.parentNode) tooltip.parentNode.removeChild(tooltip);
        } catch (e) {}
      }
    };
  }

  // ── shared canvas helpers (module scope) ──
  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }
  function roundRectCentered(ctx, cx, cy, w, h, r) {
    var x = cx - w / 2,
      y = cy - h / 2;
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  window.BarkparkGraphRenderer = BarkparkGraphRenderer;

  // ════════════════════════════════════════════ PHOENIX LIVEVIEW HOOK ══
  // Thin wrapper over the pure renderer. Reads data-* off #studio-graph,
  // parses in a try/catch (authored amber PARSE-ERROR, never silent []),
  // diffs on data-rev (the load-bearing guard), tears down on destroyed().
  window.BarkparkGraph = {
    mounted() {
      var canvas2d = true;
      try {
        var probe = document.createElement("canvas").getContext("2d");
        if (!probe) canvas2d = false;
      } catch (e) {
        canvas2d = false;
      }
      if (!canvas2d) {
        this.el.textContent = "graph unavailable";
        return;
      }

      this._rev = this.el.dataset.rev;
      var self = this;
      var parsed = this._parse();
      var rootId = this.el.dataset.root || null;

      this._renderer = window.BarkparkGraphRenderer(
        this.el,
        { nodes: parsed.nodes, edges: parsed.edges },
        {
          theme: "auto",
          rootId: rootId,
          // The HOST owns the query when it says so, and then drives this graph
          // through the `graph-matches` channel registered below. That
          // suppresses the renderer's own in-canvas search box, which otherwise
          // appears on any corpus past 30 nodes — /finder shipped BOTH for
          // months: a server-side FTS that never touched the canvas beside a
          // client-side substring filter that never touched the result list.
          // Absent the attr this is false, so Studio's GraphPane (the same hook
          // object) keeps its in-canvas box unchanged.
          externalSearch: this.el.dataset.externalSearch === "true",
          onNodeClick: function (n) {
            if (n && n.id) self.pushEvent("node-clicked", { id: n.id });
          }
        }
      );

      if (parsed.error) this._renderer.setError(true);
      // INITIAL-FETCH continuity: if the first paint has no nodes yet (the
      // server hasn't pushed the graph into data-nodes), show the breathing
      // fetch ring. The first updated() with real nodes calls update(), which
      // clears fetching and the ring brightens into the populated graph. This
      // makes the signature "kindled point becomes the root" opener REACHABLE
      // in production, not just in the harness.
      else if (!parsed.nodes || parsed.nodes.length === 0) {
        this._fetching = true;
        this._renderer.setFetching(true);
      }

      // Optional server push channel for incremental deltas. Reconcile to the
      // SAME rev source of truth as the data-rev attr path: stamp this._rev
      // from the payload so a subsequent identical attr-rev is correctly
      // deduped (no double-apply, no skip). Payload carries its own root.
      // EXTERNAL SEARCH -> GRAPH. A host that set `data-external-search` pushes
      // its weighted visible result set here on every query; `setMatches` dims
      // everything else and scales each match's emphasis by `w`. The payload's
      // `matches` is the whole contract: `null` = idle (clear the filter, full
      // corpus undimmed), `[]` = a query that matched nothing (everything
      // dims) — `setMatches` already reads those two apart. Safe before the
      // corpus lands: `ingest()` re-stamps the active match after every data
      // update, so a query typed during the async corpus derivation lights the
      // nodes the moment they arrive.
      this.handleEvent("graph-matches", function (payload) {
        if (!self._renderer || !payload) return;
        self._renderer.setMatches(payload.matches);
      });

      this.handleEvent("graph-update", function (payload) {
        if (!self._renderer || !payload) return;
        if (payload.rev != null) self._rev = String(payload.rev);
        self._renderer.update(payload.nodes, payload.edges, {
          rootId: payload.root != null ? String(payload.root) : self.el.dataset.root || null
        });
      });
    },

    updated() {
      if (!this._renderer) return;
      // THE LOAD-BEARING GUARD — navigation changes data-* on the same div.
      if (this.el.dataset.rev === this._rev) return;
      this._rev = this.el.dataset.rev;
      var parsed = this._parse();
      if (parsed.error) {
        this._renderer.setError(true);
        return;
      }
      // Re-root on navigation: pass the (possibly new) root id so the renderer
      // re-centers the gravitational sun on the destination doc, never the
      // stale construction-time root.
      this._renderer.update(parsed.nodes, parsed.edges, {
        rootId: this.el.dataset.root || null
      });
    },

    destroyed() {
      if (this._renderer) {
        this._renderer.destroy();
        this._renderer = null;
      }
    },

    // Parse data-nodes/data-edges. On failure -> authored PARSE-ERROR (amber)
    // + ONE console.error, NEVER the old silent JSON.parse -> [] swallow.
    _parse() {
      var nodes, edges;
      try {
        nodes = JSON.parse(this.el.dataset.nodes || "[]");
        edges = JSON.parse(this.el.dataset.edges || "[]");
      } catch (e) {
        console.error("[bp-graph] failed to parse graph data:", e);
        return { nodes: [], edges: [], error: true };
      }
      return { nodes: nodes, edges: edges, error: false };
    }
  };
})();
