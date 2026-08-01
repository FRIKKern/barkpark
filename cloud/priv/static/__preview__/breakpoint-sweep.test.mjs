// breakpoint-sweep.test.mjs — the PURE half of the continuous responsive sweep,
// pinned. Zero dependencies, no browser, no port: node --test only.
//
// WHAT THIS FILE IS FOR, AND WHAT IT IS NOT FOR. The sweep's judgement about
// PIXELS lives in headless Chrome and cannot be asserted here — reading the
// probe source and declaring it correct is exactly the mistake charter GR118
// records (a source regex tests a story about the pixels). What CAN be pinned
// hermetically is the PARSER and the COVERAGE ALGEBRA: comment-stripping, range
// syntax, min-width polarity, the refusal to guess at an unreadable width, the
// boundary walk, and the fact that the refusal reads the sweep's OWN tables.
// Those are the parts that decide whether the instrument has a blind spot.
//
// Every negative case here is a MUTATION of a positive one, so each assertion
// is demonstrably able to fail rather than able to be satisfied by an empty set.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  stripCssComments, boundaryOf, parseWidthClause, parseMediaBreakpoints,
  parseViewIds, boundaryWalk, coverageReport, selectCells,
  parseHeightClause, parseThemeMembers, accentIdentities, axisCoverage,
  familyOf, scenarioReport,
  BREAKPOINTS, WIDTHS, CELLS, COVERED_VIEWS, FOLD_FRACTION,
  HIDING_UTILITIES, THEMES, HEIGHTS, HEIGHT_REASONS, RENDER_HEIGHT,
  SCENARIO_RESIDUE, RESIDUE_FAMILY_REASONS,
} from "./breakpoint-sweep.mjs";
import { SCENARIOS, SCENARIO_NAMES } from "./scenarios.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const APP_CSS = fs.readFileSync(path.join(ROOT, "app.css"), "utf8");
const INDEX_HTML = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");

// ── comment stripping ────────────────────────────────────────────────────────

test("stripCssComments removes a comment and keeps the rules around it", () => {
  assert.equal(stripCssComments("a{x:1} /* note */ b{y:2}").replace(/\s+/g, " "),
    "a{x:1} b{y:2}");
});

test("a breakpoint mentioned INSIDE a comment contributes no axis — the load-bearing case", () => {
  const css = "/* the `@media (max-width: 720px)` shell fold */\n@media (max-width: 900px){.a{b:c}}";
  const r = parseMediaBreakpoints(css);
  assert.deepEqual(r.breakpoints, [900]);
  assert.equal(r.preludes.length, 1, "the commented @media must not count as a block");
  // the MUTATION: uncomment it and the axis grows — proving the assertion above
  // is not satisfied by a parser that simply never sees 720
  const uncommented = css.replace("/* the `", "").replace("` shell fold */", "{.z{y:1}}");
  assert.deepEqual(parseMediaBreakpoints(uncommented).breakpoints, [720, 900]);
});

test("an UNTERMINATED comment swallows the rest of the file rather than inventing rules", () => {
  assert.deepEqual(parseMediaBreakpoints("@media (max-width: 900px){.a{b:c}}\n/* oops\n@media (max-width: 500px){}").breakpoints, [900]);
});

// ── one comparison → one boundary ────────────────────────────────────────────

test("boundaryOf resolves each comparison to the last width on its low side", () => {
  assert.equal(boundaryOf("max", 720, "px"), 720);   // (max-width: 720px)
  assert.equal(boundaryOf("lt", 720, "px"), 719);    // (width < 720px)
  assert.equal(boundaryOf("min", 720, "px"), 719);   // (min-width: 720px) flips AT 720
  assert.equal(boundaryOf("gt", 720, "px"), 720);    // (width > 720px)
});

test("boundaryOf REFUSES a unit it will not guess at, and a fractional px", () => {
  assert.equal(boundaryOf("max", 50, "em"), null);
  assert.equal(boundaryOf("max", 30, "rem"), null);
  assert.equal(boundaryOf("max", 899.98, "px"), null);
});

// ── clause parsing ───────────────────────────────────────────────────────────

test("max-width and the equivalent range syntax resolve to ONE breakpoint", () => {
  assert.deepEqual(parseWidthClause("(max-width: 812px)").boundaries, [812]);
  assert.deepEqual(parseWidthClause("(width <= 812px)").boundaries, [812]);
});

