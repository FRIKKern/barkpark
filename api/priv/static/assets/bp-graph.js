// bp-graph.js — Northern Night constellation renderer for the Studio
// blast-radius pane. Self-contained vanilla Canvas2D + a hand-rolled
// velocity-Verlet force simulation. ZERO npm, ZERO network-fetched libs,
// ZERO font fetch (Golden Rule). Cytoscape is fully gutted.
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
// THE THESIS: emissive depth (luminance is the only depth language on dark),
// generous negative space, slow physics that says "complete, not loading."
// The root is pinned dead-center as the gravitational sun; dependents band
// into concentric BFS blast-rings so radial distance encodes impact rank.
(function () {
  "use strict";

  // ───────────────────────────────────────────────────────────── constants ──
  var ACCENT = "#9B8CFF"; // root halo / selection / hover corona / guides
  var ACCENT_RGB = [155, 140, 255];
  var A11Y_RING = "#60A5FA"; // keyboard-focus ring, kept DISTINCT from accent
  var SLATE = "#94A3B8"; // _unknown + phantom + ash mix target
  var AMBER = "#FBBF24"; // the only warm pixel — parse-error state

  var FONT_STACK =
    "Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', ui-sans-serif, system-ui, sans-serif";

  // OKLCH L~0.70 -> sRGB hex, hues >=25 apart. Capacity, not a mandate.
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
    _unknown: SLATE
  };

  // Mandatory non-color channel #1: a per-type glyph (WCAG 1.4.1).
  var TYPE_GLYPH = {
    post: "P",
    page: "G",
    paper: "R",
    task: "K",
    author: "A",
    category: "C",
    book: "B",
    asset: "M",
    mediaAsset: "M",
    sheet: "S",
    project: "J",
    "game-data": "D",
    _unknown: "·"
  };

  // Northern Night uses ROUND luminous glass orbs / cabochons for every node —
  // the Obsidian-faithful read. Shape is therefore NO LONGER a type channel;
  // the non-color WCAG channels are the per-type GLYPH (above) + per-type HUE.
  // Kept as an all-"circle" map so the legend / shapePath callers stay uniform
  // (and a future shape revival has one place to change). Phantoms still draw a
  // dashed ghost ring, handled inline in drawNode, not via this map.
  var TYPE_SHAPE = {
    post: "circle",
    page: "circle",
    paper: "circle",
    asset: "circle",
    mediaAsset: "circle",
    book: "circle",
    author: "circle",
    category: "circle",
    project: "circle",
    task: "circle",
    sheet: "circle",
    "game-data": "circle"
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
  function hslL(hex) {
    var c = hexToRgb(hex);
    var r = c[0] / 255,
      g = c[1] / 255,
      b = c[2] / 255;
    return (Math.max(r, g, b) + Math.min(r, g, b)) / 2;
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
    var demoteRun = 0,
      promoteRun = 0;

    var alpha = 1.0;
    var alphaTarget = 1.0;
    var alphaDecay = 0.008;
    var velocityDecay = 0.55;
    var alphaMin = 0.001;

    var R_RING = 0; // recomputed on layout = 0.22*min(W,H)
    var flowOn = !!opts.flow;
    // Full-color is the HERO state by default — the luminous focal hierarchy is
    // the wow moment, so the first impression must NOT be the desaturated one.
    // Ash (60% toward slate) is the opt-in RESTRAINT, flipped from the legend.
    var fullColor = opts.fullColor != null ? !!opts.fullColor : true;
    var nowT = 0;

    // ── eased camera scale (luxe wheel/button zoom) ──
    var camTargetScale = 1; // scale glides toward this; cursor world-point pinned
    var camZoomAnchor = null; // {wx, wy, px, py} kept fixed during the glide
    var camAnimating = false; // animateCam (fit) in flight

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
    function saveView() {
      try {
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
    function loadView() {
      try {
        var raw = localStorage.getItem(storageKey());
        if (!raw) return null;
        return JSON.parse(raw);
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

      // node radii: clamp(8+5*sqrt(degree),8,32); sqrt-compressed.
      var n = nextNodes.length;
      var degs = nextNodes.filter(function (x) { return !x.phantom; }).map(function (x) { return x.degree; });
      var dMax = degs.length ? Math.max.apply(null, degs) : 0;
      var dMin = degs.length ? Math.min.apply(null, degs) : 0;
      nextNodes.forEach(function (node) {
        if (node.phantom) {
          node.r = 7;
        } else if (node.id === newRootId) {
          node.r = 0; // set after base formula below
        } else if (dMax === dMin) {
          node.r = 14; // guard: all degrees equal -> neutral mid-size
        } else {
          var base;
          if (n === 1) base = 28;
          else if (n <= 3) base = 22;
          else if (n <= 10) base = 16;
          else base = clamp(8 + 5 * Math.sqrt(node.degree), 8, 32);
          node.r = base;
        }
      });
      // root gets x1.4 of its formula size
      var rootNode = nextById[newRootId];
      if (rootNode) {
        var rb;
        if (n === 1) rb = 28;
        else rb = clamp(8 + 5 * Math.sqrt(rootNode.degree), 8, 32);
        // 1.55 (was 1.4) restores clear primacy: at the sqrt cap a 1.4 root is
        // only marginally larger than a high-degree depth-1 hub.
        rootNode.r = rb * 1.55;
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
      nodes.forEach(function (node) {
        var op = oldPos[node.id];
        if (op && hadData) {
          node.x = op.x;
          node.y = op.y;
          node._enterAt = 0; // PERSIST never replays entrance
          node.alpha = 1;
          node.scaleK = 1;
        } else {
          var depth = Math.max(1, depthMap[node.id] || 1);
          var ang = seedIdx * GOLDEN;
          seedIdx++;
          var rad = depth * R_RING + (Math.random() - 0.5) * 20;
          node.x = cx + rad * Math.cos(ang);
          node.y = cy + rad * Math.sin(ang);
          node.alpha = 0;
          node.scaleK = 0;
          // Stronger depth stagger (55ms/ring, 320ms cap) turns the root→rim
          // fill into a readable outward ripple — "impact propagating outward"
          // — while staying under ~0.6s total. Pairs with the easeOutBack settle.
          node._enterAt = perfNow() + Math.min(depthMap[node.id] * 55, 320);
        }
      });

      buildA11yTree();
      recomputeTopDegree(); // at-rest label allow-set (root + top-6 by degree)

      if (sparseMode) {
        layoutSparse();
      } else if (reduced) {
        settleSync();
      } else {
        // Pre-warm is now CAPPED by node count (clamp(round(4000/n),8,120)) so
        // a large graph warms few steps off the good seed; tiny graphs still
        // warm fully. This keeps the synchronous main-thread cost bounded.
        var warm = hadData
          ? clamp(Math.round(2000 / Math.max(1, n)), 6, 60)
          : clamp(Math.round(4000 / Math.max(1, n)), 8, 120);
        for (var w2 = 0; w2 < warm; w2++) tick(16.67, true);
        alpha = hadData ? 0.3 : 1.0;
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
          // now full-color, so a saved `false` must still restore to ash)
          if (saved.full != null) fullColor = !!saved.full;
          if (saved.flow != null) flowOn = saved.flow;
        } else {
          // Frame the SEEDED positions now (so first paint isn't off-screen),
          // then arm the one-shot auto-fit to reframe the SETTLED clump once the
          // sim cools below the settle threshold. Sparse layouts are already
          // exact, so they don't need the post-settle reframe.
          fitInternal(false);
          _autoFitDone = sparseMode || reduced ? true : false;
          _userMovedCam = false;
        }
      }
      buildChrome();
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

    // ── synchronous settle (reduced-motion) ──
    function settleSync() {
      var start = perfNow();
      var iters = 0;
      alpha = 1.0;
      R_RING = 0.22 * Math.min(W, H);
      while (alpha > alphaMin && perfNow() - start < 40 && iters < 500) {
        tick(16.67, true);
        iters++;
      }
      applyAngularFan();
      // apply blast-ring banding firmly
      for (var b = 0; b < 40; b++) tick(16.67, true);
      nodes.forEach(function (nd) {
        nd.alpha = nd.phantom ? 1 : 1;
        nd.scaleK = 1;
        nd._enterAt = 0;
      });
      edges.forEach(function (e) {
        e.alpha = 1;
      });
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
      var repel = n < 12 ? -350 : -250;

      // (2) link springs
      for (var i = 0; i < edges.length; i++) {
        var e = edges[i];
        if (e.selfLoop) continue;
        var a = e.src,
          b = e.dst;
        var dx = b.x - a.x,
          dy = b.y - a.y;
        var dist = Math.sqrt(dx * dx + dy * dy) || 0.0001;
        var rest = 130 * (0.7 + 0.3 * e.wBand);
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

      // (4) soft collision (only while warm AND only for smaller graphs — it is
      // a second O(n^2) loop and purely cosmetic anti-overlap; above ~150 nodes
      // the repulsion + ring banding already keep nodes apart, so we drop it to
      // halve the per-tick physics bill).
      if (alpha > 0.1 && n <= 150) {
        for (var c = 0; c < n; c++) {
          var nc = nodes[c];
          for (var d = c + 1; d < n; d++) {
            var nd = nodes[d];
            var cdx = nc.x - nd.x,
              cdy = nc.y - nd.y;
            var cl = Math.sqrt(cdx * cdx + cdy * cdy) || 0.0001;
            var minD = nc.r + nd.r + 4;
            if (cl < minD) {
              var push = ((minD - cl) / cl) * 0.7 * 0.5;
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
        ng.vx += (cx - ng.x) * 0.012;
        ng.vy += (cy - ng.y) * 0.012;
      }

      // (6) BLAST-RING radial banding (hero) — after center gravity.
      // F_ring = -k_ring*(|r|-depth*R)*r_hat, alpha-scaled, decays below 0.05.
      if (!sparseMode && root && R_RING > 0) {
        var ringScale = Math.max(alpha, 0.03);
        if (alpha >= 0.05) {
          for (var rr = 0; rr < n; rr++) {
            var nr = nodes[rr];
            if (nr.id === rootId) continue;
            var rdx = nr.x - root.x,
              rdy = nr.y - root.y;
            var rlen = Math.sqrt(rdx * rdx + rdy * rdy) || 0.0001;
            var depth = depthMap[nr.id] || 1;
            var target = depth * R_RING;
            var fr = -0.04 * (rlen - target) * ringScale;
            nr.vx += (rdx / rlen) * fr;
            nr.vy += (rdy / rlen) * fr;
          }
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
        nz.x += nz.vx;
        nz.y += nz.vy;
      }
    }

    // ════════════════════════════════════════════════════════════════ DRAW ══
    function present() {
      // present ring radii for guide-circles
      var depths = {};
      nodes.forEach(function (n) {
        if (n.phantom || n.id === rootId) return;
        var d = depthMap[n.id] || 1;
        depths[d] = true;
      });
      return depths;
    }

    // bgGradient is cached — it only changes on resize / theme / a meaningful
    // shift of its anchor. The anchor is PINNED TO THE ROOT screen position
    // (the gravitational sun), not the wandering centroid, so the void feels
    // anchored and still as the sim cools (no swimming vignette).
    var _bgGrad = null,
      _bgKey = "";
    function bgGradient() {
      var root = rootId ? byId[rootId] : null;
      var ax = root ? root.x * cam.scale + cam.tx : W / 2;
      var ay = root ? root.y * cam.scale + cam.ty : H / 2;
      // quantize the anchor so sub-pixel drift doesn't rebuild every frame
      var key =
        theme + "|" + W + "x" + H + "|" + Math.round(ax / 24) + "," + Math.round(ay / 24);
      if (_bgGrad && key === _bgKey) return _bgGrad;
      var rr = 0.7 * Math.max(W, H);
      var g = ctx.createRadialGradient(ax, ay, 0, ax, ay, rr);
      if (theme === "light") {
        g.addColorStop(0, "#F4F4F8");
        g.addColorStop(1, "#E8EDF8");
      } else {
        // Cool-blue center cast + near-black edge: a darker floor raises the
        // node-to-ground luminance ratio (every glow reads brighter for free),
        // and the cool center makes the warm amber/orange/rose node hues sing
        // instead of muddying against a near-same-hue purple ground. The 0.22
        // stop (≈ first blast-ring fraction) carves a subtly brighter clearing
        // FROM the root so the void feels authored, not incidental.
        g.addColorStop(0, "#0D1018");
        g.addColorStop(0.22, "#0A0C13");
        g.addColorStop(1, "#050609");
      }
      _bgGrad = g;
      _bgKey = key;
      return g;
    }

    function worldToScreen(x, y) {
      return [x * cam.scale + cam.tx, y * cam.scale + cam.ty];
    }

    // hover constellation alpha targets
    function computeAlphaTargets() {
      if (hoverId == null) {
        nodes.forEach(function (n) {
          n.alphaTarget = 1;
          n.frosted = false;
        });
        edges.forEach(function (e) {
          e.alphaTarget = 1;
        });
        return;
      }
      var neigh = adj[hoverId] || {};
      var focusNode = focusIdx >= 0 && a11yOrder[focusIdx] ? a11yOrder[focusIdx] : null;
      nodes.forEach(function (n) {
        if (focusNode && n.id === focusNode.id) {
          // keyboard focus has parity with hover: always lit, never frosted
          n.alphaTarget = 1;
          n.frosted = false;
        } else if (n.id === hoverId) {
          n.alphaTarget = 1;
          n.frosted = false;
        } else if (neigh[n.id] && !n.phantom) {
          n.alphaTarget = 0.85;
          n.frosted = false;
        } else if (neigh[n.id] && n.phantom) {
          n.alphaTarget = 0.08; // phantoms join frosted set
          n.frosted = true;
        } else {
          n.alphaTarget = 0.08;
          n.frosted = true;
        }
      });
      edges.forEach(function (e) {
        if (e.srcId === hoverId || e.dstId === hoverId) e.alphaTarget = 1;
        else e.alphaTarget = 0.04;
      });
    }

    // _lerpDirty: count of channels still settling. lerpAlphas maintains it so
    // the keep-alive check (isFocusLerping) is O(1) instead of O(n+e) — exactly
    // when we most want to be cheap (deciding whether to park).
    var _lerpDirty = 0;
    function lerpAlphas(dt) {
      var kin = kStep(0.18, dt);
      var kout = kStep(0.1, dt);
      var dirty = 0;
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var k = n.alphaTarget > n.alpha ? kin : kout;
        n.alpha += (n.alphaTarget - n.alpha) * k;
        n.scaleK += (n.scaleTarget - n.scaleK) * kin;
        if (Math.abs(n.alpha - n.alphaTarget) > 0.01) dirty++;
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

    // Entrance has TWO decoupled channels so opacity LAGS spatial arrival
    // (the deliberate luxe fade): scaleK on easeOutBack over ~280ms, alpha on
    // a slightly-longer, slightly-delayed easeOutCubic so the orb fades in
    // AFTER it has scaled into place. Returns {scale, alpha} progress, and
    // clears _enterAt only once BOTH channels have completed.
    function entranceProgress(node, now) {
      if (node._enterAt === 0) return { scale: 1, alpha: 1, done: true };
      var ts = (now - node._enterAt) / 280; // scale window
      var ta = (now - node._enterAt - 60) / 360; // alpha: +60ms delay, 360ms
      var scaleP = ts < 0 ? 0 : ts >= 1 ? 1 : ts;
      var alphaP = ta < 0 ? 0 : ta >= 1 ? 1 : ta;
      var done = scaleP >= 1 && alphaP >= 1;
      if (done) node._enterAt = 0;
      return { scale: scaleP, alpha: alphaP, done: done };
    }

    function draw(now) {
      var t = now;
      nowT = now;

      // full-canvas clear in device space
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.fillStyle = bgGradient();
      ctx.fillRect(0, 0, W, H);

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

      // guide circles (blast boundary) — under edges, gated tier>=1
      if (!sparseMode && glowTier <= 1 && !forced) {
        drawGuideCircles();
      }

      // entrance ramp — scale (easeOutBack) leads, alpha (easeOutCubic) lags
      nodes.forEach(function (n) {
        if (n._enterAt) {
          var ep = entranceProgress(n, now);
          n.scaleK = easeOutBack(ep.scale);
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

    function drawGuideCircles() {
      var root = byId[rootId];
      if (!root) return;
      var depths = present();
      var rs = worldToScreen(root.x, root.y);
      var fadeIn = clamp((perfNow() - mountTime - 600) / 600, 0, 1);
      ctx.save();
      ctx.strokeStyle = rgba(ACCENT, 0.06 * fadeIn);
      ctx.lineWidth = 1;
      for (var d in depths) {
        var r = parseInt(d, 10) * R_RING * cam.scale;
        ctx.beginPath();
        ctx.arc(rs[0], rs[1], r, 0, Math.PI * 2);
        ctx.stroke();
      }
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

    function edgeGeom(e) {
      var a = e.src,
        b = e.dst;
      var p0 = worldToScreen(a.x, a.y);
      var p2 = worldToScreen(b.x, b.y);
      var dx = p2[0] - p0[0],
        dy = p2[1] - p0[1];
      var len = Math.sqrt(dx * dx + dy * dy) || 0.0001;
      // perpendicular control offset
      var heavy = e.wBand > 0.6;
      var offFrac = heavy ? 0.08 : 0.18;
      var off = Math.min(offFrac * len, 60);
      // sign: alternate by parallel index AND angular sector off root
      var sign = e.parallelIndex % 2 === 0 ? 1 : -1;
      if (rootId && (e.srcId === rootId || e.dstId === rootId)) {
        var other = e.srcId === rootId ? e.dst : e.src;
        var ang = Math.atan2(other.y - byId[rootId].y, other.x - byId[rootId].x);
        var sector = Math.floor(((ang + Math.PI) / (Math.PI * 2)) * 8);
        sign = sector % 2 === 0 ? 1 : -1;
      }
      var mx = (p0[0] + p2[0]) / 2,
        my = (p0[1] + p2[1]) / 2;
      var nx = -dy / len,
        ny = dx / len;
      var c = [mx + nx * off * sign, my + ny * off * sign];
      return { p0: p0, p2: p2, c: c, len: len };
    }

    function bezierAt(p0, c, p2, t) {
      var u = 1 - t;
      return [
        u * u * p0[0] + 2 * u * t * c[0] + t * t * p2[0],
        u * u * p0[1] + 2 * u * t * c[1] + t * t * p2[1]
      ];
    }
    function bezierTangent(p0, c, p2, t) {
      return [
        2 * (1 - t) * (c[0] - p0[0]) + 2 * t * (p2[0] - c[0]),
        2 * (1 - t) * (c[1] - p0[1]) + 2 * t * (p2[1] - c[1])
      ];
    }

    // Kind is pre-attentive WITHOUT zoom or flow via a distinct DASH signature
    // per kind (pattern survives where low-alpha hue does not) PLUS a raised
    // resting alpha floor so backlink/plugin_source don't vanish on the near-
    // black bed. reference solid · backlink dotted · plugin_source dash-dot.
    function edgeTier(kind) {
      if (kind === "backlink") return { s: 0.26, t: 0.12, dash: [1, 4] };
      if (kind === "plugin_source") return { s: 0.22, t: 0.1, dash: [5, 4, 1, 4] };
      return { s: 0.32, t: 0.14, dash: null };
    }

    function drawEdge(e, now) {
      var g = edgeGeom(e);
      var tier = edgeTier(e.kind);
      var srcHex = nodeFill(e.src);
      var dstHex = nodeFill(e.dst);

      var sAlpha = (theme === "light" ? 0.20 : tier.s) * e.alpha;
      var tAlpha = (theme === "light" ? 0.35 : tier.t) * e.alpha;

      ctx.save();
      if (forced) {
        ctx.strokeStyle = "CanvasText";
      } else {
        var grad = ctx.createLinearGradient(g.p0[0], g.p0[1], g.p2[0], g.p2[1]);
        grad.addColorStop(0, rgba(srcHex, sAlpha));
        grad.addColorStop(1, rgba(dstHex, tAlpha));
        ctx.strokeStyle = grad;
      }
      if (e.phantom) {
        ctx.setLineDash([4, 4]);
        ctx.strokeStyle = rgba(SLATE, 0.45 * e.alpha);
        ctx.lineWidth = 1.5;
      } else {
        if (tier.dash && !forced) ctx.setLineDash(tier.dash);
        var lw = clamp(0.8 + 0.5 * e.wBand, 0.8, 3.5);
        if (e.srcId === hoverId || e.dstId === hoverId) lw *= 1.5;
        // Floor the ON-SCREEN width at ~0.75px so structure never vanishes at
        // overview scale (a node cloud with no visible connections defeats the
        // tool's reason to exist).
        ctx.lineWidth = Math.max(0.75, lw * cam.scale * 0.6 + lw * 0.4);
      }
      ctx.beginPath();
      ctx.moveTo(g.p0[0], g.p0[1]);
      ctx.quadraticCurveTo(g.c[0], g.c[1], g.p2[0], g.p2[1]);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.restore();

      // DIRECTION at all zooms. The arrowhead is the crisp cue when zoomed in
      // (scale>0.5); below that a mid-edge chevron carries direction so the
      // fit-view is never left with ZERO direction cues.
      if (!e.phantom) {
        if (cam.scale > 0.5) {
          drawArrowhead(g, e, dstHex, tAlpha);
        } else if (e.alpha > 0.2) {
          drawMidChevron(g, e, dstHex);
        }
      }

      // flow particles
      if (
        flowOn &&
        !e.phantom &&
        glowTier <= 1 &&
        cam.scale > 0.35 &&
        e.alpha > 0.5 &&
        !reduced
      ) {
        drawFlowParticles(e, g, now, srcHex);
      } else if (reduced && flowOn && !e.phantom) {
        drawStaticFlowMarkers(e, g, srcHex);
      }
    }

    function drawArrowhead(g, e, hex, baseA) {
      var t = 0.92;
      var tip = bezierAt(g.p0, g.c, g.p2, t);
      var tan = bezierTangent(g.p0, g.c, g.p2, t);
      var tl = Math.sqrt(tan[0] * tan[0] + tan[1] * tan[1]) || 0.0001;
      var ux = tan[0] / tl,
        uy = tan[1] / tl;
      // pull tip inward by node radius + 2
      var rr = (e.dst.r + 2) * cam.scale;
      var tx = tip[0] - ux * rr,
        ty = tip[1] - uy * rr;
      var barb = 8;
      var ang = (22 * Math.PI) / 180;
      var aa = baseA / (theme === "light" ? 0.35 : 0.12) * 0.65;
      ctx.save();
      ctx.fillStyle = forced ? "CanvasText" : rgba(hex, clamp(aa, 0, 0.65) * e.alpha);
      ctx.beginPath();
      ctx.moveTo(tx, ty);
      ctx.lineTo(
        tx - ux * barb * Math.cos(ang) + uy * barb * Math.sin(ang),
        ty - uy * barb * Math.cos(ang) - ux * barb * Math.sin(ang)
      );
      ctx.lineTo(
        tx - ux * barb * Math.cos(ang) - uy * barb * Math.sin(ang),
        ty - uy * barb * Math.cos(ang) + ux * barb * Math.sin(ang)
      );
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    }

    // A small chevron at the curve midpoint pointing toward the target — the
    // direction channel that survives at overview scale (<=0.5) where the
    // node-anchored arrowhead is suppressed.
    function drawMidChevron(g, e, hex) {
      var mid = bezierAt(g.p0, g.c, g.p2, 0.52);
      var tan = bezierTangent(g.p0, g.c, g.p2, 0.52);
      var tl = Math.sqrt(tan[0] * tan[0] + tan[1] * tan[1]) || 0.0001;
      var ux = tan[0] / tl,
        uy = tan[1] / tl;
      var barb = 4.5;
      var ang = (28 * Math.PI) / 180;
      var aa = clamp(0.5 * e.alpha, 0, 0.6);
      ctx.save();
      ctx.strokeStyle = forced ? "CanvasText" : rgba(hex, aa);
      ctx.lineWidth = 1.2;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(
        mid[0] - ux * barb * Math.cos(ang) + uy * barb * Math.sin(ang),
        mid[1] - uy * barb * Math.cos(ang) - ux * barb * Math.sin(ang)
      );
      ctx.lineTo(mid[0], mid[1]);
      ctx.lineTo(
        mid[0] - ux * barb * Math.cos(ang) - uy * barb * Math.sin(ang),
        mid[1] - uy * barb * Math.cos(ang) + ux * barb * Math.sin(ang)
      );
      ctx.stroke();
      ctx.restore();
    }

    function drawFlowParticles(e, g, now, srcHex) {
      var period = (e.kind === "backlink" || e.kind === "plugin_source" ? 4500 * 1.33 : 4500);
      var hex = shiftL(srcHex, 0.15);
      var count = e.wBand > 0.6 ? 3 : e.wBand > 0.3 ? 2 : 1;
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      for (var i = 0; i < count; i++) {
        var phase = (e.phaseSeed + (i * period) / count);
        var tt = (((now - phase) % period) + period) % period / period;
        var pos = bezierAt(g.p0, g.c, g.p2, tt);
        var grad = ctx.createRadialGradient(pos[0], pos[1], 0, pos[0], pos[1], 3.2);
        grad.addColorStop(0, rgba(hex, 0.9 * e.alpha));
        grad.addColorStop(1, rgba(hex, 0));
        ctx.fillStyle = grad;
        ctx.beginPath();
        ctx.arc(pos[0], pos[1], 1.6, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    }

    function drawStaticFlowMarkers(e, g, srcHex) {
      var hex = shiftL(srcHex, 0.15);
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      [0.3, 0.55, 0.82].forEach(function (tt, i) {
        var pos = bezierAt(g.p0, g.c, g.p2, tt);
        ctx.fillStyle = rgba(hex, 0.7 * e.alpha);
        ctx.beginPath();
        ctx.arc(pos[0], pos[1], i === 2 ? 2.2 : 1.6, 0, Math.PI * 2);
        ctx.fill();
      });
      ctx.restore();
    }

    function drawSelfLoop(e) {
      var a = e.src;
      var p = worldToScreen(a.x, a.y);
      var r = a.r * 0.9 * cam.scale;
      var ox = p[0] + a.r * cam.scale,
        oy = p[1] - a.r * cam.scale;
      ctx.save();
      ctx.strokeStyle = rgba(nodeFill(a), 0.4 * e.alpha);
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      ctx.arc(ox, oy, r, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // ── NODE FILL (ash default, full-color toggle) ──
    function nodeFill(node) {
      if (node.phantom) return SLATE;
      var hex = TYPE_HEX[node.type] || SLATE;
      if (theme === "light") {
        return shiftL(hex, -0.22); // L0.70 -> ~0.48, un-ashed
      }
      if (fullColor) return hex;
      // ash: mix 60% toward slate
      return mixHex(hex, SLATE, 0.6);
    }

    function shapePath(cx, cy, r, shape) {
      ctx.beginPath();
      if (shape === "rounded") {
        var rr = r * 1.6;
        roundRectCentered(ctx, cx, cy, rr, rr, r * 0.35);
      } else if (shape === "hex") {
        for (var i = 0; i < 6; i++) {
          var ang = (Math.PI / 3) * i - Math.PI / 2;
          var x = cx + r * Math.cos(ang),
            y = cy + r * Math.sin(ang);
          if (i === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        ctx.closePath();
      } else {
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
      }
    }

    function drawNode(node, now, frosted) {
      if (node.alpha < 0.02) return;
      var p = worldToScreen(node.x, node.y);
      var r = node.r * node.scaleK * cam.scale;
      if (r < 0.5) return;
      var hex = nodeFill(node);
      var isRoot = node.id === rootId;
      var shape = node.phantom ? "dashed" : TYPE_SHAPE[node.type] || "circle";

      // ── PHANTOM: dashed, zero glow ──
      if (node.phantom) {
        ctx.save();
        ctx.globalAlpha = node.alpha;
        ctx.setLineDash([4, 4]);
        ctx.fillStyle = "rgba(148,163,184,0.12)";
        ctx.strokeStyle = "rgba(148,163,184,0.45)";
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
        ctx.setLineDash([]);
        ctx.restore();
        return;
      }

      // hover corona BEFORE node (gradient ring, not shadowBlur). Intensity is
      // sprung via hoverCoronaK so it LEAPS in (snappy) and GLIDES out (luxe)
      // rather than popping binary — the marquee asymmetry of the direction.
      if (!frosted && hoverCoronaK > 0.004 && hoverId != null &&
          (node.id === hoverId || (adj[hoverId] && adj[hoverId][node.id]))) {
        var coronaA = (node.id === hoverId ? 0.22 : 0.13) * hoverCoronaK;
        var cg = ctx.createRadialGradient(p[0], p[1], r * 0.8, p[0], p[1], r * 2.4);
        cg.addColorStop(0, rgba(ACCENT, coronaA));
        cg.addColorStop(0.5, rgba(ACCENT, coronaA * 0.55));
        cg.addColorStop(1, rgba(ACCENT, 0));
        ctx.save();
        ctx.fillStyle = cg;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r * 2.4, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }

      // selection-ring pulse (snappy click acknowledgement) — ring expands
      // outward and fades as selectPulse decays 1->0.
      if (!frosted && selectPulse > 0 && node.id === selectId) {
        // Both channels drive off one eased phase. Radius expands with a
        // decelerating ease (4→16); opacity uses the OPPOSITE curve (ease-in
        // quad) so the ring holds bright, then drops fast — a "release" rather
        // than a constant-velocity "dissolve" (linear fades read as cheap).
        var sp = easeOutCubic(1 - selectPulse);
        var ringR = r + (4 + 12 * sp) * cam.scale;
        ctx.save();
        ctx.globalAlpha = (1 - sp) * (1 - sp);
        ctx.strokeStyle = forced ? "CanvasText" : ACCENT;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(p[0], p[1], ringR, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      // ── FROSTED (dimmed context under hover): PASS-1 halo SOLE ──
      // The depth-of-field eases in WITH the dim (frost alpha tracks the lerped
      // node.alpha, normalized) so the dimmed field GLIDES to frost instead of
      // popping in one frame. Sprite blit, no shadowBlur.
      if (frosted) {
        if (theme !== "light" && glowTier <= 2 && !forced) {
          var frostA = 0.08 * clamp(node.alpha / 0.45, 0, 1);
          blitGlow(shiftL(hex, -0.01), p[0], p[1], (r + 1) * 1.9, frostA);
        } else {
          // light/forced: faint flat outline (forced keeps a CanvasText stroke
          // so dimmed nodes stay VISIBLE — Canvas-on-Canvas would erase them).
          ctx.save();
          ctx.globalAlpha = 0.18 * clamp(node.alpha / 0.45, 0, 1) + 0.04;
          if (forced) {
            ctx.strokeStyle = "GrayText";
            ctx.lineWidth = 1.25;
            shapePath(p[0], p[1], r, shape);
            ctx.stroke();
          } else {
            ctx.fillStyle = hex;
            shapePath(p[0], p[1], r, shape);
            ctx.fill();
          }
          ctx.restore();
        }
        return;
      }

      var depth = depthMap[node.id] || 0;
      // base luminance by ring (impact rank made luminance)
      // Steeper 0.14/ring falloff with a 0.42 floor: the 1.05 base keeps
      // depth-1 essentially full-bright while pushing rings 3+ visibly dimmer,
      // so radial distance AND luminance both encode blast rank — the two
      // channels reinforce instead of luminance being a near-no-op.
      var ringAlpha = isRoot ? 1 : clamp(1.05 - 0.14 * (depth - 1), 0.42, 1.0);

      if (forced) {
        drawNodeForced(node, p, r, shape);
        return;
      }

      if (theme === "light") {
        drawNodeLight(node, p, r, shape, hex);
      } else {
        drawNodeDark(node, p, r, shape, hex, isRoot, depth, ringAlpha, now);
      }
    }

    // ── glow-sprite cache ──
    // Canvas shadowBlur is one of the most expensive 2D ops (a full gaussian
    // convolution, scaling with device-pixel area). Using it per-node per-frame
    // under 'lighter' is the single biggest GPU cost. Instead we bake a soft
    // radial bloom into an offscreen sprite ONCE per (color-bucket) and
    // drawImage it per node — the spec's own T2 sprite-cache, promoted to the
    // DEFAULT for every non-root halo at all tiers. shadowBlur is reserved for
    // the ONE root node (1/frame is fine).
    var _glowSprites = {};
    function glowSprite(hex) {
      var key = hex;
      if (_glowSprites[key]) return _glowSprites[key];
      var S = 64; // sprite is sampled and scaled per node
      var off = document.createElement("canvas");
      off.width = S;
      off.height = S;
      var c = off.getContext("2d");
      var g = c.createRadialGradient(S / 2, S / 2, 0, S / 2, S / 2, S / 2);
      var rgb = hexToRgb(hex);
      // Chromatic bloom: a hot, lightened core bleeds to the saturated hue at
      // the edge (how real emissive light scatters). A flat-hue radial under
      // 'lighter' reads as a hard CG disc; this 4-stop curve gives every
      // satellite a luminous orb with a long bloom tail. Cache key stays `hex`.
      var coreRgb = hexToRgb(shiftL(hex, 0.18));
      g.addColorStop(0, "rgba(" + coreRgb[0] + "," + coreRgb[1] + "," + coreRgb[2] + ",1)");
      g.addColorStop(0.22, "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ",0.70)");
      g.addColorStop(0.55, "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ",0.22)");
      g.addColorStop(1, "rgba(" + rgb[0] + "," + rgb[1] + "," + rgb[2] + ",0)");
      c.fillStyle = g;
      c.fillRect(0, 0, S, S);
      _glowSprites[key] = off;
      return off;
    }
    function blitGlow(hex, x, y, radius, alpha) {
      if (alpha <= 0.001 || radius <= 0) return;
      var spr = glowSprite(hex);
      var d = radius * 2;
      ctx.save();
      ctx.globalCompositeOperation = "lighter";
      ctx.globalAlpha = clamp(alpha, 0, 1);
      ctx.drawImage(spr, x - radius, y - radius, d, d);
      ctx.restore();
    }

    function drawNodeDark(node, p, r, shape, hex, isRoot, depth, ringAlpha, now) {
      var a = node.alpha * ringAlpha;
      var haloBias = depth === 1 ? 0.06 : 0;
      // Hoisted breath: the root halo AND its concentric blast rings exhale on
      // the SAME sine so the gravitational pulse is one coherent motion rather
      // than a pulsing core inside two dead circles. Reduced-motion → 0 (today's
      // exact rest values), preserving the accessibility guarantee verbatim.
      var breath = reduced ? 0 : Math.sin(now * 0.0028);

      if (glowTier <= 1) {
        // The breathing sine MODULATES halo intensity — the signature
        // "alive-at-rest" move. Under reduced-motion the sine collapses to its
        // mid-rest value (0) so frozen frames land on the DESIGNED rest
        // luminance, not a random phase.
        if (isRoot) {
          // The root is a CLEAR focal anchor, NOT a blast lamp. The old huge
          // bright disc (blur 32 @ ~0.67α over r+4) washed adjacent depth-1
          // orbs to white. Its primacy now rides on SIZE (1.55x) + the thin
          // accent rings below — the glow is deliberately tight and gentle so
          // neighbors stay legible. Still the only perpetually-breathing node.
          var haloA = 0.06 + 0.035 * breath;
          // tight outer bloom — radius pulled in (r+2, blur 16) and peak alpha
          // roughly halved so the corona hugs the orb instead of flooding out.
          ctx.save();
          ctx.globalCompositeOperation = "lighter";
          ctx.globalAlpha = (0.26 + haloA) * node.alpha;
          ctx.shadowColor = ACCENT;
          ctx.shadowBlur = 16;
          ctx.fillStyle = ACCENT;
          shapePath(p[0], p[1], r + 2, shape);
          ctx.fill();
          ctx.shadowBlur = 0;
          ctx.shadowColor = "transparent";
          ctx.restore();
          // hot core pass — a slightly-brighter heart so it still reads as the
          // star at the center, but contained (blur 10, lower alpha).
          ctx.save();
          ctx.globalCompositeOperation = "lighter";
          ctx.globalAlpha = 0.3 * node.alpha;
          ctx.shadowColor = shiftL(ACCENT, 0.28);
          ctx.shadowBlur = 10;
          ctx.fillStyle = shiftL(ACCENT, 0.3);
          shapePath(p[0], p[1], r * 0.9, shape);
          ctx.fill();
          ctx.shadowBlur = 0;
          ctx.shadowColor = "transparent";
          ctx.restore();
        } else {
          // Satellites: cached glow SPRITE (no shadowBlur). Per-node STABLE
          // breathing phase (seeded once, not from live x — dragging must not
          // jump the pulse). The clamp ceiling now exceeds the floor so
          // haloBias (depth-1 boost) survives — depth-1 visibly out-glows deep
          // rings (impact-rank-as-luminance).
          var sbreath = reduced ? 0 : Math.sin(now * 0.0018 + node.phaseSeed);
          var shaloA = 0.12 + 0.06 * sbreath;
          var outerA = clamp(0.18 + haloBias, 0.1, 0.3) * a + shaloA * 0.5 * a;
          // Orb bloom: a wide soft halo (the luminous corona around the glass
          // bead) under a tighter inner glow. Two blits read as a real emissive
          // orb rather than a flat lit disc.
          blitGlow(hex, p[0], p[1], (r + 5) * 2.2, outerA * 0.85);
          blitGlow(hex, p[0], p[1], r * 1.35, 0.5 * a);
        }
      } else if (glowTier === 2) {
        // sprite-tier: single soft bloom blit (no shadowBlur)
        blitGlow(hex, p[0], p[1], r * 1.5, 0.5 * a);
      }

      // PASS 3 — glass-orb / cabochon core ('source-over'). A bright emissive
      // off-center core bleeds through the saturated type hue to a darkened,
      // slightly-transparent edge: the read of a luminous bead, not a flat disc.
      ctx.save();
      ctx.globalAlpha = node.alpha;
      var coreHex = isRoot ? ACCENT : hex;
      var grad = ctx.createRadialGradient(
        p[0] - 0.32 * r,
        p[1] - 0.34 * r,
        r * 0.06,
        p[0],
        p[1],
        r
      );
      // hot emissive heart -> mid type-color -> darkened, fading edge
      grad.addColorStop(0, shiftL(coreHex, 0.34));
      grad.addColorStop(0.32, shiftL(coreHex, 0.1));
      grad.addColorStop(0.7, coreHex);
      grad.addColorStop(1, rgba(shiftL(coreHex, -0.3), 0.82));
      ctx.fillStyle = grad;
      shapePath(p[0], p[1], r, shape);
      ctx.fill();
      // soft rim (kept thin so the orb reads as glass, not a chip)
      ctx.lineWidth = 1.25;
      ctx.strokeStyle = rgba(shiftL(coreHex, 0.08), 0.85);
      ctx.globalAlpha = node.alpha * 0.85;
      shapePath(p[0], p[1], r, shape);
      ctx.stroke();
      // specular glint — a tiny soft highlight at the upper-left, the cabochon
      // tell. Skipped on the root (its hot-core pass already supplies one) and
      // on tiny on-screen orbs where it would just be noise.
      if (!isRoot && r >= 6) {
        ctx.globalAlpha = node.alpha * 0.5;
        var sg = ctx.createRadialGradient(
          p[0] - 0.34 * r, p[1] - 0.38 * r, 0,
          p[0] - 0.34 * r, p[1] - 0.38 * r, r * 0.5
        );
        sg.addColorStop(0, "rgba(255,255,255,0.9)");
        sg.addColorStop(1, "rgba(255,255,255,0)");
        ctx.fillStyle = sg;
        ctx.beginPath();
        ctx.arc(p[0] - 0.34 * r, p[1] - 0.38 * r, r * 0.5, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();

      // status badge (in_progress quarter-ring)
      if (node.type === "task" && node.status === "in_progress") {
        ctx.save();
        ctx.globalAlpha = node.alpha;
        ctx.strokeStyle = ACCENT;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + 2, -Math.PI / 2, 0);
        ctx.stroke();
        ctx.restore();
      }

      // root concentric blast rings — breathe in sympathy with the sun (same
      // hoisted breath phase), alpha and radius exhaling together.
      if (isRoot) {
        ctx.save();
        ctx.globalAlpha = node.alpha;
        // thin crisp accent ring hugging the orb — the primary "this is the
        // center" tell now that the bloom is tamed. A defined edge reads as
        // focal far more cheaply (and without washing neighbors) than brightness.
        ctx.strokeStyle = rgba(shiftL(ACCENT, 0.12), 0.85);
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + 2.5 * cam.scale, 0, Math.PI * 2);
        ctx.stroke();
        // outer concentric blast rings — faint, breathing in sympathy.
        ctx.strokeStyle = rgba(ACCENT, 0.16 + 0.05 * breath);
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + (9 + 1.5 * breath) * cam.scale, 0, Math.PI * 2);
        ctx.stroke();
        ctx.strokeStyle = rgba(ACCENT, 0.06 + 0.03 * breath);
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + (17 + 3 * breath) * cam.scale, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      drawGlyph(node, p, r, hex, isRoot ? 1 : ringAlpha);
    }

    function drawNodeLight(node, p, r, shape, hex) {
      // Light-mode luxe tell: a soft accent ground-glow under the ROOT so light
      // mode has ONE signature identity (its answer to dark's breathing sun)
      // rather than reading as a flat corporate graph.
      if (node.id === rootId && !forced) {
        ctx.save();
        ctx.globalCompositeOperation = "multiply";
        ctx.globalAlpha = 0.5 * node.alpha;
        var rg = ctx.createRadialGradient(p[0], p[1], r * 0.6, p[0], p[1], r * 3);
        rg.addColorStop(0, rgba(ACCENT, 0.35));
        rg.addColorStop(1, rgba(ACCENT, 0));
        ctx.fillStyle = rg;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r * 3, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      // light depth: ground shadow + inner-top highlight + rim-darken
      ctx.save();
      // ground shadow ellipse
      ctx.globalAlpha = node.alpha;
      ctx.save();
      ctx.translate(p[0], p[1] + 0.35 * r);
      ctx.scale(1.1, 1);
      var sg = ctx.createRadialGradient(0, 0, 0, 0, 0, r);
      sg.addColorStop(0, "rgba(15,23,42,0.10)");
      sg.addColorStop(1, "rgba(15,23,42,0)");
      ctx.fillStyle = sg;
      ctx.beginPath();
      ctx.arc(0, 0, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();

      // disc with inner-top highlight
      var grad = ctx.createRadialGradient(
        p[0] - 0.3 * r,
        p[1] - 0.4 * r,
        r * 0.1,
        p[0],
        p[1],
        r
      );
      grad.addColorStop(0, shiftL(hex, 0.22));
      grad.addColorStop(1, hex);
      ctx.fillStyle = grad;
      shapePath(p[0], p[1], r, shape);
      ctx.fill();
      ctx.lineWidth = 1;
      ctx.strokeStyle = shiftL(hex, -0.12);
      shapePath(p[0], p[1], r, shape);
      ctx.stroke();
      ctx.restore();

      if (node.id === rootId) {
        ctx.save();
        ctx.globalAlpha = node.alpha;
        ctx.strokeStyle = rgba(ACCENT, 0.4);
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(p[0], p[1], r + 8 * cam.scale, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }
      drawGlyph(node, p, r, hex);
    }

    function drawNodeForced(node, p, r, shape) {
      ctx.save();
      ctx.globalAlpha = node.alpha;
      ctx.fillStyle = "Canvas";
      ctx.strokeStyle = "CanvasText";
      ctx.lineWidth = node.id === rootId ? 3 : 1.5;
      shapePath(p[0], p[1], r, shape);
      ctx.fill();
      ctx.stroke();
      ctx.restore();
      drawGlyph(node, p, r, "#000");
    }

    function drawGlyph(node, p, r, hex, aMul) {
      // In forced-colors the glyph is the ONLY type channel (color is gone), so
      // it must NEVER be gated by zoom — drop the scale cutoff when forced and
      // keep a minimum readable size. Non-forced keeps the LOD cutoff.
      if (!forced && cam.scale < 0.5) return;
      var glyph = node.phantom ? "" : TYPE_GLYPH[node.type] || "·";
      if (!glyph) return;
      var lightLabel = forced ? "CanvasText" : hslL(hex) > 0.75 ? "rgba(15,17,23,0.85)" : "rgba(240,242,248,0.85)";
      var fontPx = forced ? Math.max(10, Math.min(13, r * 0.9)) : 10;
      ctx.save();
      ctx.font = "700 " + fontPx + "px " + FONT_STACK;
      // The lone cap wants NO kerning so it centers true on its rounded x.
      if ("fontKerning" in ctx) ctx.fontKerning = "none";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillStyle = lightLabel;
      // Glyph alpha tracks the disc's ring luminance (aMul = ringAlpha) so a
      // deep-ring glyph isn't MORE opaque than its disc — consistent with the
      // impact-rank-as-luminance story.
      ctx.globalAlpha = forced ? 1 : node.alpha * (aMul == null ? 1 : aMul);
      ctx.fillText(glyph, Math.round(p[0]), Math.round(p[1]));
      ctx.restore();
    }

    // Top-degree allow-set for at-rest labels, recomputed only when the node
    // set changes (cheap: a single sort of the real nodes by degree). At rest
    // we label ONLY the root + these few, then collision-skip the rest, so a
    // settled constellation reads clean instead of an overlapping word-pile.
    var REST_TOP_N = 6;
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

    // ── LABELS (screen-space, aggressive LOD + greedy declutter) ──
    function drawLabels(now) {
      var s = cam.scale;
      if (s < 0.4 && hoverId == null) return; // overview: labels off
      var focusNode = focusIdx >= 0 && a11yOrder[focusIdx] ? a11yOrder[focusIdx] : null;
      // ── pass 1: collect eligible labels with their LOD fade alpha ──
      var cand = [];
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        var isFocused = focusNode && node.id === focusNode.id;
        if (node.alpha < 0.3 && !isFocused) continue;
        var isRoot = node.id === rootId;
        var isHov = isFocused || node.id === hoverId || (hoverId != null && adj[hoverId] && adj[hoverId][node.id]);
        var deg = node.degree;
        // LOD policy:
        //   • root + hovered + hovered's 1-hop neighbors  → ALWAYS (win collision)
        //   • at REST (s < 1.4): only the top-6 highest-degree nodes are even
        //     candidates — everything else stays silent so the field is calm.
        //   • zoomed in (s >= 1.4): progressively reveal more by degree as you
        //     push further in, highest-degree first, each fading in over a band.
        var show = false;
        var labelA = 1;
        if (isRoot || isHov) {
          show = true;
        } else if (_topDegIds[node.id]) {
          // top-degree tier: visible from a near-overview, fades in by s>=0.46.
          show = true;
          labelA = clamp((s - 0.34) / 0.12, 0, 1);
        } else if (s >= 1.4) {
          // progressive reveal: each 0.35 of extra zoom past 1.4x lowers the
          // degree bar by ~2, so deeper zoom surfaces more (lower-degree) labels.
          var degBar = Math.max(1, 8 - Math.floor((s - 1.4) / 0.35) * 2);
          if (deg >= degBar) {
            show = true;
            labelA = clamp((s - 1.4) / 0.18, 0, 1);
          }
        }
        if (!show || labelA <= 0.001) continue;
        if (node.phantom && s < 1.2 && !isHov) continue;
        // importance: root > hovered/adjacent > top-degree > by degree. High
        // importance wins contested space in the greedy declutter below.
        var prio = isRoot ? 3 : isHov ? 2 : _topDegIds[node.id] ? 1 + deg / 1000 : deg / 1000;
        cand.push({ node: node, isRoot: isRoot, isHov: isHov, labelA: labelA, prio: prio });
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
        var p = worldToScreen(nd.x, nd.y);
        var r = nd.r * cam.scale;
        var x = Math.round(p[0]);
        var y = Math.round(p[1] + r + (it.isRoot ? 16 : 11));
        var fontPx = it.isRoot ? 15 : nd.phantom ? 9 : nd.degree >= 4 ? 11 : 10;
        var label = nd.phantom ? nd.broken_id || nd.title : nd.title;
        var halfW = Math.min(String(label).length * fontPx * 0.3, 55);
        var box = [x - halfW, y - 7, x + halfW, y + 7];
        if (!it.isRoot && !it.isHov) {
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

    function drawLabel(node, isRoot, isHov, labelA) {
      if (labelA == null) labelA = 1;
      var p = worldToScreen(node.x, node.y);
      var r = node.r * cam.scale;
      var font, color, track;
      if (isRoot) {
        // 15px/650 reads as the sun, not a slightly-bigger satellite — a clear
        // 1.36x ratio over the 11px tier (was a too-timid 1.18x at 13px).
        font = "650 15px " + FONT_STACK;
        color = "#FFFFFF";
        track = "0.005em";
      } else if (node.phantom) {
        font = "italic 400 9px " + FONT_STACK;
        color = rgba(SLATE, 0.55);
        track = "0.02em";
      } else if (node.degree >= 4) {
        font = "500 11px " + FONT_STACK;
        color = "rgba(226,232,240,0.92)";
        track = "0.012em";
      } else {
        font = "400 10px " + FONT_STACK;
        color = "rgba(226,232,240,0.92)";
        track = "0.012em";
      }
      // bright node -> dark label
      var hex = nodeFill(node);
      if (!isRoot && !node.phantom && hslL(hex) > 0.75) color = "rgba(15,17,23,0.95)";
      if (theme === "light") color = node.phantom ? rgba(SLATE, 0.7) : "rgba(15,23,42,0.85)";
      if (forced) color = "CanvasText";

      var label = node.phantom ? node.broken_id || node.title : node.title;
      var maxW = isHov ? 9999 : 110;
      var text = isHov ? label : truncate(label, font, maxW, track);

      // Scale the label gap with the disc so the big root doesn't crowd its
      // title (16px under the sun, 11px for satellites).
      var x = Math.round(p[0]);
      var y = Math.round(p[1] + r + (isRoot ? 16 : 11));
      ctx.save();
      ctx.font = font;
      // Optical tracking loosens as size drops so Inter stops looking cramped
      // at 9-11px. Same value the truncate measured with.
      if ("letterSpacing" in ctx) ctx.letterSpacing = track;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      // Fade across LOD boundaries (labelA) on top of the node's own alpha.
      ctx.globalAlpha = node.alpha * labelA;
      // halo (replaces 2px outline) — widened for the root so its title reads
      // clean against the bright disc.
      ctx.lineWidth = isRoot ? (dpr >= 2 ? 7 : 6) : dpr >= 2 ? 5 : 4;
      ctx.lineJoin = "round";
      ctx.strokeStyle = forced
        ? "Canvas"
        : theme === "light"
        ? "rgba(248,250,252,0.92)"
        : "rgba(13,15,20,0.85)";
      ctx.strokeText(text, x, y);
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
      // feel (vs. a generic popover). Title text stays high-contrast white.
      var hue = node.phantom ? SLATE : TYPE_HEX[node.type] || SLATE;
      html +=
        "<div style='font-weight:600;color:#fff;margin-bottom:4px;padding-bottom:3px;" +
        "border-bottom:1.5px solid " + rgba(hue, 0.55) + "'>" + esc(title) + "</div>";
      if (node.phantom) {
        var line = node.via
          ? esc(node.broken_id) + " · via " + esc(node.via)
          : esc(node.broken_id) + " · broken reference";
        html += "<div style='color:" + SLATE + "'>" + line + "</div>";
      } else {
        html += "<div style='color:" + rgba(ACCENT, 0.9) + "'>" + esc(node.type) + "</div>";
        var cc = Object.keys(adj[node.id] || {}).length;
        html += "<div style='color:rgba(226,232,240,0.7);margin-top:2px'>" + cc + " connection" + (cc === 1 ? "" : "s") + "</div>";
      }
      tooltip.innerHTML = html;
      tooltip.style.background = theme === "light" ? "rgba(255,255,255,0.92)" : "rgba(19,20,27,0.92)";
      tooltip.style.border = "1px solid rgba(255,255,255,0.08)";
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
      return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
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

      draw(now);

      // decide whether to keep running. The root breathes perpetually (the
      // "alive at rest" signature), so once data is present we keep the loop
      // alive UNLESS reduced-motion is on (then the breathing sine is frozen
      // to its rest value and we may park). coronaK lerps are also kept alive.
      var stillFocus = isFocusLerping();
      var alive = !reduced && (alpha > 0 || alphaTarget > alphaMin);
      // The root breathes perpetually when data is present; the fetch ring
      // breathes while awaiting data. Both keep the loop alive UNLESS reduced.
      var hasBreathingNode =
        !reduced && !errorState && (nodes.length > 0 || fetching);
      var interacting =
        dragging ||
        Math.abs(panVX) > 0.1 ||
        Math.abs(panVY) > 0.1 ||
        morph ||
        camAnimating ||
        Math.abs(cam.scale - camTargetScale) > 0.0005;
      var keepGoing =
        alive || interacting || stillFocus || hasBreathingNode || hoverCoronaK > 0.001 || selectPulse > 0;
      // Off-screen: park UNLESS mid-interaction/morph (those must complete).
      if (!visible && !interacting && !stillFocus) keepGoing = false;
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
      alphaTarget = target;
      if (alpha < target) alpha = target;
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
          var w = clientToWorld(ev.clientX, ev.clientY);
          dragNode.x = w[0];
          dragNode.y = w[1];
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
        if (hit && !hit.phantom) reheat(0.25);
        else wake();
      }
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
        reheat(0.3);
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
      saveView();
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
      var scale = Math.min((W - inset * 2) / bw, (H - inset * 2) / bh, 4.0);
      scale = clamp(scale, 0.08, 4.0);
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
          "background:rgba(15,17,23,0.55);border:1px solid rgba(255,255,255,0.07);" +
          "color:rgba(255,255,255,0.75);font-size:16px;line-height:1;backdrop-filter:blur(14px);outline:none;" +
          "transition:background .14s ease, border-color .14s ease, transform .08s ease, box-shadow .14s ease;";
        b.addEventListener("click", pair[1]);
        // live pointer states — the difference between "functional" and
        // "crafted" chrome (no new paint cost).
        b.addEventListener("pointerenter", function () {
          b.style.background = "rgba(24,27,36,0.72)";
          b.style.borderColor = "rgba(255,255,255,0.14)";
          b.style.color = "rgba(255,255,255,0.95)";
        });
        b.addEventListener("pointerleave", function () {
          b.style.background = "rgba(15,17,23,0.55)";
          b.style.borderColor = "rgba(255,255,255,0.07)";
          b.style.color = "rgba(255,255,255,0.75)";
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

      // legend (always; collapses past 8 types)
      var presentTypes = {};
      nodes.forEach(function (nd) {
        if (!nd.phantom) presentTypes[nd.type] = true;
      });
      var typeList = Object.keys(presentTypes);
      var legend = mkPanel("position:absolute;left:12px;top:12px;padding:9px 11px;max-width:200px;");
      var title = document.createElement("div");
      title.style.cssText = "font-size:10px;letter-spacing:0.04em;text-transform:uppercase;color:rgba(255,255,255,0.45);margin-bottom:6px;";
      title.textContent = "Types";
      legend.appendChild(title);
      typeList.slice(0, 8).forEach(function (ty) {
        var row = document.createElement("div");
        row.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;font-size:11px;color:rgba(255,255,255,0.65);letter-spacing:0.03em;";
        // Shape-correct swatch: the canvas treats shape (circle|rounded|hex) as
        // a MANDATORY non-color channel (WCAG 1.4.1), so the legend must match —
        // a 'task' hexagon on canvas was rendering as a circle in the key.
        var sh = TYPE_SHAPE[ty] || "circle";
        var swStyle = "width:12px;height:12px;flex:0 0 auto;background:" +
          (fullColor ? TYPE_HEX[ty] : mixHex(TYPE_HEX[ty] || SLATE, SLATE, 0.6)) + ";";
        if (sh === "hex") {
          swStyle += "border-radius:0;clip-path:polygon(25% 5%,75% 5%,100% 50%,75% 95%,25% 95%,0% 50%);";
        } else if (sh === "rounded") {
          swStyle += "border-radius:3px;";
        } else {
          swStyle += "border-radius:50%;";
        }
        row.innerHTML =
          "<span style='" + swStyle + "'></span>" +
          "<b style='font-weight:700;color:rgba(255,255,255,0.5)'>" +
          (TYPE_GLYPH[ty] || "·") +
          "</b> " +
          ty;
        legend.appendChild(row);
      });
      // phantom ghost entry
      var prow = document.createElement("div");
      prow.style.cssText = "display:flex;align-items:center;gap:7px;margin:3px 0;font-size:11px;color:rgba(255,255,255,0.5);font-style:italic;";
      prow.innerHTML = "<span style='width:10px;height:10px;border-radius:50%;border:1px dashed rgba(148,163,184,0.6)'></span> broken ref";
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

      // search (medium+; ghost)
      if (n > 30) {
        var sw = document.createElement("input");
        sw.placeholder = "Search…";
        sw.style.cssText =
          "position:absolute;right:16px;top:12px;width:160px;pointer-events:auto;" +
          "padding:6px 10px;border-radius:8px;background:rgba(15,17,23,0.55);" +
          "border:1px solid rgba(255,255,255,0.07);color:#fff;font-size:12px;backdrop-filter:blur(14px);font-family:" + FONT_STACK + ";";
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
      var d = document.createElement("div");
      d.style.cssText =
        "background:rgba(15,17,23,0.55);backdrop-filter:blur(14px) saturate(180%);" +
        "border:1px solid rgba(255,255,255,0.07);border-radius:10px;pointer-events:auto;" + extra;
      return d;
    }
    // Pill toggle with a state dot (on = accent-lit, off = dim) — reads as
    // premium chrome rather than a debug control with a checkmark-in-label.
    function mkToggle(label, on, fn) {
      var b = document.createElement("button");
      b.setAttribute("role", "switch");
      b.setAttribute("aria-checked", on ? "true" : "false");
      b.style.cssText =
        "margin-top:8px;display:flex;align-items:center;gap:7px;width:100%;padding:5px 9px;" +
        "border-radius:7px;cursor:pointer;text-align:left;" +
        "background:rgba(40,44,58," + (on ? "0.7" : "0.4") + ");" +
        "border:1px solid rgba(255,255,255," + (on ? "0.12" : "0.06") + ");" +
        "color:rgba(255,255,255," + (on ? "0.85" : "0.6") + ");" +
        "font-size:11px;pointer-events:auto;font-family:" + FONT_STACK + ";" +
        "transition:background .14s ease, border-color .14s ease, transform .08s ease, box-shadow .14s ease;";
      var dot = document.createElement("span");
      dot.style.cssText =
        "width:7px;height:7px;border-radius:50%;flex:0 0 auto;" +
        (on
          ? "background:" + ACCENT + ";box-shadow:0 0 6px " + rgba(ACCENT, 0.8) + ";"
          : "background:rgba(255,255,255,0.25);");
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
      destroy: function () {
        destroyed = true;
        if (rafId) cancelAnimationFrame(rafId);
        rafId = null;
        canvas.removeEventListener("pointermove", onPointerMove);
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
