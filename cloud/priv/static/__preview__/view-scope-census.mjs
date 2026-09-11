// view-scope-census.mjs — WHICH OF THIS GUARD'S ELEMENT WALKS ARE DOCUMENT-WIDE,
// and therefore able to measure a view the person is not looking at.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (cch-w24-followup-no-leg-drives-a-hash-nav)
// ─────────────────────────────────────────────────────────────────────────────
//  `nav()` in overflow-guard.mjs drives every cell with `Page.navigate` to a URL
//  whose QUERY STRING changes (`?scen=…&theme=…`), so every leg in that file
//  enters its scenario by a FULL DOCUMENT LOAD: one view has ever been painted,
//  every other `section.view` is the empty shell index.html shipped, and a
//  document-wide `document.querySelectorAll('.some-class')` is accidentally
//  identical to a walk scoped to the visible view.
//
//  A PERSON DOES NOT ARRIVE THAT WAY. They land on `#overview` and click
//  through to `#fleet`. app.js routes by setting `section.hidden` (see the
//  `applyRoute` block: `sec.hidden = detail || v !== r.view`) and NEVER clears a
//  view's innerHTML, so every screen they have already visited is still in the
//  document — painted, laid out at `display:none`, and matched by every
//  document-wide selector.
//
//  That difference is the only reason the W15 fleet leg's `.fleet-row` walk was
//  invisible for nine waves: measured through a hash navigation on `mixed-fleet`
//  it sees 8 rows document-wide against 5 in the view, because `#view-overview`
//  paints its own activity rows under the same class. cch-w24-s5 scoped THAT
//  walk. This module is the CLASS: it enumerates every walk in the guard so the
//  question can be asked of all of them at once, mechanically, and so the answer
//  cannot rot into a paragraph somebody wrote once.
//
//  THE DIVISION OF LABOUR, and it is deliberate:
//    · THIS FILE is pure and browserless. It says WHERE TO LOOK — every
//      `document.querySelector(All)?(…)` call in the guard, the leg that owns
//      it, and the SHAPE of its selector.
//    · THE BROWSER says WHAT IS THERE. Only a live DOM, driven the way a person
//      drives it, can answer "does a hidden view hold a match for this
//      selector" — the answer depends on what app.js paints, not on the
//      selector's spelling. The `W35-hash-nav-hidden-view-residue` leg of
//      overflow-guard.mjs asks it, per selector, per view, and refuses on drift
//      against RESIDUE_REGISTER below.
//  A classification here is a HYPOTHESIS about a selector. It is never evidence
//  that a leg is clean.
//
//  NON-LITERAL CALL SITES ARE NOT DROPPED. A walk whose selector is built from a
//  variable or a `${…}` interpolation cannot be classified from the bytes, and a
//  census that silently omitted them would report a smaller, cleaner file than
//  the one that exists. They are enumerated as `kind:"unresolved"`, counted, and
//  printed by the leg. An absence is never caught by inspection.
// ─────────────────────────────────────────────────────────────────────────────

// Every `document.querySelector(` / `document.querySelectorAll(` in the guard,
// literal or not. `[(]` in the source comments above is written bracketed on
// purpose; these regexes are the real ones.
const CALL_RE = /document\.querySelector(All)?\(/g;

// A selector literal as the guard writes them: single- or double-quoted, no
// escapes, no interpolation. A template literal containing `${` is deliberately
// NOT matched — that is the `unresolved` class.
const LITERAL_ARG_RE = /^\s*(?:'([^'\\$`]*)'|"([^"\\$`]*)")\s*\)/;

// The scoped idiom every converted walk uses: the visible view, computed in the
// same evaluate that walks it.
export const LIVE_VIEW_SELECTOR = "section.view:not([hidden])";

// Chrome that lives OUTSIDE `main.content` and therefore outside every
// `section.view`: no amount of routing can leave a second copy behind, because
// there is only ever one. Verified against index.html by `verifyGlobalChrome`.
export const GLOBAL_CHROME = ["header.topbar", "main.content", "html", "body"];