test("min-width and its range twin agree, and land one BELOW the declared value", () => {
  assert.deepEqual(parseWidthClause("(min-width: 813px)").boundaries, [812]);
  assert.deepEqual(parseWidthClause("(width >= 813px)").boundaries, [812]);
  assert.deepEqual(parseWidthClause("(813px <= width)").boundaries, [812]);
});

test("a two-sided range yields BOTH edges", () => {
  assert.deepEqual(parseWidthClause("(400px <= width <= 800px)").boundaries.sort((a, b) => a - b), [399, 800]);
});

test("a non-width query is not width-bearing and is not an error", () => {
  const r = parseWidthClause("(prefers-reduced-motion: reduce)");
  assert.deepEqual(r.boundaries, []);
  assert.deepEqual(r.unresolved, []);
});

test("an UNREADABLE width is REFUSED, never silently dropped", () => {
  // This is the regression that shipped in the first draft: the parser CONSUMED
  // the token it could not resolve, so `(max-width: 50em)` produced an empty
  // boundary list AND an empty unresolved list — a whole breakpoint vanished
  // and the sweep exited 0.
  for (const clause of ["(max-width: 50em)", "(width <= 40rem)", "(min-width: calc(100% - 2px))"]) {
    const r = parseWidthClause(clause);
    assert.deepEqual(r.boundaries, [], `${clause} must contribute no boundary`);
    assert.equal(r.unresolved.length, 1, `${clause} must be REPORTED as unparseable`);
  }
});

test("a comma-separated prelude is judged clause by clause", () => {
  const r = parseMediaBreakpoints("@media (max-width: 620px), (min-width: 901px) {.a{b:c}}");
  assert.deepEqual(r.breakpoints, [620, 900]);
  assert.deepEqual(r.unresolved, []);
});

// ── the boundary walk ────────────────────────────────────────────────────────

test("boundaryWalk straddles every breakpoint and does NOT de-duplicate 899/900", () => {
  assert.deepEqual(boundaryWalk([768]), [767, 768, 769]);
  const w = boundaryWalk([899, 900]);
  assert.deepEqual(w, [898, 899, 900, 901]);
  assert.ok(w.includes(899) && w.includes(900),
    "adjacent breakpoints MERGE their walks without losing a width: 899 and 900 " +
    "one apart still yield 898/899/900/901, four widths, not three. That is the " +
    "property this assertion actually holds, and it is why dropping 900 from " +
    "BREAKPOINTS costs only the width 901 — 900 survives as 899+1. " +
    "(The reason this said until cch-w16-s8 — 'at exactly 900 the tier grid has " +
    "folded and the detail grid has not' — was FALSE when written: driven on " +
    "origin/main the tier grid computed TWO tracks at 899 (282.5/282.5), 900 " +
    "(283/283) AND 901 (283.5/283.5). It folded nowhere near 900.)");
});

// ── the artifact today ───────────────────────────────────────────────────────

test("app.css's declared axis is exactly the sweep's BREAKPOINTS, with nothing unreadable", () => {
  const r = parseMediaBreakpoints(APP_CSS);
  assert.deepEqual(r.breakpoints, BREAKPOINTS);
  assert.deepEqual(r.unresolved, []);
  // 12 widths, not 13: cch-w16-s8 dropped 900 from BREAKPOINTS with the CSS rule
  // that declared it, and the ONLY width that leaves is 901. 900 is still here,
  // walked as 899+1.
  assert.deepEqual(WIDTHS, [619, 620, 621, 719, 720, 721, 767, 768, 769, 898, 899, 900]);
});

test("the raw grep over-counts @media — comment-stripping is why the parser does not", () => {
  const raw = (APP_CSS.match(/@media/g) || []).length;
  const stripped = parseMediaBreakpoints(APP_CSS).preludes.length;
  assert.ok(raw > stripped, `raw grep ${raw} must exceed the parsed block count ${stripped} (app.css:2131 names a breakpoint inside a comment)`);
});

test("index.html's registered screens are exactly the screens CELLS drives", () => {
  const views = parseViewIds(INDEX_HTML);
  assert.equal(views.length, 13);
  assert.deepEqual([...views].sort(), COVERED_VIEWS);
});

