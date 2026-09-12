// view-scope-census.test.mjs — the pure half of the hidden-view residue census.
//
// EVERY ASSERTION HERE IS MUTATION-SHAPED: each one names a way the census can
// go quietly wrong (a walk it stops seeing, a selector it misclassifies as
// anchored, a register that only reds in one direction) and fails on that shape
// rather than on a snapshot of today's numbers. The one count it does pin is a
// FLOOR, not an equality: a census of a 10k-line guard that suddenly reads two
// walks has been defeated by a rename, and that is the failure this file exists
// to make loud.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  censusWalks,
  censusTally,
  classifySelector,
  documentWideSelectors,
  registerDrift,
  viewHostOfIds,
  RESIDUE_REGISTER,
  LIVE_VIEW_SELECTOR,
  SINGULAR_REGISTER,
  singularCensus,
  classifyCardinality,
  walkKey,
  registerKey,
  grepCounts,
} from "./view-scope-census.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GUARD = fs.readFileSync(path.join(HERE, "overflow-guard.mjs"), "utf8");
const INDEX = fs.readFileSync(path.join(HERE, "..", "index.html"), "utf8");

test("classifySelector: a bare class is document-wide", () => {
  assert.equal(classifySelector(".fleet-row"), "document-wide");
  assert.equal(classifySelector(".detail-rail .status-pill"), "document-wide");
  assert.equal(classifySelector('.inst-tab[aria-current="page"]'), "document-wide");
});

test("classifySelector: an id-anchored selector is one host, not a view sweep", () => {
  assert.equal(classifySelector("#members-body .set-row"), "id-anchored");
  assert.equal(classifySelector("#view-site *"), "id-anchored");
  assert.equal(classifySelector("#cred-submit"), "id-anchored");
});

test("classifySelector: the scoped idiom is recognised wherever it appears", () => {
  assert.equal(classifySelector(LIVE_VIEW_SELECTOR), "live-view");
});

test("classifySelector: page chrome outside every view cannot be inherited", () => {
  assert.equal(classifySelector("header.topbar"), "global-chrome");
  assert.equal(classifySelector("main.content"), "global-chrome");
});

test("classifySelector: a comma list is only as anchored as its WEAKEST arm", () => {
  // THE MUTATION THIS CATCHES: reading only the first arm. `#new-body, #new-body *`
  // is genuinely anchored; `#new-body, .new-step` is not, and a first-arm rule
  // would call both safe.
  assert.equal(classifySelector("#new-body, #new-body *"), "id-anchored");
  assert.equal(classifySelector("#new-body, .new-step"), "document-wide");
  assert.equal(classifySelector(".new-theater-grid,.new-theater-rail,.new-step"), "document-wide");
});

test("classifySelector: an attribute selector is document-wide, not anchored", () => {
  assert.equal(classifySelector("[data-w29-probe]"), "document-wide");
});

test("censusWalks: the guard's own bytes yield a census far above any floor", () => {
  const walks = censusWalks(GUARD);
  const t = censusTally(walks);
  assert.ok(t.total >= 150, `census read ${t.total} walks out of overflow-guard.mjs — a defeated pattern, not a clean file`);
  assert.ok(t["document-wide"] >= 50, `only ${t["document-wide"]} document-wide walks`);
  assert.ok(t["live-view"] >= 20, `only ${t["live-view"]} walks scoped to the live view`);
  assert.equal(t.total, walks.length);
  assert.equal(
    t.total,
    t["document-wide"] + t["id-anchored"] + t["live-view"] + t["global-chrome"] + t.unresolved,
    "the tally must partition the census — a walk counted in no bucket is a walk nobody looks at",
  );
});

test("censusWalks: a whole-line comment is prose and is not censused", () => {
  // The guard's header quotes its own selectors constantly. Counting them would
  // put the census's documentation in the census.
  const src = [
    "// document.querySelectorAll('.not-a-walk')",
    "  * document.querySelector('.also-prose')",
    "const x = document.querySelectorAll('.real-walk');",
  ].join("\n");
  const walks = censusWalks(src);
  assert.equal(walks.length, 1);
  assert.equal(walks[0].selector, ".real-walk");
});

test("censusWalks: a trailing comment after real code does NOT hide the walk", () => {
  const src = "const x = document.querySelectorAll('.real'); // document.querySelector('.prose')";
  const walks = censusWalks(src);
  // Two call sites on the line: skipping the line would hide the real one.
  assert.equal(walks.length, 2);
  assert.equal(walks[0].selector, ".real");
});

