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
  SHELL_CHROME_SELECTORS, SHELL_CHROME_CEILING, CHROME_PIN_ROW, foldVerdict,
  HIDING_UTILITIES, THEMES, HEIGHTS, HEIGHT_REASONS, RENDER_HEIGHT,
  RENDER_HEIGHTS_DEFAULT, heightDriveReport, cueAxisOfMask, cueStuckVerdict,
  selectNames,
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
  // 21 widths. cch-w16-s8 dropped 900 from BREAKPOINTS with the CSS rule that
  // declared it — the ONLY width that left is 901, since 900 is still walked as
  // 899+1 — taking this to 12. W17-S6 then added `@media (max-width: 830px)`
  // for the past-due money message, which brings 829/830/831 and takes it to 15.
  // W20-S8 added `@media (min-width: 621px) and (max-width: 740px)` for that
  // SAME message in the shell-fold band, which brings 739/740/741 and takes it
  // to 18 — the prelude's lower edge costs nothing, since 620 was already
  // declared and 621 is walked as 620+1. cch-w18-bl then re-derived the W20-S9
  // attention-name band's upper edge from 899 to 904 — the old edge was driven
  // against a fixture string the control plane does not write, and on the real
  // "Health unknown · Agent offline" the name column is cut from 900 through 904
  // — which brings 903/904/905 and takes it to 21. 903 and 905 are genuinely
  // new; 904 is not walked as 903+1 because 903 is itself only 904-1.
  // THIS LITERAL IS THE POINT: a CSS slice that adds or removes a breakpoint has
  // to come here and say which widths it moved. Leg A refuses either way, and it
  // DID refuse W17-S6's first draft ("UNCOVERED breakpoint 830px") and W20-S8's
  // ("UNCOVERED breakpoint 740px — the boundary walk is missing 739, 740, 741").
  assert.deepEqual(WIDTHS, [619, 620, 621, 719, 720, 721, 739, 740, 741, 767, 768, 769, 829, 830, 831, 898, 899, 900, 903, 904, 905]);
});

test("the raw grep over-counts @media — comment-stripping is why the parser does not", () => {
  const raw = (APP_CSS.match(/@media/g) || []).length;
  const stripped = parseMediaBreakpoints(APP_CSS).preludes.length;
  assert.ok(raw > stripped, `raw grep ${raw} must exceed the parsed block count ${stripped} (app.css:2131 names a breakpoint inside a comment)`);
});