/**
 * Classify ONE selector literal by shape.
 *
 *   "live-view"     — the walk is scoped to `section.view:not([hidden])`.
 *   "global-chrome" — the walk targets page chrome outside every view.
 *   "id-anchored"   — the selector's first compound is an id. An id is one host,
 *                     so a SECOND view cannot hold a match unless the id is
 *                     duplicated — which is a defect in its own right and one
 *                     several legs deliberately count (`#cred-submit`).
 *   "document-wide" — everything else: a bare class, an element, an attribute.
 *                     Any view, hidden or not, that paints a match is measured.
 */
export function classifySelector(sel) {
  if (typeof sel !== "string") return "unresolved";
  const s = sel.trim();
  if (s === "") return "document-wide";
  if (s.includes(LIVE_VIEW_SELECTOR)) return "live-view";
  // A comma list is only as anchored as its WEAKEST arm.
  const arms = s.split(",").map((a) => a.trim()).filter(Boolean);
  if (arms.length > 1) {
    const kinds = arms.map(classifySelector);
    if (kinds.includes("document-wide")) return "document-wide";
    if (kinds.includes("global-chrome")) return "global-chrome";
    return kinds[0];
  }
  const first = arms[0].split(/[\s>+~]+/)[0];
  if (GLOBAL_CHROME.includes(first)) return "global-chrome";
  if (first.startsWith("#")) return "id-anchored";
  return "document-wide";
}

/**
 * The census. Returns one entry per `document.querySelector(All)?(` call site in
 * `source`, in file order:
 *   { line, leg, all, kind, selector }
 * `leg` is the defect id whose `if (requested.includes("…"))` block the call sits
 * in, or "(prologue)" for the module-level helpers above `main()`.
 * `kind` is `classifySelector(selector)`, or "unresolved" when the argument is
 * not a bare literal.
 */
export function censusWalks(source) {
  const lines = String(source).split("\n");
  const out = [];
  let leg = "(prologue)";
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const legMark = line.match(/requested\.includes\("([^"]+)"\)/);
    if (legMark) leg = legMark[1];
    // A LINE-COMMENT IS PROSE, NOT A WALK. This guard's header quotes its own
    // selectors constantly (the `…` placeholder at the `shown` note is one), and
    // counting them would put the census's own documentation in the census.
    // Only whole-line comments are skipped: a trailing `// …` after real code
    // cannot fake a call site, and skipping those lines would HIDE one.
    if (/^\s*(\/\/|\*|\/\*)/.test(line)) continue;
    CALL_RE.lastIndex = 0;
    let m;
    while ((m = CALL_RE.exec(line))) {
      const rest = line.slice(m.index + m[0].length);
      const lit = rest.match(LITERAL_ARG_RE);
      const selector = lit ? (lit[1] !== undefined ? lit[1] : lit[2]) : null;
      out.push({
        line: i + 1,
        leg,
        all: !!m[1],
        selector,
        kind: selector === null ? "unresolved" : classifySelector(selector),
      });
    }
  }
  return out;
}

/** The distinct document-wide selectors, with the legs and lines that walk them. */
export function documentWideSelectors(walks) {
  const by = new Map();
  for (const w of walks) {
    if (w.kind !== "document-wide") continue;
    if (!by.has(w.selector)) by.set(w.selector, { selector: w.selector, legs: new Set(), lines: [], all: false });
    const e = by.get(w.selector);
    e.legs.add(w.leg);
    e.lines.push(w.line);
    if (w.all) e.all = true;
  }
  return [...by.values()]
    .map((e) => ({ selector: e.selector, legs: [...e.legs].sort(), lines: e.lines, all: e.all }))
    .sort((a, b) => (a.selector < b.selector ? -1 : 1));
}

