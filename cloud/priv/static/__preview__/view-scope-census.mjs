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
        // THE ARGUMENT AS WRITTEN, for the sites whose selector cannot be read
        // from the bytes. A LINE NUMBER IS NOT A KEY — this file grows by
        // hundreds of lines a wave and every pinned line rots — so the
        // cardinality register below keys an unresolved site by leg + this
        // snippet. Whitespace is collapsed and it is cut at 48 chars: enough to
        // tell two `${…}`-built walks in one leg apart, short enough that a
        // reflow of the expression's tail does not invent a new site.
        arg: selector === null ? rest.replace(/\s+/g, " ").trim().slice(0, 48) : null,
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
//  edit this list). The leg PRINTS both numbers every run — how many distinct
//  document-wide selectors the static census found and how many of them match
//  inside a hidden view — so they are not typed here; a pair of literals in a
//  comment is exactly what the cancelled row this file's cardinality half
//  answers had rotted into.
//
//  TWO ROWS LEFT THIS LIST ON 2026-09-11 (task-39ebd948f40660e3) and neither was
//  a fix to the exposure: `.attention-row .attention-acts` and `.instances-grid
//  .instance-card` were both READINESS GATES converted to count the population
//  they wait for, scoped to `section.view:not([hidden])`. A scoped walk is not
//  document-wide, so it leaves the residue census entirely — and the ratchet's
//  stale arm is what noticed, exactly as designed.
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
  { selector: ".site-name", views: ["view-sites", "view-instance"], legs: "W26-instance-track-min-content", status: "latent" },
  { selector: ".site-row", views: ["view-sites", "view-instance"], legs: "W50-site-row-three-hosts-cruel-by-fixture", status: "latent" },
  // task-02a521fea7beeb2f: the pin-badge walk in the W21 detail leg is document-wide by
  // the same full-load entry as its siblings above; a hidden view-instance keeps one
  // Autoupdate badge painted after the tour. Latent for the same reason as .detail-url-text.
  { selector: ".update-panel-body .rail-row .v .badge", views: ["view-instance"], legs: "W21-detail-url-text-page-bound", status: "latent" },
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

// ─────────────────────────────────────────────────────────────────────────────
//  THE CARDINALITY HALF — WHICH WALKS READ **ONE** OF A POPULATION
//  (task-39ebd948f40660e3, re-cut of the cancelled cchi-w23 population register)
// ─────────────────────────────────────────────────────────────────────────────
//  The SCOPE half above asks WHERE a walk can reach. This half asks HOW MANY it
//  stood in front of. `document.querySelector('.deploy-row')` returns the FIRST
//  row on the page and says nothing about whether there was one row, three, or
//  forty — so a leg that keys its readiness, its click, or its measurement on a
//  singular walk can be measuring a half-painted screen, an arbitrary member of
//  a population, or (worst) a population of one that quietly became a population
//  of many when a fixture grew. Nothing in the file records which.
//
//  A singular walk therefore OWES one of two things, and this census is what
//  collects the debt:
//    · THE LEG PRINTS THE POPULATION — the same leg also walks the same
//      selector with `querySelectorAll`, so the run's own output carries the
//      count the singular read stood for. This is the D228 remedy and the only
//      discharge that is re-earned on every run.
//    · A COMMITTED ONE-LINE REASON — an entry in SINGULAR_REGISTER below saying
//      why one is the right number to read, or why the population does not
//      matter at that site.
//  Anything else is UNREGISTERED and reds. THE STALENESS CLAUSE IS FATAL AND
//  SYMMETRIC (D180): a register entry matching no site in the guard reds just as
//  loudly, because a reason nobody can reach certifies nothing.
//
//  FOUR CLASSES ARE DISCHARGED MECHANICALLY, by a rule rather than by a row —
//  an enumeration is a snapshot, a predicate is a rule, and a hand-kept list of
//  ~200 sites would rot inside a wave:
//    · `singleton-id`   — the selector's LAST compound is an `#id`. An id is one
//                         host by the HTML contract; a second match is a
//                         duplicate-id defect, which is a different finding and
//                         one several legs count on purpose.
//    · `live-view-host` — the selector IS `section.view:not([hidden])`. app.js's
//                         `applyRoute` hides every view but the routed one, so
//                         the visible view is a singleton by construction; and
//                         a walk that reads a DESCENDANT of it is NOT in this
//                         class, because the descendant is a population.
//    · `global-chrome`  — page chrome outside every view (GLOBAL_CHROME), one
//                         copy in index.html, verified by `verifyGlobalChrome`.
//    · `counted-in-leg` — the owning leg also walks the SAME selector with
//                         `querySelectorAll`, i.e. it prints the population.
//
//  WHAT THIS CENSUS DOES NOT CLAIM: it reads bytes, so it cannot tell you that a
//  population really is 1 on a shipped fixture. Only a run can, which is why the
//  discharge this file prefers is `counted-in-leg` — a number in the ok-line,
//  re-measured every run — and why a register row is a REASON, never a count.
// ─────────────────────────────────────────────────────────────────────────────