test("index.html's registered screens are exactly the screens CELLS drives", () => {
  const views = parseViewIds(INDEX_HTML);
  assert.equal(views.length, 12);
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
  // cch-w53-bl env-var Option A: this leg used to mutate `view-env`, which the
  // team env-var deletion removed from index.html — a `.replace` whose needle
  // is gone is a SILENT no-op, so the mutation is asserted to have APPLIED
  // before the refusal is read. `view-members` is the sibling settings screen
  // and is cell-driven exactly as `view-env` was.
  const NEEDLE = '<section class="view" id="view-members" hidden>';
  assert.ok(INDEX_HTML.includes(NEEDLE), "the mutation's needle must exist, or this leg proves nothing");
  const mutated = INDEX_HTML.replace(NEEDLE, '<section class="gone" hidden>');
  assert.notEqual(mutated, INDEX_HTML, "the mutation must actually change the artifact");
  const r = coverageReport({ css: APP_CSS, html: mutated });
  assert.equal(r.ok, false);
  assert.deepEqual(r.phantomViews, ["view-members"]);
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

// ── Q3 MEASURES THE SCREEN; THE FOLDED SHELL IS PINNED SEPARATELY ────────────
//
// cch-w24-bl-q3-fold-budget-is-a-shell-property-at-320. The two tests above are
// about the CSS shape at the widths the boundary walk drives (619 and up). At
// 320 — a width the walk does not reach, and the one people actually hold — the
// SHIPPED numbers are these, measured on origin/main @327ffd96b with
// `--render --widths 320 --cell sites,billing-trial,overview-fleet`:
//
//   cell            aside.sidebar   header.topbar   .content   view-head
//   sites             0 → 260        260 → 344.5      344.5      368.5
//   overview-fleet    0 → 260        260 → 344.5      344.5      368.5
//   billing-trial     0 → 260        260 → 378.5      378.5      402.5
//
// `.content`'s top IS the topbar's bottom, to the pixel. So the old Q3 — the raw
// `.content` offset against 0.4H = 320 — was measuring the SHELL, was over
// budget on every screen tried, and no screen could have passed it.
const W24_AT_320 = {
  sites:          { chromeBottom: 344.5, contentTop: 344.5, anchorTop: 368.5 },
  "overview-fleet": { chromeBottom: 344.5, contentTop: 344.5, anchorTop: 368.5 },
  "billing-trial":{ chromeBottom: 378.5, contentTop: 378.5, anchorTop: 402.5 },
};
const V = (m, over = {}) => foldVerdict({ vh: 800, ...m, ...over });

test("THE ROW'S DEFECT: the OLD Q3 shape is unreachable at 320 on every screen measured", () => {
  // Anti-vacuity for everything below: if this ever passes, the split stopped
  // being a fix and started being a loosening.
  for (const [name, m] of Object.entries(W24_AT_320)) {
    assert.ok(m.contentTop > FOLD_FRACTION * 800,
      `${name}: the raw .content offset ${m.contentTop} must still bust the ${FOLD_FRACTION * 800}px budget — that IS the defect this row filed`);
  }
});

test("Q3 now measures the SCREEN: the same cells clear the budget with room, and the shell is what was over", () => {
  for (const [name, m] of Object.entries(W24_AT_320)) {
    const v = V(m);
    assert.equal(v.screenTop, 24, `${name}: the screen's first box starts 24px below the folded chrome at 320`);
    assert.equal(v.foldOver, false, `${name}: a 24px screen contribution must not read as below the fold`);
    assert.equal(v.budget, 320);
  }
  // At 900 the sidebar is a left COLUMN, so nothing is stacked above .content
  // and the chrome is the 56px topbar: measured screenTop 32.
  const wide = V({ chromeBottom: 56, contentTop: 56, anchorTop: 88 });
  assert.equal(wide.screenTop, 32);
  assert.equal(wide.foldOver, false);
  assert.equal(wide.chromeOver, false, "one ceiling covers the whole width axis — the unfolded chrome is far under it");
});

test("MUTATION — push a screen's first box past the budget and Q3 REDS", () => {
  // The browser-side mutation is `.view-head { margin-top: 400px }`; this is the
  // same arithmetic without a Chrome. 344.5 + 24 + 400 = 768.5.
  const pushed = V({ ...W24_AT_320.sites, anchorTop: 768.5 });
  assert.equal(pushed.screenTop, 424);
  assert.equal(pushed.foldOver, true, "a screen that puts 424px above its own first box must be a Q3 defect");
  assert.equal(pushed.chromeOver, false, "and it must NOT be blamed on the shell — the chrome did not move");
  // The bar is where it is claimed to be, on both sides of the edge.
  assert.equal(V({ ...W24_AT_320.sites, anchorTop: 344.5 + 320 }).foldOver, false, "exactly at budget is not over");
  assert.equal(V({ ...W24_AT_320.sites, anchorTop: 344.5 + 320.5 }).foldOver, true, "half a pixel over IS over");
});

test("MUTATION — grow the shell and the CHROME PIN reds, at the pixel", () => {
  // The browser-side mutation is `.topbar { padding-block: 8px }`; here it is
  // the number. The pin sits exactly ON the worst value origin/main prints, in
  // the FLEET_ROW_RESIDUAL shape this file already cites: it reds if the number
  // GROWS, by any amount.
  assert.equal(V({ ...W24_AT_320["billing-trial"], chromeBottom: SHELL_CHROME_CEILING }).chromeOver, false,
    "the shipped worst must be exactly AT the pin, not under it — slack is a shell that can grow unwatched");
  assert.equal(V({ ...W24_AT_320["billing-trial"], chromeBottom: SHELL_CHROME_CEILING + 0.5 }).chromeOver, true,
    "half a pixel of shell growth must red the pin");
  assert.equal(V({ ...W24_AT_320["billing-trial"], chromeBottom: SHELL_CHROME_CEILING + 16 }).chromeOver, true);
});

test("THE PIN IS THE WORST PRINTED NUMBER, NOT THE ONE THE FILING QUOTED", () => {
  // What the filing got wrong: it quotes 344.5 as "the folded chrome cost at
  // 320". That is the NARROWER of the two shipped values — billing-trial prints
  // 378.5 at the same width. A 344.5 pin would red billing-trial on the first
  // run, re-creating the unreachable-budget defect this row exists to remove.
  const printed = Object.values(W24_AT_320).map((m) => m.chromeBottom);
  assert.equal(Math.max(...printed), SHELL_CHROME_CEILING,
    "the ceiling must BE a value the instrument printed on origin/main — never arithmetic, never the narrower one");
  for (const [name, m] of Object.entries(W24_AT_320)) {
    assert.equal(V(m).chromeOver, false, `${name}: no shipped cell may be over the pin on the day it lands`);
    assert.equal(foldVerdict({ vh: 800, ...m, ceiling: 344.5 }).chromeOver, name === "billing-trial",
      `pinning at the filing's 344.5 would have refused billing-trial — which is why it is not the pin`);
  }
});

test("a probe that loses the chrome reports a WORSE number, never a better one", () => {
  // chromeBottom 0 is what a renamed .topbar/.sidebar produces. The verdict then
  // degenerates to the raw offset the old Q3 read — 402.5 at 320, over budget —
  // so the failure mode of the measurement is a RED, not a silent green.
  const blind = V({ ...W24_AT_320["billing-trial"], chromeBottom: 0 });
  assert.equal(blind.screenTop, 402.5);
  assert.equal(blind.foldOver, true, "losing the chrome must not be able to look like a pass");
});

test("the chrome selectors and the pin's row are NAMED, so the number can be re-derived", () => {
  assert.deepEqual(SHELL_CHROME_SELECTORS, ["aside.sidebar", "header.topbar"],
    "the folded chrome is an enumerated list — a class regex would sweep in a screen's own header");
  assert.equal(CHROME_PIN_ROW, "cch-w24-bl-q3-fold-budget-is-a-shell-property-at-320",
    "a pin without the row that set it is a number nobody can move deliberately");
});

// ── Q2's named lists ─────────────────────────────────────────────────────────

test("hiding utilities are ENUMERATED, so a class merely containing 'hidden' is not skipped", () => {
  assert.ok(HIDING_UTILITIES.includes("visually-hidden"));
  assert.ok(!HIDING_UTILITIES.includes("is-hidden-until-hover"));
  assert.equal(HIDING_UTILITIES.some((u) => u.includes("*")), false, "no globs — a regex is what over-skips");
});

// ── CUE_STUCK asks the CUE'S OWN AXIS ────────────────────────────────────────
//
// NOT A SOURCE REGEX, AND NOT A SECOND IMPLEMENTATION. cueStuckVerdict and
// cueAxisOfMask are the very functions the probe injects with .toString(), so
// these arms drive the code headless Chrome runs. What is asserted is the
// DECISION, on numbers that came off a real render — the mistake GR118 records
// is testing a story ABOUT the pixels, and the antidote is to feed the real
// decision function the real measurements.
//
// THE MEASUREMENT, DRIVEN (breakpoint-sweep.mjs --render --cell operator
// --widths 720 --theme light --height 800):
//   aside.sidebar.is-nav-clipped 40px vertical — clipped on y
//   (scrollHeight 503 > clientHeight 259) — the cue is telling the truth
// The same run on origin/main printed:
//   note CUE_STUCK operator/light@720: aside.sidebar.is-nav-clipped shows a
//   40px edge cue while it FITS

// The masks as the STYLESHEET authors them, read out of app.css rather than
// typed here — flip a `to bottom` to a `to right` in the artifact and this
// test moves with it.
const MASK_DECLS = [...APP_CSS.matchAll(/(?:^|[\s;{])mask-image:\s*([^;]+);/g)].map((m) => m[1].trim());

test("cueAxisOfMask reads the axis off every mask app.css actually ships", () => {
  assert.ok(MASK_DECLS.length >= 2, `expected the shipped masks; found ${MASK_DECLS.length}`);
  const axes = MASK_DECLS.map(cueAxisOfMask);
  assert.ok(axes.every((a) => a === "x" || a === "y"),
    `every shipped mask must resolve to ONE axis; got ${JSON.stringify(axes)} for ${JSON.stringify(MASK_DECLS)}`);
  // The two shapes this sweep has to tell apart, named by the property they carry.
  const navFade = MASK_DECLS.filter((d) => d.includes("--nav-fade"));
  const matrixFade = MASK_DECLS.filter((d) => d.includes("--set-matrix-fade"));
  assert.ok(navFade.length && matrixFade.length, "both cue masks must still be in app.css for this arm to mean anything");
  for (const d of navFade) assert.equal(cueAxisOfMask(d), "y", "--nav-fade is a VERTICAL mask — this is the defect's whole point");
  for (const d of matrixFade) assert.equal(cueAxisOfMask(d), "x", "--set-matrix-fade is a HORIZONTAL mask");
});

test("cueAxisOfMask reads the COMPUTED forms too — Chrome drops the default `to bottom`", () => {
  assert.equal(cueAxisOfMask("linear-gradient(rgb(0, 0, 0) calc(100% - 40px), rgba(0, 0, 0, 0))"), "y",
    "a gradient with NO direction token IS `to bottom` — reading it as unknown would make the vertical case guess");
  assert.equal(cueAxisOfMask("linear-gradient(to right, rgb(0, 0, 0) calc(100% - 48px), rgba(0, 0, 0, 0))"), "x");
  assert.equal(cueAxisOfMask("linear-gradient(90deg, rgb(0, 0, 0), rgba(0, 0, 0, 0))"), "x");
  assert.equal(cueAxisOfMask("linear-gradient(180deg, rgb(0, 0, 0), rgba(0, 0, 0, 0))"), "y");
  assert.equal(cueAxisOfMask("linear-gradient(to bottom right, rgb(0, 0, 0), rgba(0, 0, 0, 0))"), "both");
  // Unreadable — and unreadable must mean QUIETER, never louder (the caller
  // then asks BOTH axes, so it can never note about an axis it did not measure).
  assert.equal(cueAxisOfMask("none"), null);
  assert.equal(cueAxisOfMask(""), null);
  assert.equal(cueAxisOfMask("radial-gradient(circle, rgb(0,0,0), rgba(0,0,0,0))"), null);
});

// The folded sidebar as measured at 720x800, in one object, so every arm below
// is a MUTATION of one real render rather than four inventions.
const FOLDED_SIDEBAR = {
  cue: 40,
  maskImage: "linear-gradient(to bottom, rgb(0, 0, 0) calc(100% - 40px), rgba(0, 0, 0, 0))",
  scrollW: 720, clientW: 720,   // fits horizontally — which is ALL the old gate asked
  scrollH: 503, clientH: 259,   // and is 244px short vertically, which is why the cue is live
};

test("THE DEFECT: a VERTICALLY clipped strip with a VERTICAL cue is not stuck", () => {
  const v = cueStuckVerdict(FOLDED_SIDEBAR);
  assert.equal(v.note, false, "the cue is telling the truth — 503 does not fit in 259");
  assert.equal(v.axis, "y");
  assert.match(v.why, /scrollHeight 503 > clientHeight 259/);
  // THE OLD GATE, RESTATED, so this arm proves the AXIS changed the verdict and
  // not the numbers: a horizontal-only fit test says "it fits" on these very
  // measurements, which is the note origin/main printed 78 times.
  const oldGateSaysStuck = FOLDED_SIDEBAR.cue > 0 && !(FOLDED_SIDEBAR.scrollW > FOLDED_SIDEBAR.clientW + 1);
  assert.equal(oldGateSaysStuck, true,
    "if the horizontal-only gate did NOT fire on these numbers this arm is vacuous — it would be asserting a fix for a case that never reached the old code");
});

test("MUTATION: the note still fires on a cue live over something that FITS on the cue's own axis", () => {
  const fitsVertically = { ...FOLDED_SIDEBAR, scrollH: 259, clientH: 259 };
  const v = cueStuckVerdict(fitsVertically);
  assert.equal(v.note, true, "a 40px vertical fade over a strip that fits vertically IS stuck — the note must not have gone inert");
  assert.equal(v.axis, "y");
});

test("the HORIZONTAL twin decides on x, in both directions", () => {
  const matrix = {
    cue: 48,
    maskImage: "linear-gradient(to right, rgb(0, 0, 0) calc(100% - 48px), rgba(0, 0, 0, 0))",
    scrollW: 1029, clientW: 1000, scrollH: 300, clientH: 300,
  };
  assert.equal(cueStuckVerdict(matrix).note, false, "clipped on x with an x cue — honest");
  assert.equal(cueStuckVerdict({ ...matrix, scrollW: 1000 }).note, true, "fits on x with an x cue — stuck");
  // AND THE CROSS-AXIS CASE, which is the whole bug in one line: a HORIZONTAL
  // cue over a box clipped only VERTICALLY is stuck, and a vertical-only gate
  // would be exactly as wrong in that direction.
  assert.equal(cueStuckVerdict({ ...matrix, scrollW: 1000, scrollH: 900 }).note, true);
});

test("a cue the element does not OWN is not its note — the 78 descendant copies", () => {
  // svg.nav-ico inside the folded strip: --nav-fade is registered
  // `@property { inherits: false }`, so the child computes 0px. The 40px the
  // old arm reported came from the probe's own ancestor walk.
  assert.equal(cueStuckVerdict({ ...FOLDED_SIDEBAR, cue: 0, scrollW: 16, clientW: 16, scrollH: 16, clientH: 16 }).note, false);
  assert.match(APP_CSS, /@property\s+--nav-fade\s*\{[^}]*inherits:\s*false/,
    "this arm's premise IS the artifact: if --nav-fade ever starts inheriting, a descendant really does carry the cue and the ownership rule is wrong");
  assert.match(APP_CSS, /@property\s+--set-matrix-fade\s*\{[^}]*inherits:\s*false/);
});

test("an UNREADABLE mask asks BOTH axes — quieter, never louder", () => {
  const noMask = { cue: 12, maskImage: "none", scrollW: 100, clientW: 100, scrollH: 100, clientH: 100 };
  assert.equal(cueStuckVerdict(noMask).note, true, "fits on both axes with a live cue — still a note");
  assert.equal(cueStuckVerdict(noMask).axis, "both");
  assert.equal(cueStuckVerdict({ ...noMask, scrollH: 400 }).note, false, "clipped on EITHER axis is enough to silence an unnamed axis");
  assert.equal(cueStuckVerdict({ ...noMask, scrollW: 400 }).note, false);
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

// ── the height axis is DRIVEN, not merely declared ───────────────────────────
//
// cch-w16-bl-legb-drives-one-of-three-heights: HEIGHTS declared [390,667,800]
// and Leg B pinned setDeviceMetricsOverride to RENDER_HEIGHT, so two thirds of
// the declared axis was a wish. `--height a,b,c` drives them, refuses an
// undeclared value by name, and the run reconciles what it ASKED for against
// the window.innerHeight the cells REPORTED.
//
// DRIVEN (--render --cell operator --widths 720 --height 390,667,800):
//   ✓ heights — 3/3 declared height(s) DRIVEN and read back from
//     window.innerHeight: 390, 667, 800
//   ✓ Q3 fold — worst .content top per height: 390px -> 152 against a 156px
//     budget · 667px -> 262.8 against a 267px budget · 800px -> 316 / 320

test("--height selects declared heights BY NAME, in the order asked", () => {
  const r = selectNames(HEIGHTS.map(String), "800,390");
  assert.deepEqual(r.selected, ["800", "390"]);
  assert.deepEqual(r.unknown, []);
});

test("THE TYPO MUST NOT NARROW SILENTLY HERE EITHER: an undeclared height is REPORTED BY NAME", () => {
  const r = selectNames(HEIGHTS.map(String), "390,500,667");
  assert.deepEqual(r.unknown, ["500"], "the refusal has to be able to NAME 500 — 'no match' over the whole list is what lets a typo shrink a run");
  assert.deepEqual(r.selected, ["390", "667"], "and the two that matched are known, so the refusal can say what it is refusing INSTEAD of");
  // the MUTATION: declare 500 and the same call stops refusing — proving the
  // arm reads HEIGHTS rather than a second literal of it
  assert.deepEqual(selectNames([...HEIGHTS.map(String), "500"], "390,500,667").unknown, []);
});

test("the DEFAULT loop is ONE height, and the decision carries its own render counts", () => {
  assert.deepEqual(RENDER_HEIGHTS_DEFAULT, [RENDER_HEIGHT], "the default loop is a DECISION, and it is one height");
  assert.ok(HEIGHTS.includes(RENDER_HEIGHTS_DEFAULT[0]), "the default must be a member of the declared axis");
  // THE COST IS RECOUNTED FROM THE TABLES, not read off the prose. This is the
  // criterion "the default render-loop cost is stated with a number": the two
  // numerals in HEIGHT_REASONS are the ones CELLS/THEMES/WIDTHS/HEIGHTS
  // actually multiply out to, so a table that grows makes the sentence red
  // instead of quietly stale.
  const one = CELLS.length * THEMES.length * 1 * WIDTHS.length;
  const all = CELLS.length * THEMES.length * HEIGHTS.length * WIDTHS.length;
  assert.equal(one, 1050);
  assert.equal(all, 3150);
  const reason = HEIGHT_REASONS[RENDER_HEIGHT];
  assert.ok(reason.includes(String(one)), `HEIGHT_REASONS[${RENDER_HEIGHT}] must state the default-loop render count ${one}`);
  assert.ok(reason.includes(String(all)), `HEIGHT_REASONS[${RENDER_HEIGHT}] must state what walking all ${HEIGHTS.length} heights costs (${all})`);
  assert.ok(/--height/.test(reason), "and it must name the flag that opts in, or the decision is a dead end");
});

test("heightDriveReport is clean only when every ASKED height was MEASURED", () => {
  const ok = heightDriveReport({ asked: HEIGHTS, seen: new Set(HEIGHTS) });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.driven, [390, 667, 800]);
  assert.deepEqual(ok.undriven, []);
});

test("MUTATION — DROP ONE HEIGHT FROM THE DRIVE AND IT REFUSES BY VALUE", () => {
  // This IS the shipped defect, in the shape the run would now catch: the loop
  // asks for three and the viewport only ever became 800.
  const r = heightDriveReport({ asked: HEIGHTS, seen: new Set([800]) });
  assert.equal(r.ok, false, "asking for three heights and measuring one must NOT be reportable as covered");
  assert.deepEqual(r.undriven, [390, 667], "and it has to name WHICH — 390 is the binding height for the fold bar");
  assert.deepEqual(r.driven, [800]);
  // the origin/main shape exactly: --height 390 asked, RENDER_HEIGHT measured
  const pinned = heightDriveReport({ asked: [390], seen: new Set([800]) });
  assert.equal(pinned.ok, false);
  assert.deepEqual(pinned.undriven, [390]);
  assert.deepEqual(pinned.unasked, [800], "a viewport nobody asked for is its own refusal — the override did not take");
});

test("the Q3 fold budget is met at EVERY driven height, including landscape 390", () => {
  // The driven numbers above, re-derived rather than retyped: the shipped
  // `max-height: calc(40vh - 60px)` makes contentTop = 0.4H - 4 an identity,
  // so the margin is 4px at every height and the bar is FOLD_FRACTION * H.
  const measured = { 390: 152, 667: 262.8, 800: 316 };
  for (const h of HEIGHTS) {
    assert.ok(measured[h] != null, `height ${h} has no driven Q3 number quoted here`);
    assert.ok(measured[h] <= FOLD_FRACTION * h,
      `driven contentTop ${measured[h]} at H=${h} exceeds the ${FOLD_FRACTION} bar (${FOLD_FRACTION * h})`);
    assert.ok(Math.abs(measured[h] - (FOLD_FRACTION * h - 4)) < 1.5,
      `the identity contentTop = ${FOLD_FRACTION}H - 4 must hold at H=${h}: expected ~${FOLD_FRACTION * h - 4}, drove ${measured[h]}`);
  }
  // NOT VACUOUS: the 34vh shape this slice's predecessor replaced fails the
  // same comparison at the same heights.
  for (const h of HEIGHTS) assert.ok(0.34 * h + 56 > FOLD_FRACTION * h, `the old shape must still bust the bar at H=${h}`);
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
  // So mutate BY VALUE onto an EXISTING breakpoint: X -> Y removes X from the
  // derived axis without inventing a new one, and BREAKPOINTS still declares it
  // — a phantom, by construction.
  //
  // RE-ARMED AGAIN ON 740 (W20-S8), AND THE 620 RE-ARM WENT VACUOUS EXACTLY THE
  // WAY 900 DID. W20-S8's block is `@media (min-width: 621px) and (max-width:
  // 740px)`, and a `min-width: N` prelude parses as the boundary N-1 — the same
  // rule that keeps 899 alive through `@media (min-width: 900px)`. So 620 became
  // DOUBLY declared: mutating every `max-width: 620px` to 720 now leaves the
  // derived axis UNCHANGED at [620,720,740,768,830,899] and `r.ok` comes back
  // TRUE (driven, before this re-arm: this test failed on `r.ok` alone). 740 is
  // declared exactly ONCE in app.css, so `max-width: 740px` -> `max-width: 768px`
  // removes it and invents nothing. THE LESSON IS THE STANDING ONE: a mutation
  // aimed at a value some other rule ALSO declares proves nothing, and only
  // re-driving it says which value that is today.
  const css = APP_CSS.replace(/max-width: 740px/g, "max-width: 768px");
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
  assert.equal((css.match(/740px/g) || []).length, 0,
    "the 740px mutation left a 740px occurrence behind — app.css names 740 in a form " +
    "`max-width: 740px` does not match (range syntax `(width <= 740px)`, a `min-width` " +
    "complement, a different space run, or a comment), so the phantom below would be " +
    "proving nothing. Widen the mutation, never remove this clamp.");
  const r = coverageReport({ css, html: INDEX_HTML });
  assert.equal(r.ok, false);
  assert.deepEqual(r.phantomBreakpoints, [740]);
  assert.deepEqual(r.breakpoints, [620, 720, 768, 830, 899, 904], "the mutation really did remove it — otherwise the refusal above is vacuous");
  // and the unmutated tree is clean, so this is the mutation talking
  assert.deepEqual(coverageReport({ css: APP_CSS, html: INDEX_HTML }).phantomBreakpoints, []);
});

// ── the SCENARIO axis: a committed literal that can actually lose ────────────

// cch-w16-s4 moved this census by one: `sites-on-instance` is the 100th
// scenario and the 75th residue entry. That is the point of a typed-out
// literal — a slice that adds a scenario has to come here and say so.
// cch-w21-s3 moved it again: `fleet-cruel-content` was the 101st scenario and
// the 76th residue entry. THAT EDIT WAS FORCED, NOT OPTIONAL — the bare sweep
// exited 2 with `UNLISTED scenario "fleet-cruel-content"` and this test exited
// 1 on 100/75, which is exactly the "come here and say so" the literal exists
// to compel. Four numbers moved and every one of them is derived from
// `scenarioReport`, never typed from memory.
// cch-w25-s3 moved it, and both halves refused again:
// `site-deploy-rail-failed` — the first fixture in this harness to carry a
// deploy-rail STAGE entry — is the 102nd scenario and the 77th residue entry,
// and the sweep exited 2 while this test exited 1 on 101/76. The numbers below
// are `scenarioReport`'s, re-read after the entry landed.
// cch-w34-s6 REVIEW moved it: `overview-never-reported` — the
// first fixture for the never-reported state the slice made reachable — is the
// 103rd scenario and the 78th residue entry. It refused exactly as designed:
// this test exited 1 on 102/77 before these four numbers were re-read from
// `scenarioReport`, which is the literal doing its job on a REVIEW edit rather
// than a builder one.
// cch-w37-s6 moved it: `operator-me-unreadable` — the first fixture that can
// fail the /v1/me READ while keeping the account present, and therefore the
// first one to reach meState()=="failed" at all — is the 104th scenario and
// the 79th residue entry. It refused exactly as designed: the bare sweep
// exited 2 with `UNLISTED scenario "operator-me-unreadable" (family
// hash:#operator)` and this test exited 1 on 103/78 before the four numbers
// below were RE-READ from `scenarioReport` (charter D413 — cch-w35-s4's brief
// carried target numbers that were wrong; these are derived, never copied).
// cch-w38-s1 moved it: `panel-overview-member` — the first plain-member
// fixture outside GR33's settings scope, and the BEFORE/AFTER pin for the
// instance rail's authority answer — is the 105th scenario and the 80th
// residue entry. All three guards refused first, by name: the sweep exited 2
// on `UNLISTED scenario "panel-overview-member"`, smoke on `CENSUS: 1
// committed scenario(s) have NO expectation`, and this file failed FOUR tests
// (17, 21, 44, 47) on 104/79. The numbers below are `scenarioReport`'s,
// re-read after the entry landed.
// cch-w39-s1 moved it: `billing-me-unreadable` — the first fixture that fails
// the /v1/me read on a screen that makes a ROLE CLAIM (an owner told "Only
// the team owner can manage billing.") — is the 106th scenario and the 81st
// residue entry. It refused exactly as designed: the bare sweep exited 2 with
// `UNLISTED scenario "billing-me-unreadable" (family hash:#billing)` and this
// test exited 1 on 105/80 before the four numbers below were RE-READ from
// `scenarioReport` on the merged tree, never carried from the brief.
// cch-w45-s1 moved it by TWO: `members-admin-actor` and
// `members-peer-owner` — the first fixtures whose acting principal is not the
// roster's row 0, and so the first that can ask a rank-relative predicate about
// a row the actor does NOT outrank — are the 107th and 108th scenarios and the
// 82nd and 83rd residue entries. It refused exactly as designed: the bare sweep
// exited 2 with `UNLISTED scenario "members-admin-actor" (family hash:#settings)`
// (and the twin on the next line) and this test exited 1 on 106/81 before the
// five numbers below were RE-READ from `scenarioReport` on that slice's own
// merge base, never carried from the brief. (That sha is deliberately not
// spelled here: a merge base is stale the day after it is written, and this is
// the file that exists to stop typed numerals rotting.)
// cch-w29-bl-deploy-rail-live-site-open-still-nowrap moved it by ONE:
// `site-deploy-rail-live` — the first fixture in this harness able to render
// `.deploy-rail-live`, the rail's OTHER footer, and so the first that can measure
// the site URL inside it — is the 117th scenario and the 92nd residue entry. It
// refused exactly as designed: the bare sweep exited 2 with `UNLISTED scenario
// "site-deploy-rail-live" (family hash:#site)` and this test exited 1 on 119/93
// before the numbers below were RE-READ from `scenarioReport`. (It LANDED as the
// 120th/94th; cch-w53-bl's env-var Option A then deleted three scenarios and two
// residue entries beneath it — a chronicle ordinal is a landing SLOT, and the
// ceiling arm below re-reads the census rather than trusting the slot.) They are NOT
// 109/84: several scenarios landed between the block above and this one without
// writing a chronicle block, so the last typed ordinal is never the next slot —
// only the measured census is.
//
// cch-w47-s4 (D527) DERIVED THE TITLE. It used to carry the same five integers
// as a second copy that "no assertion can red" — true, and the reason the
// prescribed fix was a test that parses its own `t.name`. Building the title
// from `scenarioReport` instead DELETES the copy: there is no integer left to
// parse, no parser to maintain, and the harness prints the identical line. The
// five asserts below stay — they are what makes the derived title mean
// something rather than merely echo itself.
//
// task-9b96d39e0fa3d9e5 DELETED the "moved it a Nth time" counters from every
// block above and from the bare sweep's twins: the counter was a second copy
// of a fact the block ORDER already carries, and it rotted twice — two blocks
// both claiming "a fifth time", then an eighth with no sixth — which is D527's
// argument for deleting the title's integer copy, applied to prose. The
// ordinals that remain ("the Nth scenario and the Mth residue entry") are no
// longer unguarded: the chronicle arm below the residue parsers reads these
// bytes and reds on a duplicate landing slot, an out-of-order block, or an
// ordinal past the measured census.
const census = scenarioReport({ scenarios: SCENARIOS });
test(`the census reconciles: ${census.total} scenarios, ${census.distinctCovered} distinct covered by ${census.cells} cells, ${census.residue} residue over ${census.families} families`, () => {
  const r = scenarioReport({ scenarios: SCENARIOS });
  assert.equal(r.total, SCENARIO_NAMES.length);
  // cch-w53-bl env-var Option A (ruled 2026-09-02): 121 -> 118 scenarios
  // (`env-populated`, `env-write-once-409`, `env-member` deleted with the team
  // env-var feature) and 27 -> 25 cells (the `env` cell, plus the `env-editor`
  // cell that drove the SITE env-blob scenario at the now-deleted
  // `#settings/env` route). Residue 95 -> 94: two env entries left, `env-editor`
  // joined `hash:#site`, the family its own deepLink names. Every integer here
  // was RE-DERIVED after the rebase onto origin/main by running
  // `scenarioReport({scenarios: SCENARIOS})` against the merged tree and reading
  // what it printed — main had moved the census to 121/27/26/95 while this
  // branch was in flight, so the pre-rebase 117/25/24/93 was stale arithmetic.
  // cch-w50-s4 moved it by TWO in ONE commit: `billing-free-owner` (the
  // UNSUBSCRIBED owner — the first fixture ever to reach renderPlanState's
  // upsell arm) and `billing-support-plus` (the first `support_plus` fixture the
  // corpus has held at all). Total 118 -> 120, residue 94 -> 96. CELLS (25),
  // distinctCovered (24) and families (13) are DELIBERATELY UNMOVED: both land
  // in the residue, not a cell, so no cell is added and no scenario changes
  // which cell renders it; and `hash:#billing` already had five members, so two
  // more cannot create a 14th family — a family is created only by a residue
  // scenario whose `familyOf` is new, and both of these are `hash:#billing`.
  // Every integer here was RE-DERIVED at THIS branch's merge base by running
  // `scenarioReport({scenarios: SCENARIOS})` and reading the `>> scenarios`
  // line, never carried from the filing — whose 110->112 / 85->87 / 26 cells /
  // 25 distinct were all stale against a base that already measured
  // 118/25/24/94.
  // cch-w12-followup-login-fixture-gap moves it by ONE: `activity-identity-change`,
  // the corpus's ONLY fixture that answers POST /v1/auth/login with a session —
  // until it, route()'s own `status < 400` login branch was unreachable from
  // every committed scenario and no drive in this harness had ever completed a
  // sign-in. Total 120 -> 121, residue 96 -> 97. CELLS (25), distinctCovered
  // (24) and families (13) are DELIBERATELY UNMOVED: it lands in the residue,
  // not a cell, and its `familyOf` is `hash:#overview` — a family that already
  // had eleven members, so it cannot create a 14th. Its deepLink is #overview
  // and NOT #activity on purpose: `hash:#activity` is one of the two ZERO-residue
  // families this file names by hand ("the two ZERO-residue families are named"),
  // and a fixture landing there would silently retire that arm's subject. The
  // Activity screen it ends on is reached by a warm hash navigation inside
  // smoke.mjs, which is what the drive is measuring anyway.
  // Both integers were RE-DERIVED by RUNNING `node breakpoint-sweep.mjs` on this
  // branch and reading what it PRINTED, never by adding one.
  // cch-w49-s7 moves it by ONE: `billing-unconfigured`, the corpus's first
  // fixture to carry D554's `billing_capability` on the /v1/subscription 200 —
  // so the first from which the console's consumption of that key can be
  // asserted from rendered bytes rather than assumed. Total 121 -> 122, residue
  // 97 -> 98. CELLS (25), distinctCovered (24) and families (13) are
  // DELIBERATELY UNMOVED: it lands in the residue, not a cell, and its familyOf
  // is `hash:#billing` — a family that already had seven members, so it cannot
  // create a 14th. Both integers were RE-DERIVED by RUNNING `node
  // breakpoint-sweep.mjs` on this branch and reading the `>> scenarios` line it
  // PRINTED, never by adding one to the line above.
  // cch-w50-bl moves it by ONE: `billing-forever`, the corpus's first fixture on
  // the admin-granted `forever` comp tier — a plan the server CAN mint
  // (Billing.Subscription's @plans, Billing.grant_forever/1) that no scenario had
  // ever booted, which is why planName painting its raw slug and the
  // Manage-billing section silently vanishing were both invisible here. Total
  // 123 -> 124, residue 99 -> 100. CELLS (25), distinctCovered (24) and families
  // (13) are DELIBERATELY UNMOVED: it lands in the residue, not a cell, and its
  // familyOf is `hash:#billing` — a family that already had eight members, so it
  // cannot create a 14th. Both integers were RE-DERIVED by RUNNING `node
  // breakpoint-sweep.mjs` on this branch and reading the `>> scenarios` line it
  // PRINTED (`124 scenarios · 24 distinct covered by 25 cells · 100 residue over
  // 13 families`), never by adding one to the line above.
  assert.equal(r.total, 124);
  assert.equal(r.cells, 25);
  assert.equal(r.distinctCovered, 24, "mixed-fleet is used twice — 25 cells cover 24 DISTINCT scenarios");
  assert.equal(r.residue, 100, "100 is the RESIDUE, not the census");
  assert.equal(r.families, 13);
  assert.equal(r.ok, true);
  assert.equal(Object.keys(SCENARIO_RESIDUE).length, 100, "the COMMITTED literal, counted from the committed bytes");
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

// ── the residue's TYPED numerals: 21 of them, none of which could lose ───────
//
// WHAT THESE THREE ARMS OWN (charter D527). The census five (108/25/26/83/13)
// were already asserted above; what was NOT asserted is every OTHER typed
// number the residue carries — the 13 `// <family> — N` group headers inside
// the SCENARIO_RESIDUE literal, the 8 `These N` clauses inside
// RESIDUE_FAMILY_REASONS, and the two ZERO-residue family names in
// breakpoint-sweep.mjs's own header prose. TWO OF THEM WERE FALSE ON MAIN when
// these arms were written, and both were found BY these arms, not by reading:
// `// hash:#billing — 3` sat over FOUR entries (the sibling reason 142 lines
// above already said "These 4"), and the `hash:#overview` reason said "These 9"
// over TEN. The sweep RUNNER exits 0 under both — it derives its own report
// from the object, never from the comments above it, so it structurally cannot
// own this. Console gate runs THIS file, which is why the arms live here.
//
// WHY PARSE THE COMMITTED BYTES AT ALL. A comment is invisible to the module
// system: importing SCENARIO_RESIDUE gives the 83 pairs and nothing about the
// headers. The only way a header can be made to lose is to read the file as
// text — which is why the range clamp below is load-bearing rather than
// decorative.

const SWEEP_SRC = fs.readFileSync(path.join(HERE, "breakpoint-sweep.mjs"), "utf8");

// The bytes of the SCENARIO_RESIDUE literal, with each family header carried
// alongside its 1-based line number in breakpoint-sweep.mjs so a failure names
// the line to open.
function residueGroupHeaders(src = SWEEP_SRC) {
  const start = src.indexOf("export const SCENARIO_RESIDUE");
  assert.ok(start >= 0, "breakpoint-sweep.mjs no longer exports SCENARIO_RESIDUE as a literal — this parser has no range to read");
  const end = src.indexOf("\n};", start);
  assert.ok(end > start, "the SCENARIO_RESIDUE literal has no bare `};` terminator — the parse range is unbounded");
  const body = src.slice(start, end);
  const lineBase = src.slice(0, start).split("\n").length;
  const headers = [];
  for (const line of body.split("\n").entries()) {
    const [i, text] = line;
    const m = /^\s*\/\/\s+(\S+)\s+—\s+(\d+)\s*$/.exec(text);
    if (m) headers.push({ family: m[1], typed: Number(m[2]), line: lineBase + i });
  }
  return headers;
}

function derivedFamilyCounts(residue = SCENARIO_RESIDUE) {
  const counts = new Map();
  for (const family of Object.values(residue)) counts.set(family, (counts.get(family) || 0) + 1);
  return counts;
}

test("every `// <family> — N` header inside SCENARIO_RESIDUE is recounted from the literal itself", () => {
  const headers = residueGroupHeaders();
  const derived = derivedFamilyCounts();
  // THE REFORMAT TRIPWIRE, AND IT IS NOT DECORATION. The parser reads the bytes
  // between `export const SCENARIO_RESIDUE` and the FIRST bare `};`. A prettier
  // pass that collapses the object, or a nested literal that introduces an
  // earlier `};`, silently SHRINKS that range — every surviving header still
  // agrees, the loop still runs, and the arm goes vacuous-green over a fraction
  // of the file. Pinning the header COUNT against the derived family count is
  // what makes a shrunk range fatal instead of quiet. IF THIS REDS, the fix is
  // never to delete it: either a family lost its header, or the range moved.
  assert.equal(headers.length, derived.size,
    `parsed ${headers.length} group headers but the literal holds ${derived.size} families — ` +
    "either a family has no `// <family> — N` header, or the parse range shrank " +
    "(a reformat, or a nested `};` inside the literal) and this arm is reading a fraction of the file");
  for (const h of headers) {
    assert.ok(derived.has(h.family),
      `breakpoint-sweep.mjs:${h.line} heads a group for family ${h.family}, which no residue entry uses`);
    assert.equal(h.typed, derived.get(h.family),
      `breakpoint-sweep.mjs:${h.line} types \`// ${h.family} — ${h.typed}\` over ${derived.get(h.family)} entries`);
  }
  const summed = headers.reduce((a, h) => a + h.typed, 0);
  assert.equal(summed, Object.keys(SCENARIO_RESIDUE).length,
    `the ${headers.length} typed group headers sum to ${summed} against a literal of ${Object.keys(SCENARIO_RESIDUE).length} entries`);
  // and every family the literal uses is headed exactly once
  assert.deepEqual([...new Set(headers.map((h) => h.family))].sort(), [...derived.keys()].sort());
});

test("every `These N` clause in RESIDUE_FAMILY_REASONS is recounted from the literal", () => {
  const derived = derivedFamilyCounts();
  // HONEST COVERAGE, STATED RATHER THAN IMPLIED: this arm checks only the
  // reasons that actually SPELL a count. Five families phrase their reason
  // without one ("Routes whose head is a bare `#`…", the modal family,
  // /activate, /new, #signup) and are SKIPPED here — untouched by this arm, not
  // proven by it. Their membership is still pinned, but by the header arm
  // above, which covers all 13. A reason that GAINS a `These N` joins this arm
  // automatically; one that loses it silently leaves — which is the honest cost
  // of guarding prose, and the reason the header arm is the one that counts
  // families.
  const checked = [];
  const skipped = [];
  for (const [family, reason] of Object.entries(RESIDUE_FAMILY_REASONS)) {
    const m = /These (\d+)/.exec(reason);
    if (!m) { skipped.push(family); continue; }
    checked.push(family);
    assert.equal(Number(m[1]), derived.get(family),
      `RESIDUE_FAMILY_REASONS["${family}"] says "These ${m[1]}" over ${derived.get(family)} entries`);
  }
  assert.equal(checked.length + skipped.length, Object.keys(RESIDUE_FAMILY_REASONS).length);
  assert.ok(checked.length > 0, "no reason spells a count any more — this arm has gone vacuous and should be retired, not kept green");
});

test("the two ZERO-residue families are named, and 15 families over all scenarios is not 13", () => {
  // breakpoint-sweep.mjs's header prose is the ONE place a reader learns that
  // `familyOf` over all scenarios gives 15 while the residue spans 13. It was
  // asserted by nothing. These three lines are that assertion.
  const allFamilies = new Set(Object.values(SCENARIOS).map((s) => familyOf(s)));
  const residueFamilies = derivedFamilyCounts();
  assert.equal(allFamilies.size, 15, "familyOf over every committed scenario");
  const zeroResidue = [...allFamilies].filter((f) => !residueFamilies.has(f)).sort();
  assert.deepEqual(zeroResidue, ["hash:#activity", "hash:#sites"],
    "the families every one of whose scenarios is rendered by a cell");
  // the relation, derived rather than typed: 15 - 13 IS the two above
  assert.equal(allFamilies.size - residueFamilies.size, zeroResidue.length);
});

// ── the HEADER-CENSUS arm: the sweep's own summary line can actually lose ────
// (cchi-w22-bl-breakpoint-sweep-prose-says-75.) The `SCENARIO  N scenarios,
// N rendered, N in a COMMITTED residue literal` line at the top of
// breakpoint-sweep.mjs carried 100/75 for a wave after the census moved to
// 101/76 — three typed numbers, four lines above a paragraph written to make
// exactly this staleness fatal, and no arm read them. The census test above
// asserts the DERIVED report against typed constants in THIS file; nothing
// asserted the sweep's own header. This arm reads that line from the committed
// bytes and recounts every numeral from scenarioReport. THE MATCH-COUNT FLOOR
// IS LOAD-BEARING (same law as the chronicle arm below): a wording drift that
// slid out from under the regex would leave this arm vacuous-green — if the
// floor reds, re-point the regex at the new wording, never delete the arm.
test("the sweep's SCENARIO header line is recounted from the derived report", () => {
  const r = scenarioReport({ scenarios: SCENARIOS });
  const matches = [...SWEEP_SRC.matchAll(/SCENARIO\s+(\d+) scenarios, (\d+) rendered, (\d+) in a COMMITTED residue literal/g)];
  assert.equal(matches.length, 1,
    "match-count floor: the SCENARIO header wording slid out from under this regex " +
    "(or a second copy appeared) — re-point the regex at the wording on disk, never lower the floor");
  const [, total, rendered, residue] = matches[0];
  assert.equal(Number(total), r.total,
    `the header says ${total} scenarios; scenarioReport derives ${r.total}`);
  assert.equal(Number(rendered), r.distinctCovered,
    `the header says ${rendered} rendered; scenarioReport derives ${r.distinctCovered} distinct covered`);
  assert.equal(Number(residue), r.residue,
    `the header says ${residue} in the residue literal; scenarioReport derives ${r.residue}`);
});

// ── the CHRONICLE arm: the census history's ordinals can actually lose ───────
// For fifteen days the chronicle above the census test — and its twin in
// breakpoint-sweep.mjs — carried TWO blocks claiming the SAME landing slot
// (104/79: one true, one an ort-resolution artifact), and every harness stayed
// green: no assertion read the prose, and D527 had deleted the title's integer
// copy on purpose. A comment cannot be derived — but it CAN be read. This arm
// cannot recount history (no run can learn which fixture landed in which
// slot), so it asserts the three properties every true chronicle has and the
// rotted one lacked: per file, scenario ordinals strictly increase, residue
// ordinals strictly increase, and no ordinal exceeds the measured census.
// Strict increase is also the prose half of the 104->105 precedent: two green
// PRs each chronicling the same next slot now red the union instead of merging
// silently. THE MATCH-COUNT FLOOR IS LOAD-BEARING: a wording drift that slid
// out from under these regexes would otherwise leave the arm vacuous-green,
// which is the exact failure mode it exists to end. If the floor reds,
// re-point the regex at the new wording — never lower the floor below the
// blocks already on disk.
const TEST_SRC = fs.readFileSync(fileURLToPath(import.meta.url), "utf8");
function chronicleOrdinals(src) {
  // the chronicle is hard-wrapped comment prose; join continuation lines so an
  // ordinal split across a line break ("the 104th\n// scenario") still matches
  const flat = src.replace(/\n\s*\/\/ ?/g, " ");
  const out = { scenario: [], residue: [] };
  for (const m of flat.matchAll(/\b(?:is|was|are) the (\d+)(?:st|nd|rd|th)(?: and (\d+)(?:st|nd|rd|th))? scenarios?\b/g)) {
    out.scenario.push(Number(m[1]));
    if (m[2]) out.scenario.push(Number(m[2]));
  }
  for (const m of flat.matchAll(/\bthe (\d+)(?:st|nd|rd|th)(?: and (\d+)(?:st|nd|rd|th))? residue entr(?:y|ies)\b/g)) {
    out.residue.push(Number(m[1]));
    if (m[2]) out.residue.push(Number(m[2]));
  }
  return out;
}
test("the chronicle's ordinals strictly increase and stay inside the census — in this file and the bare sweep", () => {
  const r = scenarioReport({ scenarios: SCENARIOS });
  for (const [file, src] of [["breakpoint-sweep.test.mjs", TEST_SRC], ["breakpoint-sweep.mjs", SWEEP_SRC]]) {
    const ordinals = chronicleOrdinals(src);
    for (const [axis, ords, ceiling] of [["scenario", ordinals.scenario, r.total], ["residue", ordinals.residue, r.residue]]) {
      assert.ok(ords.length >= 9,
        `${file}: only ${ords.length} ${axis} ordinals matched (floor 9) — the chronicle wording drifted out from under this arm; re-point the regex, never lower the floor`);
      for (let i = 1; i < ords.length; i += 1) {
        assert.ok(ords[i] > ords[i - 1],
          `${file}: ${axis} ordinal ${ords[i]} does not follow ${ords[i - 1]} — either two blocks claim the same landing slot (the 104/79 rot) or a block sits out of landing order`);
      }
      assert.ok(ords[ords.length - 1] <= ceiling,
        `${file}: the chronicle claims ${axis} ordinal ${ords[ords.length - 1]} but the measured census ceiling is ${ceiling}`);
    }
  }
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
