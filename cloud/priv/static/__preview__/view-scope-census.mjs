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
  { selector: ".attention-row", views: ["view-overview"], legs: "GR109-attention-row-dead-rule, W20-attention-name-column", status: "latent", reason: "W20 measures the attention COLUMN geometry and GR109 the stacked-row cascade; both enter by full load on an overview scenario, and scoping them is this row's remedy \u2014 until then the walk reads the overview rows a person has already visited" },
  { selector: ".attention-row .attention-name", views: ["view-overview"], legs: "W20-attention-name-column", status: "latent", reason: "the name column's width is read off every attention row on the screen; a hidden overview keeps its own rows and would widen the census" },
  { selector: ".attention-row .status-pill-detail", views: ["view-overview"], legs: "GR109-attention-row-dead-rule, W18-overview-card-pill", status: "latent", reason: "the pill cells GR109 and W18 measure; a hidden overview holds one per attention row" },
  { selector: ".copy-btn", views: ["view-instance", "view-site"], legs: "W21-inst-head-320-copy-reachable", status: "latent", reason: "W21 asks whether the copy control is REACHABLE at 320 in the instance head; a hidden view-site keeps its own copy button painted" },
  { selector: ".detail-grid--instance", views: ["view-instance"], legs: "W26-instance-track-min-content, W27-failed-retry-reachable-after-flick", status: "latent", reason: "the instance detail grid whose track widths W26 measures and W27 waits on; only one detail view is live, the other is hidden residue" },
  { selector: ".detail-head .fleet-url", views: ["view-site"], legs: "W14-site-detail-phone-band", status: "latent", reason: "the site detail head's URL line W14 bounds; a hidden view-site keeps it after the tour" },
  { selector: ".detail-head-main", views: ["view-instance"], legs: "W21-inst-head-320-copy-reachable", status: "latent", reason: "the detail head block W21 measures at 320; the other detail view keeps its own" },
  { selector: ".detail-main", views: ["view-instance", "view-site"], legs: "W26-instance-track-min-content", status: "latent", reason: "the detail grid's main track W26 measures; instance and site each paint one and only one is live" },
  { selector: ".detail-rail", views: ["view-instance", "view-site"], legs: "W13-detail-route-band", status: "latent", reason: "the rail W13 bounds per route; both detail views paint a rail and the hidden one is residue" },
  { selector: ".detail-rail .status-pill", views: ["view-site"], legs: "W13-detail-route-band", status: "latent", reason: "the rail's route pills; the same two-detail-view residue as .detail-rail" },
  { selector: ".detail-title-row h1", views: ["view-instance"], legs: "W21-detail-url-text-page-bound", status: "latent", reason: "the detail page title W21 bounds; the hidden instance view keeps its own h1" },
  { selector: ".detail-url-text", views: ["view-instance"], legs: "W21-detail-url-text-page-bound", status: "latent", reason: "the instance URL W21 bounds; the hidden instance view keeps its own" },
  { selector: ".fleet-row", views: ["view-overview", "view-providers"], legs: "W15-fleet-row-text-bounded, W35-hash-nav-hidden-view-residue", status: "latent", reason: "THE ORIGINAL FINDING (cch-w24-s5): #view-overview paints activity rows under the same class, so the document-wide count is 8 against 5 in view. W15's measuring walk is already scoped; the sites left here are W35's own controls, which are document-wide ON PURPOSE because the difference IS the subject" },
  { selector: ".inst-tab[aria-current=\"page\"]", views: ["view-instance"], legs: "W13-detail-route-band", status: "latent", reason: "the current instance tab W13 reads; a hidden view-instance keeps its tablist with a current tab" },
  { selector: ".inst-tabs", views: ["view-instance"], legs: "W21-inst-head-320-copy-reachable", status: "latent", reason: "the tab strip W21 measures at 320; the hidden instance view keeps it" },
  { selector: ".instance-card-head", views: ["view-overview"], legs: "W18-overview-card-pill", status: "latent", reason: "the overview card head W18 measures; overview is the landing screen, so it is painted and hidden for every leg that routes away from it" },
  { selector: ".instance-card-head .status-pill-detail", views: ["view-overview"], legs: "W18-overview-card-pill", status: "latent", reason: "the card pills W18 asserts per cell; same hidden-overview residue as the head" },
  { selector: ".instance-card-url", views: ["view-overview"], legs: "W18-overview-card-pill", status: "latent", reason: "the card address W18 bounds (W22's own readiness was scoped to the live view under this row's task); the hidden overview keeps one per card" },
  { selector: ".instances-grid", views: ["view-overview"], legs: "W12-narrow-viewport-truth", status: "latent", reason: "W12's overview grid, walked plurally off the element rather than the document; a hidden overview keeps its grid" },
  { selector: ".site-name", views: ["view-sites", "view-instance"], legs: "W26-instance-track-min-content", status: "latent", reason: "the site name W26 measures in the instance detail's site list; view-sites keeps its own rows under the same class" },
  { selector: ".site-row", views: ["view-sites", "view-instance"], legs: "W50-site-row-three-hosts-cruel-by-fixture", status: "latent", reason: "the site rows W50 drives across three hosts; view-instance's embedded site list paints rows under the same class" },
  // task-02a521fea7beeb2f: the pin-badge walk in the W21 detail leg is document-wide by
  // the same full-load entry as its siblings above; a hidden view-instance keeps one
  // Autoupdate badge painted after the tour. Latent for the same reason as .detail-url-text.
  { selector: ".update-panel-body .rail-row .v .badge", views: ["view-instance"], legs: "W21-detail-url-text-page-bound", status: "latent", reason: "the Autoupdate badge W21 bounds; a hidden view-instance keeps one painted after the tour" },
];