// THE REGISTER. One row per singular walk this file cannot discharge by rule,
// each carrying the reason one is the right number to read — or the reason the
// population does not change what the site does with its match.
//
// THREE SHAPES DOMINATE, and naming them is most of the value:
//   · READINESS — the walk is inside a `nav()` / `credWait` / `exitWait`
//     predicate and its only question is "has this screen painted at all yet".
//     It asserts nothing about the count, and the cells that follow do the
//     measuring. It is still a POPULATION-BLIND wait: it fires on the FIRST
//     match, so a screen that paints its rows one at a time can be measured
//     half-drawn. Where that risk is real the remedy is the D228 conversion
//     (three sites were converted under this row's task), not a row here.
//   · SINGLETON-BY-LAYOUT — one per painted screen (a rail, a grid, a card
//     head). A second one is a defect, and it is not this walk's defect.
//   · ONE DOOR — a click or typing target inside an open modal, where a second
//     copy would mean two modals are open at once.
//
// KEYED BY LEG + SELECTOR, NEVER BY LINE. Every line number in this guard rots:
// the row this register answers was CANCELLED because its own literals had.
export const SINGULAR_REGISTER = [
  // ── prologue: the door table and its helpers ──
  { leg: "(prologue)", selector: "#modal-root .launch-connect-provider", reason: "modal door table: an EXISTENCE predicate for the one connect door a launch modal opens with; two would mean two modals are open at once" },
  { leg: "(prologue)", arg: "'#modal-root ${sel}')`;", reason: "`openWith(sel)` builds a per-caller existence predicate — the population question belongs to each call site, and this census keys those separately" },
  { leg: "(prologue)", arg: "${JSON.stringify(sel)});if(!e) throw new Error('", reason: "`clickOne(sel)` is named for its contract: click the FIRST match, throw when there is none; a caller that needs every match does not use this helper" },

  // ── topbar / chrome ──
  { leg: "GR108-tablet-topbar-overflow", selector: ".topbar", reason: "readiness: the topbar is page chrome outside every view, one copy in index.html (the `header.topbar` arm of GLOBAL_CHROME; this site spells it class-only)" },
  { leg: "W20-phone-band-billing-chip", selector: ".topbar", reason: "readiness: the same single topbar, waited on before the billing chip is read" },
  { leg: "GR115-bpconsole-dead-rule", selector: ".topbar", reason: "readiness: the same single topbar, on the `empty` scenario where nothing else paints" },
  { leg: "W12-narrow-viewport-truth", selector: ".topbar", reason: "the class-only FALLBACK arm of `header.topbar` in the elementFromPoint probe — one topbar, and the probe tries the chrome spelling first" },

  // ── GR109 / W18 / W20: the overview's attention rows and cards ──
  { leg: "GR109-attention-row-dead-rule", selector: ".attention-row .status-pill-detail", reason: "readiness for the pill cells; the measurement below walks every `.attention-row .status-pill-detail` with querySelectorAll" },
  { leg: "W18-overview-card-pill", selector: ".instance-card-head .status-pill-detail", reason: "readiness only; this leg's cells walk the pills plurally and fail per pill" },
  { leg: "W20-attention-name-column", selector: ".attention-row .attention-name", reason: "readiness only; the column measurement below is plural over the same class" },

  // ── W12: the overview grid and the notification matrix ──
  { leg: "W12-narrow-viewport-truth", selector: ".instances-grid", reason: "singleton-by-layout: one grid per overview screen, and the cards inside it are walked plurally off THIS element (`g.querySelectorAll('.instance-card')`) rather than off the document" },
  { leg: "W12-narrow-viewport-truth", selector: ".set-matrix", reason: "singleton-by-layout: the notifications screen paints one matrix; the scroll probes drive that element and read `.set-matrix-event` out of it" },
  { leg: "W12-narrow-viewport-truth", selector: ".set-matrix .set-matrix-grid .set-matrix-event", reason: "readiness: waits for the first event cell to prove the matrix rendered; the overflow measurement scrolls the matrix, not a cell" },

  // ── W13 / W14 / W21 / W26 / W27: the detail screens ──
  { leg: "W13-detail-route-band", arg: "'${r.ready}') && (function(){var v=document.quer", reason: "readiness built from the route table's own `ready` string — one predicate per route, each asking only whether that screen painted" },
  { leg: "W13-detail-route-band", selector: ".inst-tab[aria-current=\"page\"]", reason: "`aria-current=\"page\"` is single-valued per tablist by the ARIA contract: a second current tab is a tab-state defect, not a population" },
  { leg: "W14-site-detail-phone-band", selector: ".detail-head .fleet-url", reason: "singleton-by-layout: one URL line in the site detail head" },
  { leg: "W21-inst-head-320-copy-reachable", selector: ".detail-head-main", reason: "singleton-by-layout: one head block per detail screen" },
  { leg: "W21-detail-url-text-page-bound", selector: ".detail-url-text", reason: "singleton-by-layout: one instance URL per detail screen (RESIDUE_REGISTER above carries it for the HIDDEN-view axis, which is a different question)" },
  { leg: "W21-detail-url-text-page-bound", selector: ".detail-title-row h1", reason: "singleton-by-layout: one page title per detail screen" },
  { leg: "W21-cruel-content-text-bounded", arg: "'${route.ready}') && (function(){var v=document.", reason: "readiness built from the route table's own `ready` string, one per cruel-content route" },
  { leg: "W21-token-reveal-readable", selector: ".token-ab", reason: "one door: the create-token form's single always-on checkbox, ticked before submit" },
  { leg: "W26-instance-track-min-content", selector: ".detail-main", reason: "singleton-by-layout: one main column per detail grid, measured as the track it is" },
  { leg: "W26-instance-track-min-content", selector: ".detail-grid--instance", reason: "singleton-by-layout: one instance detail grid per screen, and it is the grid whose track widths this leg measures" },
  { leg: "W27-failed-retry-reachable-after-flick", selector: ".detail-grid--instance", reason: "readiness: waits for the instance grid before the flick; the same single grid" },
  { leg: "W27-failed-retry-reachable-after-flick", selector: ".bp-timeline", reason: "readiness: one timeline per instance detail screen" },

  // ── W29: the deploy rail ──
  { leg: "W29-deploy-rail-live-url-wrap", selector: ".deploy-rail-live .site-open", reason: "readiness: the live rail paints one open-site link" },
  { leg: "W29-deploy-rail-live-url-wrap", selector: ".detail-head .fleet-url .site-open", reason: "readiness: the head's own open-site link, one per detail head" },
  { leg: "W29-deploy-rail-live-url-wrap", selector: ".deploy-rail-live .copy-btn", reason: "singleton-by-layout: one copy button in the live rail — the leg asserts its ancestry rather than assuming the class is unique document-wide" },
  { leg: "W29-deploy-rail-live-url-wrap", selector: ".detail-grid > .detail-main > #deploy-rail-slot > section.deploy-rail", reason: "the ancestry assertion itself: a child-combinator path through an id slot, which is one host by the id contract" },

  // ── W22 / W24 / W25 / W26: modals, credential sheets and the launch wizard ──
  { leg: "W22-shared-modal-card-min-content-floor", selector: "#modal-root .modal-card", reason: "one door: the open modal's single card, polled for running animations before it is measured" },
  { leg: "W24-cred-dialog-button-alive", selector: "#modal-root .launch-connect-provider", reason: "one door: the connect button inside the open modal" },
  { leg: "W24-cred-dialog-button-alive", selector: "#provider-connect [data-connect-submit]", reason: "one door: the providers screen's single connect-submit control, under an id host" },
  { leg: "W25-launch-catalog-after-connect", arg: "${JSON.stringify(scope)}+' .launch-connect-provi", reason: "one door, scope-parameterised: the same connect button reached under whichever host (`#modal-root` / `#view-overview`) the cell drives" },
  { leg: "W25-launch-catalog-after-connect", selector: "#view-overview .launch-form .form-input", reason: "one door: the wizard's first text field on the overview host — the leg types into the field it is about to read back" },
  { leg: "W25-launch-catalog-after-connect", selector: "#modal-root .launch-form .form-input", reason: "one door: the same wizard field on the modal host" },
  { leg: "W26-cred-sheet-exits", selector: "#launch-modal-slot .launch-form .form-input", reason: "one door: the wizard's name field inside the slot the sheet mounts in" },
  { leg: "W26-cred-sheet-exits", selector: "#view-overview .launch-form .form-input", reason: "one door: the same field on the overview host, typed into and read back" },
  { leg: "W26-cred-sheet-exits", selector: "#view-overview .launch-connect-provider", reason: "one door: the connect button the exit probes click" },
  { leg: "W26-cred-sheet-exits", selector: "#modal-root .choice-list", reason: "one door: the open sheet's provider picker — its presence IS the assertion; the choices inside it are not this leg's subject" },
  { leg: "W26-cred-sheet-exits", selector: "#modal-root .modal-title", reason: "one door: the open sheet's title, read as text to say WHICH sheet is open" },
  { leg: "W26-cred-sheet-exits", selector: "#modal-root .modal-x[data-close]", reason: "one door: the close ×; the probe reports its absence by name rather than silently missing it" },
  { leg: "W26-cred-sheet-exits", selector: "#modal-root .modal-backdrop[data-close]", reason: "one door: the single backdrop of the open sheet" },

  // ── W24 / W26: the /new deploy theater ──
  { leg: "W24-theater-failed-hostname-whole", selector: ".new-failed", reason: "singleton-by-layout: one failure panel per theater screen — also the readiness gate for it" },
  { leg: "W24-theater-failed-hostname-whole", selector: ".new-step-detail", reason: "readiness: waits for the first step caption; the torn-hostname measurement below is plural over the steps" },
  { leg: "W24-theater-failed-hostname-whole", selector: ".new-console-text", reason: "readiness: waits for the console pane to paint before its text is measured" },
  { leg: "W24-theater-failed-hostname-whole", selector: ".new-theater-grid", reason: "singleton-by-layout: one theater grid per screen; the STEPS inside it are counted plurally in the same probe" },
  { leg: "W26-new-ready-and-launch-bounded", selector: ".new-ready", reason: "singleton-by-layout: one ready card per theater screen" },
  { leg: "W26-new-ready-and-launch-bounded", selector: ".new-ready .mono", reason: "the ready card's FIRST monospace line is the URL this leg bounds; reading past it would measure the sha run instead" },
  { leg: "W26-new-ready-and-launch-bounded", selector: ".new-launch", reason: "singleton-by-layout: one launch panel per /new screen" },
  { leg: "W26-new-ready-and-launch-bounded", selector: ".new-card", reason: "singleton-by-layout: the card that CONTAINS the field this cell measures — a second card would not be that field's ancestor" },

  // ── W35 / W50 / W20-type-floor ──
  { leg: "W35-hash-nav-hidden-view-residue", selector: "section.view:not([hidden]) .fleet-row[data-id]", reason: "the tour needs ONE instance id to drill into; any row's `data-id` serves, and the row is already scoped to the visible view" },
  { leg: "W35-hash-nav-hidden-view-residue", selector: "section.view:not([hidden]) .site-row[data-id]", reason: "the same, for the site drill-down" },
  { leg: "W50-site-row-three-hosts-cruel-by-fixture", arg: "'${t.ready}') && (function(){var v=document.quer", reason: "readiness built from the cell table's own `ready` string, one per host cell" },
  { leg: "W20-type-floor-instances", selector: "#overview-body .instance-card", reason: "readiness for the overview screen; the type-floor measurement itself walks every text node under the view" },
  { leg: "W20-type-floor-instances", selector: "#billing-plan-section .set-h", reason: "readiness for the billing screen: one section heading, under an id host" },
  { leg: "W20-type-floor-instances", selector: "#billing-recommended .loading", reason: "readiness, NEGATED: waits for the recommended panel to stop showing a spinner — the question is whether ANY loading node remains, so one match is enough to keep waiting" },
  { leg: "W20-type-floor-instances", selector: "#activity-body .tlv-row", reason: "readiness for the activity feed: the first row proves the feed painted" },
  { leg: "W20-type-floor-instances", selector: "#sites-body .site-row", reason: "readiness for the sites screen: the first row proves the list painted" },
  { leg: "W20-type-floor-instances", selector: ".fleet-row", reason: "readiness for the fleet screen: the first row proves the list painted" },
];

