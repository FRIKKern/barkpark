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
  parseViewIds, boundaryWalk, coverageReport,
  BREAKPOINTS, WIDTHS, CELLS, COVERED_VIEWS, FOLD_FRACTION,
  HIDING_UTILITIES,
} from "./breakpoint-sweep.mjs";

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
    "at exactly 900 the tier grid has folded and the detail grid has not — they are different cells");
});

// ── the artifact today ───────────────────────────────────────────────────────

test("app.css's declared axis is exactly the sweep's BREAKPOINTS, with nothing unreadable", () => {
  const r = parseMediaBreakpoints(APP_CSS);
  assert.deepEqual(r.breakpoints, BREAKPOINTS);
  assert.deepEqual(r.unresolved, []);
  assert.deepEqual(WIDTHS, [619, 620, 621, 719, 720, 721, 767, 768, 769, 898, 899, 900, 901]);
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

test("cell names are unique — --cell must select exactly one", () => {
  assert.equal(new Set(CELLS.map((c) => c.name)).size, CELLS.length);
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

test("the folded shell clears the fold bar at EVERY height, as an identity — not at one lucky phone", () => {
  const { vh, minus } = foldCap();
  // Driven in Chrome (--render, both themes): contentTop = cap + TOPBAR exactly,
  // with the topbar an invariant 56px. That makes a bare `Nvh` cap a FRACTION of
  // `N + 56/H`, worst at the SMALLEST height — which is why the shipped 34vh read
  // 0.4836 of H at landscape 390 while passing casual inspection at 800.
  const TOPBAR = 56;
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
  assert.equal(minus - TOPBAR, 4, "the cap must cancel the topbar (calc(Nvh - 60px) over a 56px bar), leaving a height-independent 4px margin");
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