test("parseViewIds counts section.view only — a nested non-view <section> is not a screen", () => {
  assert.deepEqual(
    parseViewIds('<section class="view" id="view-a"><section class="archives-panel" id="nope"></section></section>'),
    ["view-a"],
  );
});

// ── the coverage algebra, and its refusals ───────────────────────────────────

test("coverageReport is clean on today's artifact", () => {
  const r = coverageReport({ css: APP_CSS, html: INDEX_HTML });
  assert.equal(r.ok, true);
  assert.equal(r.cells, CELLS.length);
});

test("a NEW breakpoint the walk does not straddle is REFUSED, naming the missing widths", () => {
  const r = coverageReport({ css: APP_CSS + "\n@media (max-width: 812px){.p{c:r}}", html: INDEX_HTML });
  assert.equal(r.ok, false);
  assert.deepEqual(r.uncoveredBreakpoints, [{ b: 812, missing: [811, 812, 813] }]);
});

test("a NEW screen with no cell is REFUSED by name", () => {
  const r = coverageReport({ css: APP_CSS, html: INDEX_HTML + '<section class="view" id="view-fake"></section>' });
  assert.equal(r.ok, false);
  assert.deepEqual(r.uncoveredViews, ["view-fake"]);
});

test("a screen the sweep still drives after index.html DROPS it is refused as a phantom", () => {
  const r = coverageReport({ css: APP_CSS, html: INDEX_HTML.replace('<section class="view" id="view-env" hidden>', '<section class="gone" hidden>') });
  assert.equal(r.ok, false);
  assert.deepEqual(r.phantomViews, ["view-env"]);
});

test("THE IMPORT PROOF: the refusal reads the widths the sweep DRIVES, not a second literal", () => {
  // Shrink the real loop and the SAME artifact stops being covered. If the
  // refusal held its own copy of the axis, this would stay green.
  const shrunk = WIDTHS.filter((w) => w < 767 || w > 769);
  const r = coverageReport({ css: APP_CSS, html: INDEX_HTML, widths: shrunk });
  assert.equal(r.ok, false);
  assert.deepEqual(r.uncoveredBreakpoints, [{ b: 768, missing: [767, 768, 769] }]);
  // and the unshrunk table is genuinely clean, so the failure above is the
  // mutation talking and not a permanently-red assertion
  assert.equal(coverageReport({ css: APP_CSS, html: INDEX_HTML }).ok, true);
});

test("an unreadable width in the stylesheet REFUSES the whole run", () => {
  const r = coverageReport({ css: APP_CSS + "\n@media (max-width: 50em){.p{c:r}}", html: INDEX_HTML });
  assert.equal(r.ok, false);
  assert.equal(r.unresolved.length, 1);
});

// ── the cell table's own invariants ──────────────────────────────────────────

test("every cell carries a scenario, a hash, a view and a SENTINEL", () => {
  for (const c of CELLS) {
    for (const k of ["name", "scen", "hash", "view", "sentinel"]) {
      assert.ok(c[k] && String(c[k]).length, `cell ${c.name}: missing ${k}`);
    }
    assert.ok(c.hash.startsWith("#"), `cell ${c.name}: the hash is what ROUTES — ?scen= alone renders #overview`);
  }
});

// ── --cell selection, and the typo it must not swallow ───────────────────────
//
// RE-PROSED (cch-w16-s2). This test used to read "--cell must select exactly
// one", which stopped being true the moment `--cell a,b,c` shipped. Uniqueness
// is still the invariant that makes a NAME a key; what changed is that a filter
// now names a SET, and the interesting failure moved from "matches nothing" to
// "matches SOME of what you asked for".

test("cell names are unique — a name is a KEY, so --cell selects by name without ambiguity", () => {
  assert.equal(new Set(CELLS.map((c) => c.name)).size, CELLS.length);
});

test("--cell selects several cells, in the order asked, collapsing duplicates", () => {
  const r = selectCells(CELLS, "billing-trial,fleet,billing-trial");
  assert.deepEqual(r.cells.map((c) => c.name), ["billing-trial", "fleet"]);
  assert.deepEqual(r.unknown, []);
});

test("no --cell at all selects the whole table", () => {
  assert.equal(selectCells(CELLS, null).cells.length, CELLS.length);
});