/** A singular walk's stable identity: the owning leg plus what it walks. */
export function walkKey(w) {
  return `${w.leg} :: ${w.selector === null ? `«${w.arg}»` : w.selector}`;
}

// `#foo` as the last compound of the selector, at the end of the string.
const TERMINAL_ID_RE = /(?:^|[\s>+~])#[A-Za-z][\w-]*$/;

/**
 * Classify ONE singular walk by how its population is accounted for.
 * `allKeys` is the set of `leg :: selector` keys of the file's PLURAL walks.
 * Returns one of: "singleton-id" | "live-view-host" | "global-chrome" |
 * "counted-in-leg" | "registered" | "unregistered".
 */
export function classifyCardinality(w, allKeys, register = SINGULAR_REGISTER) {
  if (w.selector !== null) {
    const s = w.selector.trim();
    if (s === LIVE_VIEW_SELECTOR) return "live-view-host";
    if (GLOBAL_CHROME.includes(s)) return "global-chrome";
    if (TERMINAL_ID_RE.test(s)) return "singleton-id";
  }
  // AN UNRESOLVED SITE CAN NEVER BE `counted-in-leg`. Its selector is null, and
  // `leg :: null` would collide with any OTHER runtime-built walk in the same
  // leg that happens to be plural — discharging a walk nobody has classified
  // against a count of something else. Measured while writing this: three of the
  // six unresolved sites fell into that hole.
  if (w.selector !== null && allKeys.has(`${w.leg} :: ${w.selector}`)) return "counted-in-leg";
  const key = walkKey(w);
  return register.some((r) => registerKey(r) === key) ? "registered" : "unregistered";
}