test("censusWalks: a runtime-built selector is NAMED unresolved, never dropped", () => {
  const src = [
    "const q = '.x';",
    "const a = document.querySelectorAll(q);",
    "const b = document.querySelectorAll(`#${id} .y`);",
    "const c = document.querySelectorAll(JSON.stringify(sel));",
  ].join("\n");
  const walks = censusWalks(src);
  assert.equal(walks.length, 3);
  for (const w of walks) assert.equal(w.kind, "unresolved");
  assert.deepEqual(walks.map((w) => w.selector), [null, null, null]);
});

test("censusWalks: the real guard still carries unresolved sites, and they are named", () => {
  const walks = censusWalks(GUARD);
  const u = walks.filter((w) => w.kind === "unresolved");
  assert.ok(u.length > 0, "zero unresolved sites would mean the pattern stopped seeing template-built selectors");
  for (const w of u) assert.ok(Number.isInteger(w.line) && w.line > 0);
});

test("censusWalks: every walk is attributed to the leg whose block it sits in", () => {
  const src = [
    'if (requested.includes("LEG-A")) {',
    "  document.querySelectorAll('.a');",
    "}",
    'if (requested.includes("LEG-B")) {',
    "  document.querySelector('.b');",
    "}",
  ].join("\n");
  const walks = censusWalks(src);
  assert.deepEqual(walks.map((w) => [w.leg, w.selector]), [["LEG-A", ".a"], ["LEG-B", ".b"]]);
});

test("censusWalks: code above the first leg is attributed to the prologue, not to a leg", () => {
  const walks = censusWalks("document.querySelector('.x');\n");
  assert.equal(walks[0].leg, "(prologue)");
});

test("censusWalks: the singular and the plural form are told apart", () => {
  const walks = censusWalks("document.querySelector('.a');\ndocument.querySelectorAll('.a');\n");
  assert.deepEqual(walks.map((w) => w.all), [false, true]);
});

test("documentWideSelectors: distinct selectors, with every owning leg and line", () => {
  const src = [
    'if (requested.includes("LEG-A")) {',
    "  document.querySelectorAll('.shared');",
    "}",
    'if (requested.includes("LEG-B")) {',
    "  document.querySelector('.shared');",
    "  document.querySelectorAll('#anchored .x');",
    "}",
  ].join("\n");
  const dw = documentWideSelectors(censusWalks(src));
  assert.equal(dw.length, 1, "the id-anchored walk must not appear in the document-wide list");
  assert.equal(dw[0].selector, ".shared");
  assert.deepEqual(dw[0].legs, ["LEG-A", "LEG-B"]);
  assert.equal(dw[0].lines.length, 2);
  assert.equal(dw[0].all, true, "a selector walked ALL anywhere is an element WALK");
});

test("registerDrift: a NEW exposure with no committed row is refused by name", () => {
  const d = registerDrift({ ".new-one": { hidden: 2, views: ["view-fleet"] } }, []);
  assert.equal(d.unregistered.length, 1);
  assert.match(d.unregistered[0], /\.new-one/);
  assert.match(d.unregistered[0], /view-fleet/);
});

test("registerDrift: a row nobody can reproduce is ALSO refused — the ratchet has two directions", () => {
  // A ratchet that only reds when the world gets worse is half an instrument.
  const reg = [{ selector: ".gone", views: ["view-overview"] }];
  const d = registerDrift({ ".gone": { hidden: 0, views: [] } }, reg);
  assert.equal(d.stale.length, 1);
  assert.equal(d.unregistered.length, 0);
  assert.match(d.stale[0], /\.gone/);
});

test("registerDrift: a registered selector the measurement never mentions is stale, not silently ok", () => {
  // THE MUTATION: keying only off `measured` would let a row survive forever
  // once the tour stopped reaching the selector at all.
  const d = registerDrift({}, [{ selector: ".never-measured", views: ["view-site"] }]);
  assert.equal(d.stale.length, 1);
});

test("registerDrift: the same count in a DIFFERENT view is reported as moved, not as ok", () => {
  const reg = [{ selector: ".x", views: ["view-overview"] }];
  const d = registerDrift({ ".x": { hidden: 3, views: ["view-sites"] } }, reg);
  assert.equal(d.moved.length, 1);
  assert.equal(d.ok.length, 0);
  assert.match(d.moved[0], /view-overview/);
  assert.match(d.moved[0], /view-sites/);
});

test("registerDrift: view order is not a finding", () => {
  const reg = [{ selector: ".x", views: ["view-sites", "view-instance"] }];
  const d = registerDrift({ ".x": { hidden: 4, views: ["view-instance", "view-sites"] } }, reg);
  assert.deepEqual(d.moved, []);
  assert.deepEqual(d.stale, []);
  assert.deepEqual(d.ok, [".x"]);
});