test("THE TYPO MUST NOT NARROW SILENTLY: one unknown name in the list is REPORTED BY NAME", () => {
  // The disease this fix exists for: a comma split that keeps the old
  // `if (!cells.length)` guard leaves `--cell fleet,fleeet` selecting ONE cell
  // and printing `verdict clean`, exit 0 — a green for a sweep the operator
  // never asked for. The unknown set, not the selection's emptiness, is the
  // signal, and it must name the offender rather than the whole filter.
  const r = selectCells(CELLS, "fleet,fleeet");
  assert.deepEqual(r.unknown, ["fleeet"], "the unknown name must be reported individually");
  assert.equal(r.cells.length, 1, "and the naive split really would have narrowed to one — that is what makes this mutation real");
  // the positive twin, so the assertion above is the typo talking and not a
  // permanently-red check
  assert.deepEqual(selectCells(CELLS, "fleet,billing-trial").unknown, []);
});

test("a blank member is not an unknown cell called \"\"", () => {
  const r = selectCells(CELLS, "fleet, ,");
  assert.deepEqual(r.unknown, []);
  assert.deepEqual(r.cells.map((c) => c.name), ["fleet"]);
});

test("no sentinel is merely the screen's own container", () => {
  // A container-only sentinel is satisfied by an EMPTY state, which is the
  // precise false green clause 3 exists to kill.
  const containers = ["#overview-body", "#fleet-body", "#notif-body", "#sites-body",
    "#activity-body", "#token-list", "#members-body", "#env-body", "#operator-body",
    "#instance-body", "#site-body", "#instance-tabpanel", "#archives-body"];
  for (const c of CELLS) {
    assert.ok(!containers.includes(c.sentinel.trim()),
      `cell ${c.name}: "${c.sentinel}" is a container, not a populated-content sentinel`);
  }
});

// ── Q3's bar, and the shape that clears it ───────────────────────────────────
//
// THE PIN THAT USED TO LIVE HERE IS DELETED (cch-w15-s1). It allowed 745.88px —
// 2.27x this budget — at every width the shell fold owns, so Q3 was inert
// exactly where the defect was. Deleting it alone would have left FOLD_FRACTION
// referenced by NOTHING but the import: mutation-proven on the pre-deletion
// tree, `FOLD_FRACTION = 0.99` was green in this suite, green in Leg A, and it
// SILENCES the folded-shell reds. These two tests are the replacement, and both
// red under that mutation.

// The shell fold's cap, read from the shipped bytes rather than restated. The
// fold is the 720px block that stacks .app-shell into a column (charter D153:
// there is exactly one such rule, and the fold is never raised).
function foldCap() {
  const anchor = APP_CSS.indexOf(".app-shell { flex-direction: column; }");
  assert.ok(anchor > 0, "the shell-fold block must exist");
  const at = APP_CSS.lastIndexOf("@media (max-width: 720px)", anchor);
  const block = APP_CSS.slice(at, APP_CSS.indexOf("\n}\n", at) + 3);
  const m = block.match(/max-height:\s*calc\(\s*(\d+(?:\.\d+)?)vh\s*-\s*(\d+(?:\.\d+)?)px\s*\)/);
  assert.ok(m, "the folded strip must be capped by a vh-minus-topbar calc — a bare Nvh cap cannot be an identity");
  return { vh: Number(m[1]) / 100, minus: Number(m[2]) };
}

// The topbar the cap has to cancel, READ FROM THE SHIPPED BYTES rather than
// restated (review fix, cch-w15-s1-r). The identity below is `cap - TOPBAR = 4`;
// a hard-coded 56 would keep the test green while a taller topbar — a banner, a
// second chip row — silently ate the whole 4px margin the driven run measured.
// Deriving it means the growth reds HERE, in the cheap unit leg, instead of
// only in a browser leg nobody runs on every push.
function topbarHeight() {
  const at = APP_CSS.indexOf("\n.topbar {");
  assert.ok(at > 0, "the .topbar rule must exist — the fold cap is defined against its height");
  const block = APP_CSS.slice(at, APP_CSS.indexOf("\n}\n", at) + 3);
  const m = block.match(/height:\s*(\d+(?:\.\d+)?)px/);
  assert.ok(m, "the topbar must declare a fixed px height — a fluid topbar makes the fold cap unprovable here");
  return Number(m[1]);
}