/**
 * Compare a measured exposure map against RESIDUE_REGISTER.
 * `measured` is `{ [selector]: { hidden: <count>, views: [<view id>, …] } }`.
 * Returns `{ unregistered, stale, moved, reasonless, ok }` — all five arrays of
 * strings.
 *
 * `reasonless` IS A FIFTH RED ARM AND IT IS NOT DECORATION (task-995fc7be51dab99e).
 * The criterion this register answers is "SCOPED, or kept document-wide WITH A
 * WRITTEN REASON". A row carrying only `status: "latent"` discharges neither
 * half: it records that a walk reaches a hidden view and says nothing about why
 * that is the right thing for it to do. A register whose rows can be added
 * without a sentence is a place to park a finding, so the absence of the
 * sentence reds — here, statically, in the same pass as the other three arms,
 * and not only in the browser leg.
 */
export function registerDrift(measured, register = RESIDUE_REGISTER) {
  const reg = new Map(register.map((r) => [r.selector, r]));
  const unregistered = [], stale = [], moved = [], ok = [];
  const reasonless = register
    .filter((r) => typeof r.reason !== "string" || r.reason.trim().length < 20)
    .map((r) => `${r.selector} — registered as exposed in ${r.views.join("/")} with no written reason (a one-line \`reason:\` saying why this walk stays document-wide is what the row owes)`);
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
  return { unregistered, stale, moved, reasonless, ok };
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
  { leg: "W20-type-floor-instances", selector: "#billing-plan-section .set-h", reason: "readiness for the billing screen: one section heading, under an id host" },
  { leg: "W20-type-floor-instances", selector: "#billing-recommended .loading", reason: "readiness, NEGATED: waits for the recommended panel to stop showing a spinner — the question is whether ANY loading node remains, so one match is enough to keep waiting" },
  { leg: "W20-type-floor-instances", selector: "#activity-body .tlv-row", reason: "readiness for the activity feed: the first row proves the feed painted" },
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

// ─────────────────────────────────────────────────────────────────────────────
//  THE UNRESOLVED HALF — THE WALKS THE BYTES CANNOT ANSWER FOR
//  (task-995fc7be51dab99e)
// ─────────────────────────────────────────────────────────────────────────────
//  `censusWalks` classifies a walk by reading its selector literal. A walk whose
//  argument is built at runtime — a `${…}` interpolation, a `JSON.stringify(x)`,
//  a bare variable — has no literal to read, so it comes back `kind:"unresolved"`
//  and the SCOPE census above simply does not speak for it. That was the honest
//  thing to do and it is not the finishing move: the leg printed "15 UNRESOLVED
//  and NAMED" every run, which tells a reader the sites exist and nothing about
//  whether any of them can reach a view the person is not looking at.
//
//  A HUMAN CAN READ WHAT A REGEX CANNOT. Each site below was classified by
//  following the expression back to the table or the parameter that feeds it and
//  writing down what the selector can actually BE:
//
//    · "id-anchored"       — every value the expression can take begins with a
//                            literal `#id` host written IN THE EXPRESSION
//                            (`'#modal-root ' + sel`, `'#provider-connect [...]'`).
//                            The interpolated part cannot move the walk out of
//                            that host, so no second view can hold a match.
//    · "live-view"         — the expression's own prefix is
//                            `section.view:not([hidden])`.
//    · "document-wide"     — at least one value the expression takes is a bare
//                            class/element. This is the class that OWES the
//                            scoping remedy, exactly like a literal one.
//    · "table-literal"     — the interpolation is `JSON.stringify(x)` over a
//                            table of LITERAL selectors declared in this file.
//                            Each such value is written out in `values` below,
//                            and `scope` is the WEAKEST of them, so a table that
//                            grows a bare-class row is a change to this row.
//    · "caller-classified" — a prologue HELPER whose selector is entirely its
//                            caller's (`clickOne(sel)`, `shown(sel)`). The
//                            helper reaches wherever it is handed; the scope
//                            question belongs to each call site, which the
//                            SINGULAR_REGISTER above already keys separately.
//
//  RATCHETED IN BOTH DIRECTIONS, like every other register in this file: a
//  runtime-built walk with no row REDS (`UNREGISTERED UNRESOLVED`), and a row no
//  site in the guard matches REDS (`STALE UNRESOLVED`). Keyed by leg + the same
//  48-char collapsed argument snippet `censusWalks` already cuts, never by line.
export const UNRESOLVED_REGISTER = [
  // ── prologue helpers: the selector is the caller's, not the helper's ──
  {
    leg: "(prologue)", arg: "'#modal-root ${sel}')`;", scope: "id-anchored",
    reason: "`openWith(sel)` writes the literal `#modal-root ` host itself and interpolates only the tail, so every walk it builds is anchored under the one modal root — a second view cannot hold a match unless the id is duplicated",
  },
  {
    leg: "(prologue)", arg: "${JSON.stringify(sel)});if(!e) throw new Error('", scope: "caller-classified",
    reason: "`clickOne(sel)` reaches wherever its caller points it; the scope question is each call site's, and SINGULAR_REGISTER above keys those separately rather than crediting the helper with one answer",
  },
  {
    leg: "(prologue)", arg: "'${sel}')).some(function(e){var r=e.getBoundingC", scope: "caller-classified",
    reason: "`shown(sel)` is the paint-check floor's builder — same as `clickOne`: the selector is the caller's, and the floor deliberately requires a LITERAL there so the selector can be derived and paint-checked",
  },

  // ── readiness strings built from a route table's own `ready` field ──
  {
    leg: "W13-detail-route-band", arg: "'${r.ready}') && (function(){var v=document.quer", scope: "document-wide",
    values: [".detail-grid--instance", "#instance-tabpanel", ".detail-grid", ".fleet-row"],
    reason: "BAND_ROUTES `ready` is a mix: two id-anchored, two bare classes. Readiness only, and the SAME expression already asserts `section.view:not([hidden])` has the routed id, so a hidden view satisfying the class half cannot make the conjunction true on the wrong screen — but the class half alone is document-wide and the conjunction is what saves it",
  },
  {
    leg: "W21-cruel-content-text-bounded", arg: "'${route.ready}') && (function(){var v=document.", scope: "document-wide",
    values: [".fleet-row", ".instance-card", ".detail-title-row", "#sites-body .site-row"],
    reason: "the cruel-content route table's own `ready`, same shape and same saving conjunction as W13's above",
  },
  {
    leg: "W50-site-row-three-hosts-cruel-by-fixture", arg: "'${t.ready}') && (function(){var v=document.quer", scope: "id-anchored",
    values: ["#sites-body .site-row", "#instance-sites .site-row"],
    reason: "every host cell's `ready` is anchored under an id (`#sites-body` / `#instance-sites`), so this readiness cannot be satisfied by a second view even without the conjunction it also carries",
  },
  {
    leg: "W20-type-floor-instances", arg: "${JSON.stringify(rt.pop)}).length`)}`);", scope: "id-anchored",
    values: ["#overview-body .instance-card", "#sites-body .site-row", "section.view:not([hidden]) .fleet-row"],
    reason: "the POPULATION print, over the route table's `pop`: two id-anchored hosts and one already scoped to the live view — none of the three can count a hidden screen's rows",
  },

  // ── measurement walks built from a table of literal selectors ──
  {
    leg: "W22-2fa-enroll-phone-band", arg: "q));` +", scope: "document-wide",
    values: [".a2f-qr", "#a2f-secret", "#a2f-copy-secret", "#a2f-confirm"],
    reason: "A2F_HOSTS is three id-anchored controls and one bare `.a2f-qr`; the enroll sheet is a MODAL, so the four controls only ever exist while it is open and no `section.view` paints them — the bare arm is document-wide by spelling and unreachable by a second view in practice",
  },
  {
    leg: "W29-deploy-rail-live-url-wrap", arg: "sel)).map(function(a){` +", scope: "document-wide",
    values: [".deploy-rail-live .site-open", ".detail-head .fleet-url .site-open", ".deploy-rail-live .copy-btn"],
    reason: "`read(sel, boxSel)` is handed bare-class paths inside this leg; two of them already carry RESIDUE_REGISTER rows for their singular twins, and the plural read here inherits the same hidden-detail-view residue",
  },
  {
    leg: "W23-cred-remediation-reachable", arg: "'#provider-connect [data-connect-kind=\"${cell.ki", scope: "id-anchored",
    reason: "the segment picker inside the providers screen's `#provider-connect` card: the id host is literal and only the `data-connect-kind` value interpolates",
  },
  {
    leg: "W25-launch-catalog-after-connect", arg: "${JSON.stringify(scope)}+' .launch-connect-provi", scope: "id-anchored",
    values: ["#modal-root .launch-connect-provider", "#view-overview .launch-connect-provider"],
    reason: "`lccConnect(scope, …)` is called with exactly two scopes and both are literal id hosts; the door is reached under whichever one the cell drives",
  },
  {
    leg: "W21-cruel-content-text-bounded", arg: "${JSON.stringify(route.sel)})).forEach(function(", scope: "document-wide",
    values: [".fleet-url", ".instance-card-name", ".detail-title-row .status-pill-detail, .bp-tl-fail", ".site-host", ".site-name", ".fleet-name", ".fleet-meta"],
    reason: "THE MEASUREMENT ITSELF, over bare classes — the largest unresolved exposure in the file. `.site-name` already carries a RESIDUE_REGISTER row for its literal twin, so this table's rows are exposed in the same way and by the same mechanism; the leg enters by full load, so it is latent for the same reason every registered row is",
  },
  {
    leg: "W21-cruel-content-text-bounded", arg: "hsel)).forEach(function(e,i){` +", scope: "document-wide",
    values: ["(route.heights[] — bare classes drawn from the same rows as route.sel)"],
    reason: "the line-box half of the same measurement, over the same table's `heights` paths: bare classes, exposed exactly as `route.sel` is",
  },
  {
    leg: "W21-cruel-content-text-bounded", arg: "tsel)).forEach(function(e,i){` +", scope: "document-wide",
    values: ["(route.tokens[] — bare classes drawn from the same rows as route.sel)"],
    reason: "the torn-token half of the same measurement, over the same table's `tokens` paths: bare classes, exposed exactly as `route.sel` is",
  },

  // ── the residue census's own walk ──
  {
    leg: "W35-hash-nav-hidden-view-residue", arg: "s).length;}catch(err){e.err=String(err&&err.mess", scope: "document-wide",
    reason: "DOCUMENT-WIDE ON PURPOSE AND IT IS THE SUBJECT: this is the residue census walking every censused selector against the whole document, then against each hidden `section.view` in turn. Scoping it would delete the measurement",
  },
];

/** An unresolved site's stable identity: owning leg + the collapsed argument. */
export function unresolvedKey(w) {
  return `${w.leg} :: «${w.arg}»`;
}

/**
 * Every runtime-built walk in `source`, matched against UNRESOLVED_REGISTER.
 * Returns `{ sites, byScope, unregistered, stale, lines }`. Both drift arms are
 * fatal to `runCensusCli`, in both directions (D180).
 */
export function unresolvedCensus(source, register = UNRESOLVED_REGISTER) {
  const reg = new Map(register.map((r) => [unresolvedKey(r), r]));
  const sites = censusWalks(source)
    .filter((w) => w.kind === "unresolved")
    .map((w) => {
      const r = reg.get(unresolvedKey(w));
      return { ...w, scope: r ? r.scope : null, reason: r ? r.reason : null };
    });

  const byScope = {};
  for (const s of sites) byScope[s.scope || "UNCLASSIFIED"] = (byScope[s.scope || "UNCLASSIFIED"] || 0) + 1;

  const unregistered = sites
    .filter((s) => !s.scope)
    .map((s) => `${unresolvedKey(s)} (line ${s.line}) — a walk whose selector is built at runtime, with no row saying what it can reach`);

  const reached = new Set(sites.map(unresolvedKey));
  const stale = register
    .filter((r) => !reached.has(unresolvedKey(r)))
    .map((r) => `${unresolvedKey(r)} — registered, but no runtime-built walk in the guard matches it`);

  const lines = sites.map(
    (s) => `  ${String(s.line).padStart(5)}  ${(s.scope || "UNCLASSIFIED").padEnd(17)}  ${s.leg}  «${s.arg}»`,
  );
  return { sites, byScope, unregistered, stale, lines };
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
  const u = unresolvedCensus(src);
  const rDrift = registerDrift({}, RESIDUE_REGISTER);
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
  // THE RUNTIME-BUILT HALF. These sites are outside the byte census by
  // construction; printing the count without the classification is what let
  // "15 UNRESOLVED and NAMED" stand for an answer for a wave.
  process.stdout.write(
    `\nRUNTIME-BUILT SELECTOR CENSUS — the walks the bytes cannot classify\n` +
    `  sites: ${u.sites.length}\n` +
    Object.entries(u.byScope).sort().map(([k, v]) => `    ${k.padEnd(17)} ${v}\n`).join("") +
    `  register rows: ${UNRESOLVED_REGISTER.length}\n`,
  );
  if (verbose) process.stdout.write(u.lines.join("\n") + "\n");
  // THE RESIDUE REGISTER'S REASON ARM, checked STATICALLY. The other three arms
  // need a browser (they compare against a measurement); this one is a property
  // of the register's own text and belongs in the cheap job.
  process.stdout.write(
    `\nRESIDUE REGISTER — ${RESIDUE_REGISTER.length} document-wide walk(s) kept document-wide, ` +
    `${RESIDUE_REGISTER.length - rDrift.reasonless.length} with a written reason\n`,
  );
  if (!c.sites.length) {
    process.stdout.write(`view-scope-census: REFUSED — ZERO singular walks in a guard that is ${src.split("\n").length} lines long. The call pattern stopped matching how this file spells its walks; an empty census is not a clean one\n`);
    return 2;
  }
  let bad = 0;
  for (const x of c.unregistered) {
    bad++;
    process.stdout.write(`  UNREGISTERED  ${x}\n`);
  }
  for (const st of c.stale) {
    bad++;
    process.stdout.write(`  STALE         ${st}\n`);
  }
  for (const x of u.unregistered) {
    bad++;
    process.stdout.write(`  UNREGISTERED UNRESOLVED  ${x}\n`);
  }
  for (const st of u.stale) {
    bad++;
    process.stdout.write(`  STALE UNRESOLVED         ${st}\n`);
  }
  for (const x of rDrift.reasonless) {
    bad++;
    process.stdout.write(`  REASONLESS RESIDUE ROW   ${x}\n`);
  }
  if (bad) {
    process.stdout.write(
      `\nview-scope-census: ${c.unregistered.length} unregistered singular walk(s), ${c.stale.length} stale ` +
      `register row(s), ${u.unregistered.length} unclassified runtime-built walk(s), ${u.stale.length} stale ` +
      `runtime-built row(s), ${rDrift.reasonless.length} residue row(s) with no written reason. ` +
      `A runtime-built walk owes a row in UNRESOLVED_REGISTER saying what its selector can BE — follow the ` +
      `expression back to the table or the parameter that feeds it. A residue row owes one line saying why ` +
      `the walk stays document-wide; the alternative is to scope it to \`${LIVE_VIEW_SELECTOR}\`. ` +
      `A singular walk owes either a PRINTED POPULATION in its leg's ok-line (walk the same ` +
      `selector with querySelectorAll, scoped to \`${LIVE_VIEW_SELECTOR}\`) or a one-line reason in ` +
      `SINGULAR_REGISTER. A register row that matches no walk is fatal in the same way and for the same reason ` +
      `(D180): a reason nobody can reach certifies nothing — delete it.\n`,
    );
    return 1;
  }
  process.stdout.write(
    `view-scope-census: every singular walk is accounted for, every runtime-built walk is classified, ` +
    `every document-wide walk kept document-wide carries a written reason, and every register row is reachable\n`,
  );
  return 0;
}

// Run only when this file IS the entry point; an `import` of it runs nothing.
// DELIBERATELY NOT A TOP-LEVEL `await`: a module with one is an ASYNC module for
// every importer, and overflow-guard.mjs imports this file. `.then` keeps the
// module synchronous and the CLI arm costs its importers nothing.
if (process.argv[1] && process.argv[1].endsWith("view-scope-census.mjs")) {
  runCensusCli(process.argv.slice(2)).then((code) => { process.exitCode = code; });
}