test("RESIDUE_REGISTER: every committed row names a selector the census still walks", () => {
  // THE ROT THIS CATCHES: a walk is deleted or scoped, and its register row
  // lives on certifying a condition no line of the guard can produce.
  const dw = new Set(documentWideSelectors(censusWalks(GUARD)).map((e) => e.selector));
  for (const row of RESIDUE_REGISTER) {
    assert.ok(dw.has(row.selector), `RESIDUE_REGISTER carries ${row.selector}, which is no longer a document-wide walk in overflow-guard.mjs`);
    assert.ok(Array.isArray(row.views) && row.views.length > 0, `${row.selector} has no views`);
    assert.ok(typeof row.legs === "string" && row.legs.length > 0, `${row.selector} names no owning leg`);
    assert.equal(row.status, "latent");
  }
});

test("RESIDUE_REGISTER: no selector is registered twice", () => {
  const seen = new Set();
  for (const row of RESIDUE_REGISTER) {
    assert.ok(!seen.has(row.selector), `${row.selector} is registered twice — one of the two rows can never be reached`);
    seen.add(row.selector);
  }
});

test("viewHostOfIds: index.html's view sections claim the ids inside them", () => {
  const hosts = viewHostOfIds(INDEX);
  assert.equal(hosts["members-body"], "view-members");
  assert.equal(hosts["activity-body"], "view-activity");
  assert.equal(hosts["provider-connect"], "view-providers");
  assert.equal(hosts["overview-body"], "view-overview");
});

test("viewHostOfIds: an id outside every view is UNCLAIMED, never assigned to one", () => {
  const hosts = viewHostOfIds(INDEX);
  // #modal-root is the overlay host, a sibling of <main>, not a view's child.
  assert.equal(hosts["modal-root"], undefined);
});

test("viewHostOfIds: an id app.js paints at runtime is absent, and absence is not a clean answer", () => {
  const hosts = viewHostOfIds(INDEX);
  // The guard reaches plenty of ids the shipped markup does not carry. The
  // function must return undefined for them rather than inventing a host.
  assert.equal(hosts["cred-token"], undefined);
});

test("the guard registers the leg that drives this census", () => {
  assert.match(GUARD, /"W35-hash-nav-hidden-view-residue"/);
  assert.match(GUARD, /requested\.includes\("W35-hash-nav-hidden-view-residue"\)/);
});

// ─────────────────────────────────────────────────────────────────────────────
//  THE CARDINALITY HALF (task-39ebd948f40660e3)
// ─────────────────────────────────────────────────────────────────────────────
//  Same rule as every assertion above: each test names a way the singular census
//  can go quietly wrong, and fails on THAT shape. The two that matter most are
//  the two reds — an unregistered walk and a register row nobody can reach —
//  because a register that can only say "fine" is not an instrument.

test("singularCensus: a bare singular walk with no reason is UNREGISTERED", () => {
  const src = [
    'if (requested.includes("LEG-A")) {',
    "  document.querySelector('.row');",
    "}",
  ].join("\n");
  const c = singularCensus(src, []);
  assert.equal(c.unregistered.length, 1);
  assert.match(c.unregistered[0], /LEG-A :: \.row/);
  assert.equal(c.stale.length, 0);
});

test("singularCensus: a register row matching no walk is STALE — staleness is fatal (D180)", () => {
  const src = 'if (requested.includes("LEG-A")) {\n  document.querySelector("#only-id");\n}\n';
  const c = singularCensus(src, [{ leg: "LEG-A", selector: ".gone", reason: "a walk that was deleted" }]);
  assert.equal(c.stale.length, 1);
  assert.match(c.stale[0], /LEG-A :: \.gone/);
  // THE CONTROL FOR THE CONTROL: the same source with no register is clean on
  // the stale arm, so the row above is what produced the red, not the source.
  assert.equal(singularCensus(src, []).stale.length, 0);
});

test("singularCensus: a leg that WALKS THE SAME SELECTOR plurally prints the population, and owes no row", () => {
  const src = [
    'if (requested.includes("LEG-A")) {',
    "  document.querySelector('.row');",
    "  document.querySelectorAll('.row').length;",
    "}",
  ].join("\n");
  const c = singularCensus(src, []);
  assert.equal(c.unregistered.length, 0);
  assert.equal(c.sites[0].discharge, "counted-in-leg");
  // THE MUTATION: the SAME plural walk in a DIFFERENT leg discharges nothing.
  const other = [
    'if (requested.includes("LEG-A")) {',
    "  document.querySelector('.row');",
    "}",
    'if (requested.includes("LEG-B")) {',
    "  document.querySelectorAll('.row').length;",
    "}",
  ].join("\n");
  assert.equal(singularCensus(other, []).unregistered.length, 1);
});