test("the folded shell clears the fold bar at EVERY height, as an identity — not at one lucky phone", () => {
  const { vh, minus } = foldCap();
  // Driven in Chrome (--render, both themes): contentTop = cap + TOPBAR exactly.
  // That makes a bare `Nvh` cap a FRACTION of `N + TOPBAR/H`, worst at the
  // SMALLEST height — which is why the shipped 34vh read 0.4836 of H at
  // landscape 390 while passing casual inspection at 800.
  const TOPBAR = topbarHeight();
  const contentTop = (H) => vh * H - minus + TOPBAR;
  // 390 is the BINDING height (landscape 720x390), not 800.
  for (const H of [800, 667, 390]) {
    assert.ok(contentTop(H) <= FOLD_FRACTION * H,
      `contentTop ${contentTop(H)} exceeds the ${FOLD_FRACTION} bar (${FOLD_FRACTION * H}) at H=${H}`);
  }
  // Measured on the shipped shape: 316/320 @800, 262.8/266.8 @667, 152/156 @390 —
  // a CONSTANT 4px of margin, which only holds because the calc cancels the
  // topbar. Restate that as the identity, so a cap that merely happens to fit
  // one height cannot satisfy this test.
  assert.equal(minus - TOPBAR, 4, `the cap must cancel the topbar (calc(${vh * 100}vh - ${minus}px) over a ${TOPBAR}px bar), leaving a height-independent 4px margin — if the topbar grew, the cap must grow with it`);
  assert.equal(vh, FOLD_FRACTION, "the cap's fraction IS the bar — any other value makes the margin drift with height");
});

test("the fold bar is a real bar: it still REFUSES the 34vh shape this slice replaced", () => {
  // Anti-vacuity. A bar loose enough to pass everything is not a bar, and the
  // deletion above removed the only other thing that referenced FOLD_FRACTION.
  // The pre-fix shipped shape put .content at 0.34H + 56; at the binding height
  // that is 188.6px against a 156px budget. If FOLD_FRACTION ever loosens to
  // where that passes, Q3 has stopped measuring the defect it was built for.
  const oldShape = (H) => 0.34 * H + 56;
  for (const H of [800, 667, 390]) {
    assert.ok(oldShape(H) > FOLD_FRACTION * H,
      `FOLD_FRACTION ${FOLD_FRACTION} would ACCEPT the 34vh nav wall at H=${H} (${oldShape(H)} <= ${FOLD_FRACTION * H}) — the bar has gone inert`);
  }
  // And the pin's own number must never be acceptable again: 745.88 was the
  // measured wall, and it is 2.27x the budget at H=800.
  assert.ok(745.88 > FOLD_FRACTION * 800,
    "the nav wall the deleted pin allowed must still be a Q3 defect");
});

// ── Q2's named lists ─────────────────────────────────────────────────────────

test("hiding utilities are ENUMERATED, so a class merely containing 'hidden' is not skipped", () => {
  assert.ok(HIDING_UTILITIES.includes("visually-hidden"));
  assert.ok(!HIDING_UTILITIES.includes("is-hidden-until-hover"));
  assert.equal(HIDING_UTILITIES.some((u) => u.includes("*")), false, "no globs — a regex is what over-skips");
});

// ── the HEIGHT axis, both halves ─────────────────────────────────────────────
//
// The derived half is VACUOUSLY GREEN on today's app.css — it refuses nothing,
// because there is nothing to refuse. Two things follow, and both are pinned
// here: the vacuity must be TRUE (zero height-bearing @media, not "the parser
// missed them"), and the refusal must fire the moment one appears.

test("the height half of a prelude is no longer eaten by the width half", () => {
  // THE DEFECT, RESTATED AS A TEST. `(max-width: 720px) and (max-height: 400px)`
  // used to lose its height clause with NO unresolved entry: the width eater
  // consumed the only `width` token before the residue check, and the parser
  // was never asked about height at all.
  const clause = "(max-width: 720px) and (max-height: 400px)";
  assert.deepEqual(parseWidthClause(clause).boundaries, [720]);
  assert.deepEqual(parseWidthClause(clause).unresolved, []);
  assert.deepEqual(parseHeightClause(clause).boundaries, [400], "the height half must survive the width pass");
  const r = parseMediaBreakpoints(`@media ${clause} {.a{b:c}}`);
  assert.deepEqual(r.breakpoints, [720]);
  assert.deepEqual(r.heights, [400]);
});