/** A register row's key, spelled exactly the way `walkKey` spells a walk's. */
export function registerKey(r) {
  return `${r.leg} :: ${r.selector === null || r.selector === undefined ? `«${r.arg}»` : r.selector}`;
}

/**
 * THE CENSUS. Every singular `document.querySelector(` site in `source`, in file
 * order, each with the line, the leg, the selector (or the raw argument, for a
 * runtime-built one) and its discharge class.
 * Returns `{ sites, tally, unregistered, stale, lines }` where `lines` is the
 * printable census and `unregistered`/`stale` are the two red arms.
 */
export function singularCensus(source, register = SINGULAR_REGISTER) {
  const walks = censusWalks(source);
  const allKeys = new Set(walks.filter((w) => w.all).map((w) => `${w.leg} :: ${w.selector}`));
  const sites = walks
    .filter((w) => !w.all)
    .map((w) => ({ ...w, discharge: classifyCardinality(w, allKeys, register) }));

  const tally = {};
  for (const s of sites) tally[s.discharge] = (tally[s.discharge] || 0) + 1;

  const unregistered = sites
    .filter((s) => s.discharge === "unregistered")
    .map((s) => `${walkKey(s)} (line ${s.line}) — a singular walk with no printed population and no committed reason`);

  const reached = new Set(sites.map(walkKey));
  const stale = register
    .filter((r) => !reached.has(registerKey(r)))
    .map((r) => `${registerKey(r)} — registered, but no singular walk in the guard matches it`);

  const lines = sites.map(
    (s) => `  ${String(s.line).padStart(5)}  ${s.discharge.padEnd(14)}  ${s.leg}  ${s.selector === null ? `«${s.arg}»` : s.selector}`,
  );
  return { sites, tally, unregistered, stale, lines };
}