test("classifyCardinality: a DESCENDANT of the live view is a population, not the view host", () => {
  // THE MUTATION THIS CATCHES: discharging every selector that CONTAINS the
  // scoped idiom. `section.view:not([hidden])` is one element by construction;
  // `section.view:not([hidden]) .fleet-row` is five rows on mixed-fleet, and a
  // singular read of it is exactly the defect this census exists to find.
  const host = { leg: "L", selector: LIVE_VIEW_SELECTOR, all: false, arg: null };
  const row = { leg: "L", selector: `${LIVE_VIEW_SELECTOR} .fleet-row`, all: false, arg: null };
  assert.equal(classifyCardinality(host, new Set(), []), "live-view-host");
  assert.equal(classifyCardinality(row, new Set(), []), "unregistered");
});

test("classifyCardinality: an id is one host only when it is the LAST compound", () => {
  const idc = (sel) => classifyCardinality({ leg: "L", selector: sel, all: false, arg: null }, new Set(), []);
  assert.equal(idc("#cred-token"), "singleton-id");
  assert.equal(idc("#modal-root #cred-token"), "singleton-id");
  // An id ANCESTOR with a class terminal is a population under one host —
  // `#overview-body .instance-card` is five cards, and the old scope census
  // calls it "id-anchored". That classification answers a different question.
  assert.equal(idc("#overview-body .instance-card"), "unregistered");
});

test("classifyCardinality: an UNRESOLVED site can never be discharged by another leg's plural walk", () => {
  // MEASURED WHILE WRITING THIS: keying an unresolved site as `leg :: null`
  // collided with any other runtime-built plural walk in the same leg and
  // silently discharged three of the guard's six unresolved sites against a
  // count of something else.
  const src = [
    'if (requested.includes("LEG-A")) {',
    "  document.querySelector(`.${a} .x`);",
    "  document.querySelectorAll(`.${b} .y`).length;",
    "}",
  ].join("\n");
  const c = singularCensus(src, []);
  assert.equal(c.unregistered.length, 1);
  assert.match(c.unregistered[0], /«/);
});

test("walkKey / registerKey: a register row and the walk it discharges spell the same key", () => {
  const w = { leg: "L", selector: ".x", arg: null, all: false };
  assert.equal(walkKey(w), registerKey({ leg: "L", selector: ".x", reason: "r" }));
  const u = { leg: "L", selector: null, arg: "${sel}')", all: false };
  assert.equal(walkKey(u), registerKey({ leg: "L", arg: "${sel}')", reason: "r" }));
});

test("THE GUARD'S OWN BYTES: every singular walk is discharged and every register row is reachable", () => {
  const c = singularCensus(GUARD);
  assert.deepEqual(c.unregistered, [], "a singular walk in overflow-guard.mjs prints no population and carries no committed reason");
  assert.deepEqual(c.stale, [], "a SINGULAR_REGISTER row matches no walk in overflow-guard.mjs — staleness is fatal (D180)");
  // A FLOOR, never an equality: a census of this guard that suddenly reads a
  // handful of singular walks has been defeated by a rename, not cleaned up.
  assert.ok(c.sites.length > 120, `only ${c.sites.length} singular walks censused`);
  assert.ok(SINGULAR_REGISTER.length > 0);
});

test("SINGULAR_REGISTER: every row carries a real one-line reason, and no row is written twice", () => {
  const seen = new Set();
  for (const r of SINGULAR_REGISTER) {
    const k = registerKey(r);
    assert.ok(!seen.has(k), `${k} is registered twice — one of the two rows can never be reached`);
    seen.add(k);
    assert.ok(typeof r.reason === "string" && r.reason.trim().length > 20, `${k} carries no reason worth reading`);
    assert.ok(!/\bTODO\b/.test(r.reason), `${k} carries a placeholder reason`);
  }
});

test("grepCounts: the header's three numbers are DERIVED, and the guard no longer types them", () => {
  // THE ROT THIS CATCHES: overflow-guard.mjs's header carried `68 occurrences /
  // 55 lines / 15 All` as hand-typed literals. Measured on this tree the file is
  // an order of magnitude past all three. The numbers now come from here.
  const g = grepCounts(GUARD);
  assert.ok(g.occurrences > 200, `querySelector( occurrences read ${g.occurrences}`);
  assert.ok(g.lines > 200 && g.lines <= g.occurrences);
  assert.ok(g.allOccurrences > 50);
  assert.equal(grepCounts("a.querySelector(x); b.querySelectorAll(y);").occurrences, 1, "the two patterns must stay disjoint");
  assert.equal(grepCounts("a.querySelector(x); b.querySelectorAll(y);").allOccurrences, 1);
  // And the guard must not have grown a new hand-typed pair beside them.
  assert.ok(!/querySelector\[\(\][^\n]*→\s*\d+/.test(GUARD), "the guard's header has typed a selector count again instead of pointing at this census");
});