test("a height query is not a width query, and vice versa", () => {
  assert.deepEqual(parseHeightClause("(max-width: 812px)").boundaries, []);
  assert.deepEqual(parseHeightClause("(max-width: 812px)").unresolved, []);
  assert.deepEqual(parseWidthClause("(max-height: 600px)").boundaries, []);
  assert.deepEqual(parseHeightClause("(max-height: 600px)").boundaries, [600]);
  assert.deepEqual(parseHeightClause("(height <= 600px)").boundaries, [600]);
});

test("an UNREADABLE height is REFUSED too, on the same terms as a width", () => {
  const r = parseMediaBreakpoints("@media (max-height: 40rem){.a{b:c}}");
  assert.deepEqual(r.heights, []);
  assert.equal(r.heightUnresolved.length, 1);
});

test("THE VACUITY IS REAL: app.css declares ZERO height-bearing @media today", () => {
  // If this ever stops being true the derived refusal stops being vacuous, and
  // the header line that SAYS it is vacuous has to change with it.
  const r = parseMediaBreakpoints(APP_CSS);
  assert.deepEqual(r.heights, [], "a height-bearing @media appeared — legA's 'VACUOUSLY GREEN' line is now a lie");
  assert.deepEqual(r.heightUnresolved, []);
});

test("a height-bearing @media the declared set does not carry is REFUSED by value", () => {
  const r = coverageReport({ css: APP_CSS + "\n@media (max-height: 600px){.p{c:r}}", html: INDEX_HTML });
  assert.equal(r.ok, false);
  assert.deepEqual(r.heights.uncovered, [600]);
  // and a height the set DOES carry is fine — the refusal is about coverage,
  // not about the mere existence of a height query
  assert.equal(coverageReport({ css: APP_CSS + "\n@media (max-height: 390px){.p{c:r}}", html: INDEX_HTML }).heights.uncovered.length, 0);
});

test("every declared HEIGHT carries a written reason, landscape 390 among them", () => {
  for (const h of HEIGHTS) {
    assert.ok(HEIGHT_REASONS[h] && HEIGHT_REASONS[h].length > 40, `height ${h} needs a written reason, not a number`);
  }
  assert.ok(HEIGHTS.includes(390), "390 is the BINDING height for the fold bar — a set without it cannot see the defect it was built for");
  assert.ok(HEIGHTS.includes(RENDER_HEIGHT), "the height Leg B actually renders at must be a member of the declared axis");
  assert.equal(Object.keys(HEIGHT_REASONS).length, HEIGHTS.length, "a reason for a height that is not declared is rot");
});

// ── the THEME axis, and the trap that would red it on day one ────────────────

test("the theme census is exactly 2, read from BOTH artifacts", () => {
  const members = parseThemeMembers(APP_CSS, INDEX_HTML);
  assert.deepEqual(members, ["dark", "light"]);
  assert.deepEqual(members, THEMES);
  // `light` is declared ONLY in the shell — app.css has no light selector — so
  // a CSS-only derivation would report a ONE-member axis and drive half of it.
  assert.deepEqual(parseThemeMembers(APP_CSS, "<html></html>"), ["dark"]);
});

test("THE DAY-ONE TRAP: data-bp-theme identity is NOT the theme axis", () => {
  // The console carries a second, orthogonal switch with FIVE values. A
  // derivation written as "any data-*theme* selector" derives SEVEN members and
  // reds on an untouched tree. This assertion is what stops that rewrite.
  const accents = accentIdentities(APP_CSS);
  assert.deepEqual(accents, ["charple", "ember", "evergreen", "fjord", "iris"]);
  for (const a of accents) {
    assert.ok(!parseThemeMembers(APP_CSS, INDEX_HTML).includes(a), `accent identity ${a} must not leak into the theme axis`);
  }
  // index.html's root carries BOTH attributes; only data-theme is a theme
  assert.deepEqual(parseThemeMembers("", '<html data-theme="light" data-bp-theme="evergreen">'), ["light"]);
});

test("the theme axis refuses in BOTH directions", () => {
  const added = coverageReport({ css: APP_CSS + '\n[data-theme="sepia"] .p{c:r}', html: INDEX_HTML });
  assert.equal(added.ok, false);
  assert.deepEqual(added.themes.uncovered, ["sepia"]);
  // removed: `light` lives only in the shell, so dropping it there is the whole
  // mutation — and it is why the sweep grew a BREAKPOINT_SWEEP_HTML seam
  const dropped = coverageReport({ css: APP_CSS, html: INDEX_HTML.replace(' data-theme="light"', "") });
  assert.equal(dropped.ok, false);
  assert.deepEqual(dropped.themes.phantom, ["light"]);
});