/** A one-line-per-row summary, counted by kind. Used by the leg's printout. */
export function censusTally(walks) {
  const t = { total: walks.length, "document-wide": 0, "id-anchored": 0, "live-view": 0, "global-chrome": 0, unresolved: 0 };
  for (const w of walks) t[w.kind]++;
  return t;
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE RESIDUE REGISTER — a PREDICATE'S record, not a hand-kept list
// ─────────────────────────────────────────────────────────────────────────────
//  Populated by MEASUREMENT: the leg drives a person's path (`#overview`, then
//  a hash navigation to every routable screen) and, for each document-wide
//  selector above, counts matches inside the visible view against matches inside
//  HIDDEN `section.view` containers. A selector with a non-zero hidden count is
//  EXPOSED: the moment any leg reaches it through a hash navigation rather than
//  a full load, it measures a screen nobody is looking at.
//
//  The register is a RATCHET IN BOTH DIRECTIONS (a ratchet that only reds when
//  the world gets worse is half an instrument):
//    · an EXPOSED selector missing from the register  → the guard refuses,
//      naming it. Somebody added a walk, or app.js started painting a class in a
//      second view.
//    · a registered selector that measures CLEAN      → the guard refuses,
//      naming it. The exposure was fixed, or the tour stopped reaching the view
//      that produced it, and a register listing a condition nobody can reproduce
//      is a register that certifies nothing.
//  `views` is the hidden view ids the residue was found in, so the refusal can
//  say WHERE, and so a residue that moved house is not read as the same finding.
//
//  MEASURED 2026-09-11 on `mixed-fleet` at 1000px, after a 12-hop tour of every
//  routable screen plus both drill-downs (overflow-guard.mjs's
//  `W35-hash-nav-hidden-view-residue` leg; its output is the only thing that may
//  edit this list). 23 of 57 distinct document-wide selectors match inside a
//  hidden view.
//
//  `status: "latent"` IS THE HONEST WORD AND IT IS NOT "harmless". Every leg in
//  overflow-guard.mjs enters its scenario through `nav()`, i.e. a full document
//  load, so NONE of these 23 is measuring a hidden view today. Each one is a
//  walk whose answer DEPENDS ON THE ENTRY PATH: the first cell that reaches its
//  screen by hash navigation — a person's path, and the path a future leg will
//  reach for the moment it needs to drive a click-through — measures the rows
//  listed here as if they were on the screen. Registering an exposure records
//  it; it does not discharge it. The remedy per walk is cch-w24-s5's: compute
//  `section.view:not([hidden])` and walk THAT, which is exactly what makes the
//  W15 leg's count identical under both entries.
//
//  Two views did NOT paint during the measured tour (`view-overview` never grew
//  past the shell it was loaded on, `view-operator` is gated shut on this
//  scenario), so their columns are UNMEASURED rather than clean; the leg prints
//  that line every run rather than letting a hole read as a zero.
export const RESIDUE_REGISTER = [
  { selector: ".attention-row", views: ["view-overview"], legs: "GR109-attention-row-dead-rule, W20-attention-name-column", status: "latent" },
  { selector: ".attention-row .attention-acts", views: ["view-overview"], legs: "GR109-attention-row-dead-rule", status: "latent" },
  { selector: ".attention-row .attention-name", views: ["view-overview"], legs: "W20-attention-name-column", status: "latent" },
  { selector: ".attention-row .status-pill-detail", views: ["view-overview"], legs: "GR109-attention-row-dead-rule, W18-overview-card-pill", status: "latent" },
  { selector: ".copy-btn", views: ["view-instance", "view-site"], legs: "W21-inst-head-320-copy-reachable", status: "latent" },
  { selector: ".detail-grid--instance", views: ["view-instance"], legs: "W26-instance-track-min-content, W27-failed-retry-reachable-after-flick", status: "latent" },
  { selector: ".detail-head .fleet-url", views: ["view-site"], legs: "W14-site-detail-phone-band", status: "latent" },
  { selector: ".detail-head-main", views: ["view-instance"], legs: "W21-inst-head-320-copy-reachable", status: "latent" },
  { selector: ".detail-main", views: ["view-instance", "view-site"], legs: "W26-instance-track-min-content", status: "latent" },
  { selector: ".detail-rail", views: ["view-instance", "view-site"], legs: "W13-detail-route-band", status: "latent" },
  { selector: ".detail-rail .status-pill", views: ["view-site"], legs: "W13-detail-route-band", status: "latent" },
  { selector: ".detail-title-row h1", views: ["view-instance"], legs: "W21-detail-url-text-page-bound", status: "latent" },
  { selector: ".detail-url-text", views: ["view-instance"], legs: "W21-detail-url-text-page-bound", status: "latent" },
  { selector: ".fleet-row", views: ["view-overview", "view-providers"], legs: "W15-fleet-row-text-bounded, W35-hash-nav-hidden-view-residue", status: "latent" },
  { selector: ".inst-tab[aria-current=\"page\"]", views: ["view-instance"], legs: "W13-detail-route-band", status: "latent" },
  { selector: ".inst-tabs", views: ["view-instance"], legs: "W21-inst-head-320-copy-reachable", status: "latent" },
  { selector: ".instance-card-head", views: ["view-overview"], legs: "W18-overview-card-pill", status: "latent" },
  { selector: ".instance-card-head .status-pill-detail", views: ["view-overview"], legs: "W18-overview-card-pill", status: "latent" },
  { selector: ".instance-card-url", views: ["view-overview"], legs: "W18-overview-card-pill", status: "latent" },
  { selector: ".instances-grid", views: ["view-overview"], legs: "W12-narrow-viewport-truth", status: "latent" },
  { selector: ".instances-grid .instance-card", views: ["view-overview"], legs: "W12-narrow-viewport-truth", status: "latent" },
  { selector: ".site-name", views: ["view-sites", "view-instance"], legs: "W26-instance-track-min-content", status: "latent" },
  { selector: ".site-row", views: ["view-sites", "view-instance"], legs: "W50-site-row-three-hosts-cruel-by-fixture", status: "latent" },
];

/**
 * Compare a measured exposure map against RESIDUE_REGISTER.
 * `measured` is `{ [selector]: { hidden: <count>, views: [<view id>, …] } }`.
 * Returns `{ unregistered, stale, moved, ok }` — all four arrays of strings.
 */
export function registerDrift(measured, register = RESIDUE_REGISTER) {
  const reg = new Map(register.map((r) => [r.selector, r]));
  const unregistered = [], stale = [], moved = [], ok = [];
  for (const [selector, m] of Object.entries(measured)) {
    const r = reg.get(selector);
    if (m.hidden > 0 && !r) { unregistered.push(`${selector} — ${m.hidden} match(es) in hidden ${m.views.join("/")}`); continue; }
    if (m.hidden > 0 && r) {
      const want = [...r.views].sort().join("/"), got = [...m.views].sort().join("/");
      if (want !== got) moved.push(`${selector} — registered in ${want}, measured in ${got}`);
      else ok.push(selector);
    }
  }
  for (const r of register) {
    const m = measured[r.selector];
    if (!m || m.hidden === 0) stale.push(`${r.selector} — registered as exposed in ${r.views.join("/")}, measured 0 matches in any hidden view`);
  }
  return { unregistered, stale, moved, ok };
}

/**
 * Which `section.view` hosts each `id="…"` in index.html, by byte range.
 * Only ids the SHIPPED MARKUP carries are answerable here — the guard reaches
 * plenty of ids app.js paints at runtime (`#instance-tabpanel`, `#cred-token`),
 * and those come back `undefined` rather than "not in a view". A missing answer
 * is stated as missing; it is never rendered as a clean one.
 */
export function viewHostOfIds(indexHtml) {
  const src = String(indexHtml);
  const ranges = [];
  const openView = /<section\b[^>]*class="view"[^>]*id="([^"]+)"[^>]*>/g;
  let v;
  while ((v = openView.exec(src))) {
    // Depth-count `<section` / `</section>` from the opening tag to find the end.
    let depth = 0, i = v.index;
    const tag = /<\/?section\b/g;
    tag.lastIndex = i;
    let t, end = src.length;
    while ((t = tag.exec(src))) {
      if (src[t.index + 1] === "/") { depth--; if (depth === 0) { end = t.index; break; } }
      else depth++;
    }
    ranges.push({ view: v[1], start: v.index, end });
  }
  const out = {};
  const idRe = /\bid="([^"]+)"/g;
  let m;
  while ((m = idRe.exec(src))) {
    const at = m.index;
    const r = ranges.find((x) => at > x.start && at < x.end);
    if (r) out[m[1]] = r.view;
  }
  return out;
}