/**
 * The three numbers overflow-guard.mjs's header used to carry as hand-typed
 * literals (`68 / 55 / 15` against a file that measures 253 / 224 / 98 — every
 * one of them dead by wave 23, and the row this census answers was CANCELLED
 * because it quoted them). Derived here with the counting rule beside it, so the
 * header can point at a command instead of a number. The patterns are exactly
 * the ones the header quoted: `querySelector[(]` and `querySelectorAll[(]` are
 * disjoint, and both count `e.querySelector(` on an element handle, which the
 * call-site census above deliberately does not.
 */
export function grepCounts(source) {
  const text = String(source);
  const occ = (text.match(/querySelector\(/g) || []).length;
  const allOcc = (text.match(/querySelectorAll\(/g) || []).length;
  const lines = text.split("\n").filter((l) => l.includes("querySelector(")).length;
  const allLines = text.split("\n").filter((l) => l.includes("querySelectorAll(")).length;
  return { occurrences: occ, lines, allOccurrences: allOcc, allLines };
}

// ─────────────────────────────────────────────────────────────────────────────
//  THE BUILD-TIME ARM: `node cloud/priv/static/__preview__/view-scope-census.mjs`
// ─────────────────────────────────────────────────────────────────────────────
//  Prints the cardinality census of overflow-guard.mjs — every singular walk
//  with its line, its leg, its selector and its discharge — and exits:
//    0 — every singular walk is discharged, and every register row is reachable
//    1 — UNREGISTERED singular walks, or STALE register rows (D180), or both
//    2 — REFUSED: the guard could not be read. A refusal is not a pass.
//  It is browserless and dependency-free, so it runs in the same job as the unit
//  harness rather than behind a Chrome bring-up. The module half is unchanged by
//  it: importing this file runs nothing.
export async function runCensusCli(argv = []) {
  const { default: fs } = await import("node:fs");
  const { default: path } = await import("node:path");
  const { fileURLToPath } = await import("node:url");
  const here = path.dirname(fileURLToPath(import.meta.url));
  const target = path.join(here, "overflow-guard.mjs");
  let src;
  try {
    src = fs.readFileSync(target, "utf8");
  } catch (e) {
    process.stdout.write(`view-scope-census: REFUSED — cannot read ${target}: ${e.message}\n`);
    return 2;
  }
  const c = singularCensus(src);
  const g = grepCounts(src);
  const verbose = argv.includes("--list");
  process.stdout.write(
    `\nSINGULAR-SELECTOR CENSUS — overflow-guard.mjs\n` +
    `  document.querySelector(All)? call sites: ${censusWalks(src).length} ` +
    `(grep rule, for the header that used to type these: querySelector[(] ${g.occurrences} occurrences on ` +
    `${g.lines} lines; querySelectorAll[(] ${g.allOccurrences} on ${g.allLines})\n` +
    `  singular sites: ${c.sites.length}\n` +
    Object.entries(c.tally).sort().map(([k, v]) => `    ${k.padEnd(14)} ${v}\n`).join("") +
    `  register rows: ${SINGULAR_REGISTER.length}\n`,
  );
  if (verbose) process.stdout.write(c.lines.join("\n") + "\n");
  if (!c.sites.length) {
    process.stdout.write(`view-scope-census: REFUSED — ZERO singular walks in a guard that is ${src.split("\n").length} lines long. The call pattern stopped matching how this file spells its walks; an empty census is not a clean one\n`);
    return 2;
  }
  let bad = 0;
  for (const u of c.unregistered) {
    bad++;
    process.stdout.write(`  UNREGISTERED  ${u}\n`);
  }
  for (const st of c.stale) {
    bad++;
    process.stdout.write(`  STALE         ${st}\n`);
  }
  if (bad) {
    process.stdout.write(
      `\nview-scope-census: ${c.unregistered.length} unregistered singular walk(s), ${c.stale.length} stale ` +
      `register row(s). A singular walk owes either a PRINTED POPULATION in its leg's ok-line (walk the same ` +
      `selector with querySelectorAll, scoped to \`${LIVE_VIEW_SELECTOR}\`) or a one-line reason in ` +
      `SINGULAR_REGISTER. A register row that matches no walk is fatal in the same way and for the same reason ` +
      `(D180): a reason nobody can reach certifies nothing — delete it.\n`,
    );
    return 1;
  }
  process.stdout.write(`view-scope-census: every singular walk is accounted for, and every register row is reachable\n`);
  return 0;
}

// Run only when this file IS the entry point; an `import` of it runs nothing.
if (process.argv[1] && process.argv[1].endsWith("view-scope-census.mjs")) {
  process.exitCode = await runCensusCli(process.argv.slice(2));
}
