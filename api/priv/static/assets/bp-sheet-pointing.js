// bp-sheet-pointing.js — pure pointing & prediction kernel for the Studio
// sheet grid (Sheets formula UX, wave-1 slice S2).
//
// The DOM-coupled point-mode wiring lives in bp-sheet-grid.js; THIS file is a
// side-effect-free companion: coordinate math (A1 ↔ (c,r)), the Excel
// Enter-mode phantom-reference cursor, the ghost range predictor, the function
// fuzzy matcher, and the ghost state reducer. Nothing here touches `document`,
// `window` events, or the LiveSocket — every function takes plain args (a grid
// is injected as a `getCell(c, r)` callback + integer `{cols, rows}` bounds)
// and returns data, so the whole surface is table-testable in node:vm with no
// browser (see api/assets/sheet-grid/__pointing.test.mjs).
//
// Loaded the same way as bp-sheet-grid.js (non-defer, after
// phoenix_live_view.js) so the hook can read `window.BarkparkSheetPointing`.
// The `module.exports` guard lets the pure harness require the shipped file.
(function (root) {
  "use strict";

  // ── coordinate helpers ─────────────────────────────────────────────────────
  // 1-based (c, r) throughout — column 1 = "A", row 1 = row "1" — matching the
  // 1-based grid the LiveComponent renders and the sparse A1 cell map.

  // Bijective base-26 column letters, byte-for-byte the recursion of
  // Geometry.col_letters/1 (api/lib/.../sheet_grid/geometry.ex): A..Z, then
  // AA, AB, …, so there is no "zero digit". `c` is a 1-based column index.
  function colLetters(c) {
    if (c <= 26) return String.fromCharCode(64 + c); // 65 = "A"
    return colLetters(Math.floor((c - 1) / 26)) + colLetters(((c - 1) % 26) + 1);
  }

  // Inverse of colLetters: "A" -> 1, "Z" -> 26, "AA" -> 27. Case-insensitive.
  // Anything that is not a string of 1+ ASCII letters (incl. "", null — which
  // String() would launder into the letters "null") → NaN, so callers fail
  // closed instead of receiving a falsy-but-numeric 0 or a garbage index.
  function colIndex(letters) {
    if (typeof letters !== "string" || letters.length === 0) return NaN;
    let n = 0;
    const s = letters.toUpperCase();
    for (let i = 0; i < s.length; i++) {
      const code = s.charCodeAt(i) - 64; // "A" -> 1
      if (code < 1 || code > 26) return NaN;
      n = n * 26 + code;
    }
    return n;
  }

  // "B3" -> {c:2, r:3}. Returns null on anything that is not a plain cell ref
  // (whole-col/row refs, ranges, garbage) so callers fail closed.
  function refToPos(ref) {
    const m = /^([A-Za-z]+)([0-9]+)$/.exec(String(ref).trim());
    if (!m) return null;
    const c = colIndex(m[1]);
    const r = parseInt(m[2], 10);
    if (!(c >= 1) || !(r >= 1)) return null;
    return { c: c, r: r };
  }

  // {c:2, r:3} -> "B3".
  function posToRef(pos) {
    return colLetters(pos.c) + pos.r;
  }

  // Normalized range text between two corners. Order-agnostic: a drag that ends
  // up-and-left of its anchor still yields top-left:bottom-right ("B3:B5", never
  // "B5:B3"). A single cell collapses to a bare ref ("B3").
  function rangeText(anchorPos, headPos) {
    const c1 = Math.min(anchorPos.c, headPos.c);
    const c2 = Math.max(anchorPos.c, headPos.c);
    const r1 = Math.min(anchorPos.r, headPos.r);
    const r2 = Math.max(anchorPos.r, headPos.r);
    const top = posToRef({ c: c1, r: r1 });
    if (c1 === c2 && r1 === r2) return top;
    return top + ":" + posToRef({ c: c2, r: r2 });
  }

  // Whole-column ref: "B:B" (single) or "B:D" (span), normalized low→high.
  function colRefText(c1, c2) {
    const a = Math.min(c1, c2);
    const b = Math.max(c1, c2);
    return colLetters(a) + ":" + colLetters(b);
  }

  // Whole-row ref: "3:3" or "3:7", normalized low→high.
  function rowRefText(r1, r2) {
    const a = Math.min(r1, r2);
    const b = Math.max(r1, r2);
    return a + ":" + b;
  }

  // ── occupancy + stepping primitives ────────────────────────────────────────

  var STEP = {
    up: { dc: 0, dr: -1 },
    down: { dc: 0, dr: 1 },
    left: { dc: -1, dr: 0 },
    right: { dc: 1, dr: 0 },
  };

  function advance(pos, step) {
    return { c: pos.c + step.dc, r: pos.r + step.dr };
  }

  function inBounds(pos, bounds) {
    return pos.c >= 1 && pos.c <= bounds.cols && pos.r >= 1 && pos.r <= bounds.rows;
  }

  function clamp(pos, bounds) {
    return {
      c: Math.min(Math.max(pos.c, 1), bounds.cols),
      r: Math.min(Math.max(pos.r, 1), bounds.rows),
    };
  }

  // "Occupied" = getCell returns a cell whose type is a real value (n/s/b).
  // A null return OR a {t:null} empty cell both read as empty, so this agrees
  // with the server's `occupied?` fill predicate (Geometry.edge_filled?/2).
  function occupied(getCell, c, r) {
    const cell = getCell(c, r);
    return !!cell && cell.t !== null && cell.t !== undefined;
  }

  // Excel Ctrl/Cmd+Arrow data-edge jump, a JS port of Geometry.data_edge/4 over
  // the injected occupancy callback. From an occupied cell with an occupied
  // neighbour → the last occupied cell of the run before the gap. From an empty
  // cell or a run edge → the next occupied cell in that direction, else the
  // grid bound. Result is always in-bounds.
  function dataEdge(getCell, pos, step, bounds) {
    const next = advance(pos, step);
    if (!inBounds(next, bounds)) return { c: pos.c, r: pos.r };
    if (occupied(getCell, pos.c, pos.r) && occupied(getCell, next.c, next.r)) {
      return edgeRun(getCell, next, step, bounds);
    }
    return edgeSeek(getCell, next, step, bounds);
  }

  // Walk a filled run to its last cell before the gap (or the grid edge).
  // Iterative on purpose: run/gap length is bounded only by the injected grid
  // bounds (six-figure row counts are legal), so recursion here could blow the
  // stack mid-keystroke.
  function edgeRun(getCell, pos, step, bounds) {
    let cur = pos;
    let next = advance(cur, step);
    while (inBounds(next, bounds) && occupied(getCell, next.c, next.r)) {
      cur = next;
      next = advance(cur, step);
    }
    return { c: cur.c, r: cur.r };
  }

  // Skip empties to the next filled cell; none before the edge → the edge.
  // Iterative for the same stack-safety reason as edgeRun.
  function edgeSeek(getCell, pos, step, bounds) {
    let cur = pos;
    while (!occupied(getCell, cur.c, cur.r)) {
      const next = advance(cur, step);
      if (!inBounds(next, bounds)) break;
      cur = next;
    }
    return { c: cur.c, r: cur.r };
  }

  // ── phantom reference cursor (Excel Enter-mode) ─────────────────────────────
  //
  // `state` = {anchor:{c,r}, head:{c,r}} | null. On the first arrow of a
  // session `state` is null and the phantom seeds at the active cell, supplied
  // as `opts.active` (defaults to A1 if absent so the function never throws).
  //
  //   plain arrow      → head AND anchor move one step (single-cell phantom)
  //   opts.shift       → only head moves (extends the range)
  //   opts.edge        → jump to the data edge (Ctrl/Cmd+Arrow); combines with
  //                      shift (Ctrl+Shift+Arrow extends to the edge)
  //
  // Everything clamps to 1..bounds. Returns {state, refText} where refText is
  // the normalized text of the current anchor→head range.
  function phantomStep(state, dir, opts, getCell, bounds) {
    opts = opts || {};
    var step = STEP[dir];
    if (!step) throw new Error("phantomStep: bad dir " + dir);

    var anchor, head;
    if (state && state.anchor && state.head) {
      anchor = { c: state.anchor.c, r: state.anchor.r };
      head = { c: state.head.c, r: state.head.r };
    } else {
      var seed = opts.active || { c: 1, r: 1 };
      anchor = { c: seed.c, r: seed.r };
      head = { c: seed.c, r: seed.r };
    }

    var target = opts.edge
      ? dataEdge(getCell, head, step, bounds)
      : clamp(advance(head, step), bounds);

    head = target;
    if (!opts.shift) anchor = { c: target.c, r: target.r };

    var next = { anchor: anchor, head: head };
    return { state: next, refText: rangeText(anchor, head) };
  }

  // ── ghost range prediction ──────────────────────────────────────────────────

  // Collect the contiguous run of numeric cells starting one step away from
  // `pos` in `step`, walking until a non-numeric (string/bool/empty) or the
  // grid edge stops it. Elements are ordered nearest-to-`pos` first.
  function numericRun(getCell, pos, step) {
    var run = [];
    var cur = advance(pos, step);
    while (cur.c >= 1 && cur.r >= 1) {
      var cell = getCell(cur.c, cur.r);
      if (!cell || cell.t !== "n") break;
      run.push({ c: cur.c, r: cur.r });
      cur = advance(cur, step);
    }
    return run;
  }

  // Predict the range a =SUM(-style aggregate most likely wants: scan UPWARD
  // from the cell directly above `pos` collecting the contiguous numeric run;
  // if it is ≥2 cells return its normalized text. Else scan LEFTWARD the same
  // way. Else null. This is the wish's screenshot case: numbers at B3/B4/B5 and
  // the caret in B6 → "B3:B5".
  function predictRange(getCell, pos) {
    var up = numericRun(getCell, pos, STEP.up);
    if (up.length >= 2) return rangeText(up[0], up[up.length - 1]);
    var left = numericRun(getCell, pos, STEP.left);
    if (left.length >= 2) return rangeText(left[0], left[left.length - 1]);
    return null;
  }

  // ── ghost gating ────────────────────────────────────────────────────────────

  // Charter decision #7 whitelist — the aggregates whose empty first arg earns
  // a ghost. AVERAGEIF-family etc. are deliberately excluded.
  var AGGREGATES = ["SUM", "AVERAGE", "COUNT", "COUNTA", "MIN", "MAX", "MEDIAN"];

  // The ghost fires only for a whitelisted function, at the FIRST argument
  // (argIndex 0), whose current text is empty. Any other position or a
  // non-empty arg means the user is steering — stay silent.
  function shouldOfferGhost(fnName, argIndex, argEmpty) {
    return (
      AGGREGATES.indexOf(String(fnName || "").toUpperCase()) >= 0 &&
      argIndex === 0 &&
      argEmpty === true
    );
  }

  // ── function fuzzy matcher ───────────────────────────────────────────────────

  // Up to 8 matches for the autocomplete dropdown: prefix matches first (in the
  // original vocabulary order, so a server-sorted list stays sorted), then
  // substring ("contains") matches. Case-insensitive. Empty query → [] (an
  // empty box shows nothing, never the whole 69-fn list).
  function fuzzyFns(query, names) {
    var q = String(query || "").toUpperCase();
    if (q === "" || !names) return [];
    var prefix = [];
    var contains = [];
    for (var i = 0; i < names.length; i++) {
      var up = String(names[i]).toUpperCase();
      var at = up.indexOf(q);
      if (at === 0) prefix.push(names[i]);
      else if (at > 0) contains.push(names[i]);
    }
    return prefix.concat(contains).slice(0, 8);
  }

  // ── ghost state reducer ──────────────────────────────────────────────────────

  // Pure reducer over {offered: text|null}. Encodes the invariant "the ghost
  // never steals a keystroke": only an explicit 'offer' shows a suggestion, only
  // an explicit 'accept' consumes it, and ANY other event ('key', 'click',
  // 'arrow', 'dismiss', …) silently clears the offer so the user's input wins.
  function ghostReduce(ghostState, event) {
    var state = ghostState || { offered: null };
    var type = event && event.type;
    if (type === "offer") {
      return { offered: event.text != null ? event.text : null };
    }
    if (type === "accept") {
      return { accepted: state.offered, offered: null };
    }
    return { offered: null };
  }

  // ── export ───────────────────────────────────────────────────────────────────

  var api = {
    colLetters: colLetters,
    colIndex: colIndex,
    refToPos: refToPos,
    posToRef: posToRef,
    rangeText: rangeText,
    colRefText: colRefText,
    rowRefText: rowRefText,
    phantomStep: phantomStep,
    predictRange: predictRange,
    AGGREGATES: AGGREGATES,
    shouldOfferGhost: shouldOfferGhost,
    fuzzyFns: fuzzyFns,
    ghostReduce: ghostReduce,
  };

  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (root) root.BarkparkSheetPointing = api;
})(typeof window !== "undefined" ? window : this);