// ── axisCoverage, and the removed-breakpoint hole it pays ────────────────────

test("axisCoverage names both directions and is empty on an agreeing pair", () => {
  assert.deepEqual(axisCoverage([1, 2], [1, 2]), { uncovered: [], phantom: [] });
  assert.deepEqual(axisCoverage([1, 2, 3], [1, 2]).uncovered, [3]);
  assert.deepEqual(axisCoverage([1], [1, 2]).phantom, [2]);
});

test("A BREAKPOINT THE STYLESHEET DROPS IS REFUSED — the hole cch-w15-bl-lega-cannot-refuse-removed-breakpoint named", () => {
  // Before this, the sweep kept driving 899/900/901 against a rule that no
  // longer existed and printed four DERIVED breakpoints against a thirteen-width
  // walk under a green tick. cch-w16-s8 then reached that state for real by
  // deleting app.css's `max-width: 900px` tier rule, and this refusal caught it
  // (Leg A exit 2, `PHANTOM breakpoint 900px`).
  //
  // RE-ARMED ON 620, AND THE OBVIOUS RE-ARM IS VACUOUS. This used to mutate the
  // 900px declarations. With the tier rule gone the only 900 left in app.css is
  // `@media (min-width: 900px)`, and re-pointing at it PROVES NOTHING: 899 is
  // declared THREE times (`max-width: 899px` twice, plus that block), so the
  // axis reads [620,720,768,899] before AND after and `r.ok` comes back TRUE. A
  // byte-diff clamp (`assert.notEqual(css, APP_CSS)`) passes on that no-op too,
  // which is exactly the shape of guard this wave exists to stop shipping.
  //
  // So mutate BY VALUE onto an EXISTING breakpoint: 620 -> 720 removes 620 from
  // the derived axis without inventing a new one, and BREAKPOINTS still declares
  // it — a phantom, by construction.
  const css = APP_CSS.replace(/max-width: 620px/g, "max-width: 720px");
  // THE CLAMP IS A POST-CONDITION, NOT A BYTE DIFF: assert the property the
  // mutation was for — that no 620px declaration survives it — so a regex that
  // silently stops matching cannot leave this test asserting about unmutated
  // bytes. IF THIS LINE REDS, DO NOT DELETE IT: it means app.css grew a 620
  // declaration in a syntax this replace misses (range syntax `(width <= 620px)`,
  // a `min-width: 620px` complement, a different space run). Widen the mutation
  // to cover it; the clamp reding IS the guard working. It also reds on a
  // COMMENT that merely mentions 620px — the parser strips comments and this
  // count does not — and that is the one case where the fix is to reword the
  // comment (app.css:2131 is the standing precedent for a breakpoint named
  // inside one).
  assert.equal((css.match(/620px/g) || []).length, 0,
    "the 620px mutation left a 620px occurrence behind — app.css names 620 in a form " +
    "`max-width: 620px` does not match (range syntax `(width <= 620px)`, a `min-width` " +
    "complement, a different space run, or a comment), so the phantom below would be " +
    "proving nothing. Widen the mutation, never remove this clamp.");
  const r = coverageReport({ css, html: INDEX_HTML });
  assert.equal(r.ok, false);
  assert.deepEqual(r.phantomBreakpoints, [620]);
  assert.deepEqual(r.breakpoints, [720, 768, 899], "the mutation really did remove it — otherwise the refusal above is vacuous");
  // and the unmutated tree is clean, so this is the mutation talking
  assert.deepEqual(coverageReport({ css: APP_CSS, html: INDEX_HTML }).phantomBreakpoints, []);
});

// ── the SCENARIO axis: a committed literal that can actually lose ────────────

// cch-w16-s4 moved this census by one: `sites-on-instance` is the 100th
// scenario and the 75th residue entry. That is the point of a typed-out
// literal — a slice that adds a scenario has to come here and say so.
test("the census reconciles: 100 scenarios, 25 distinct covered by 26 cells, 75 residue over 13 families", () => {
  const r = scenarioReport({ scenarios: SCENARIOS });
  assert.equal(r.total, SCENARIO_NAMES.length);
  assert.equal(r.total, 100);
  assert.equal(r.cells, 26);
  assert.equal(r.distinctCovered, 25, "mixed-fleet is used twice — 26 cells cover 25 DISTINCT scenarios");
  assert.equal(r.residue, 75, "75 is the RESIDUE, not the census");
  assert.equal(r.families, 13);
  assert.equal(r.ok, true);
  assert.equal(Object.keys(SCENARIO_RESIDUE).length, 75, "the COMMITTED literal, counted from the committed bytes");
});

test("familyOf reads the artifact: pathname, else the deepLink head, else no-deeplink", () => {
  assert.equal(familyOf({ pathname: "/activate", deepLink: "#overview" }), "path:/activate");
  assert.equal(familyOf({ deepLink: "#instance/abc/timeline" }), "hash:#instance");
  assert.equal(familyOf({ deepLink: "#/invitations/accept?token=x" }), "hash:#");
  assert.equal(familyOf({}), "no-deeplink");
  // and every committed entry still agrees with the artifact it describes
  for (const [name, family] of Object.entries(SCENARIO_RESIDUE)) {
    assert.equal(familyOf(SCENARIOS[name]), family, `residue entry ${name} records ${family}`);
  }
});

test("every residue family has a written reason, and no reason outlives its family", () => {
  const used = new Set(Object.values(SCENARIO_RESIDUE));
  assert.equal(used.size, 13);
  for (const f of used) assert.ok(RESIDUE_FAMILY_REASONS[f] && RESIDUE_FAMILY_REASONS[f].length > 60, `family ${f} needs a written reason`);
  assert.deepEqual(Object.keys(RESIDUE_FAMILY_REASONS).filter((f) => !used.has(f)), []);
});

test("A 101st SCENARIO IS REFUSED BY NAME — and a self-derived allowlist would not have", () => {
  const grown = { ...SCENARIOS, "probe-hundredth": { label: "probe", deepLink: "#fleet", data: {} } };
  const r = scenarioReport({ scenarios: grown });
  assert.equal(r.ok, false);
  assert.deepEqual(r.unlisted, ["probe-hundredth"]);
  // THE VACUITY, DEMONSTRATED RATHER THAN ASSERTED: an allowlist computed from
  // the current residue absorbs this mutation silently, because it grows with
  // the artifact. That is why the 74 entries are typed out.
  const selfDerived = Object.fromEntries(
    Object.keys(grown).filter((n) => !CELLS.some((c) => c.scen === n)).map((n) => [n, familyOf(grown[n])]));
  assert.equal(scenarioReport({ scenarios: grown, residue: selfDerived }).unlisted.length, 0,
    "a computed allowlist can never refuse anything — it looks itemised and is 100% vacuous");
});

test("STALENESS IS FATAL: an entry naming a deleted scenario refuses, never logs", () => {
  const shrunk = { ...SCENARIOS };
  delete shrunk["fleet-v4"];
  const r = scenarioReport({ scenarios: shrunk });
  assert.equal(r.ok, false);
  assert.deepEqual(r.stale, ["fleet-v4"]);
});

test("a residue scenario that GAINS a cell refuses — the entry's reason has expired", () => {
  const cells = [...CELLS, { name: "probe-v4", scen: "fleet-v4", hash: "#fleet", view: "view-fleet", sentinel: ".fleet-row" }];
  const r = scenarioReport({ scenarios: SCENARIOS, cells });
  assert.equal(r.ok, false);
  assert.deepEqual(r.promoted, ["fleet-v4"]);
});

test("a residue entry whose route MOVED refuses — its reason is about a different screen now", () => {
  const moved = { ...SCENARIOS, "fleet-v4": { ...SCENARIOS["fleet-v4"], deepLink: "#operator" } };
  const r = scenarioReport({ scenarios: moved });
  assert.equal(r.ok, false);
  assert.deepEqual(r.drift, [{ name: "fleet-v4", was: "hash:#fleet", now: "hash:#operator" }]);
});

test("a cell pointed at a scenario that no longer exists refuses", () => {
  const r = scenarioReport({
    scenarios: SCENARIOS,
    cells: [...CELLS, { name: "probe", scen: "not-a-scenario", hash: "#fleet", view: "view-fleet", sentinel: ".fleet-row" }],
  });
  assert.equal(r.ok, false);
  assert.deepEqual(r.phantomCells, ["not-a-scenario"]);
});
