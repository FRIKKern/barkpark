// same-document-nav-census.test.mjs — the arms for
// cch-w24-bl-hash-only-nav-is-same-document.
//
// TWO HALVES, AND THEY FAIL DIFFERENTLY.
//
//   THE RULE. `wouldBeSameDocument` is Chrome's navigation rule retyped into
//   JavaScript. If it is wrong, the guard silently stops guarding and every
//   instrument goes back to measuring inherited DOM on a green run — so the
//   arms below include the case a reader gets wrong (the IDENTICAL url) and the
//   cases a reader over-fires on (no fragment at all, a different query).
//
//   THE NET. The census reads SOURCE. Its failure mode is the opposite one:
//   quietly reporting zero because its scanner mis-sliced an argument. Every
//   scanner arm therefore asserts on a KNOWN ANSWER out of the real files —
//   and the last two arms are a live census of the shipped roster, which is the
//   only assertion that notices a new raw `Page.navigate` landing tomorrow.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  ANNOTATION,
  CELL_PARAM,
  census,
  censusRoster,
  createCrossDocumentNavigator,
  findNavSites,
  forceCrossDocument,
  formatCensus,
  guardedCallees,
  hasCellDiscriminator,
  segments,
  splitArgs,
  splitFragment,
  stripFragment,
  wouldBeSameDocument,
} from "./same-document-nav-census.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const read = (f) => fs.readFileSync(path.join(HERE, f), "utf8");

// ── 1. CHROME'S RULE ─────────────────────────────────────────────────────────

test("a fragment-only change keeps the document — the defect, in one line", () => {
  assert.equal(wouldBeSameDocument("http://x/?scen=a#settings/providers", "http://x/?scen=a#overview"), true);
});

test("THE CASE A READER GETS WRONG: the IDENTICAL url is also same-document", () => {
  // This is why overflow-guard's stated retry ("re-navigating once") was a
  // no-op on every URL carrying a fragment: navigating to the URL you are
  // already on does not reload it, it scrolls to the fragment.
  assert.equal(wouldBeSameDocument("http://x/?scen=a#overview", "http://x/?scen=a#overview"), true);
});

test("no fragment on the destination means a real load, however equal the rest", () => {
  assert.equal(wouldBeSameDocument("http://x/?scen=a", "http://x/?scen=a"), false);
  assert.equal(wouldBeSameDocument("http://x/?scen=a#overview", "http://x/?scen=a"), false);
});

test("a difference OUTSIDE the fragment is a real load — the whole trick", () => {
  assert.equal(wouldBeSameDocument("http://x/?scen=a&cell=1#overview", "http://x/?scen=a&cell=2#overview"), false);
  assert.equal(wouldBeSameDocument("http://x/?scen=a#overview", "http://x/?scen=b#overview"), false);
});

test("nothing navigated yet is never same-document", () => {
  assert.equal(wouldBeSameDocument(null, "http://x/?scen=a#overview"), false);
  assert.equal(wouldBeSameDocument("about:blank", "http://x/?scen=a#overview"), false);
});

test("stripFragment is total: a url with no hash is its own base", () => {
  assert.equal(stripFragment("http://x/?a=1"), "http://x/?a=1");
  assert.equal(stripFragment("http://x/?a=1#b/c#d"), "http://x/?a=1");
});

// ── 2. THE REWRITE ───────────────────────────────────────────────────────────

test("forceCrossDocument puts the discriminator BEFORE the fragment, not after", () => {
  const out = forceCrossDocument("http://x/?scen=a#settings/providers", "sdn1");
  assert.equal(out, `http://x/?scen=a&${CELL_PARAM}=sdn1#settings/providers`);
  // …and the point of doing so: the result is now a real load.
  assert.equal(wouldBeSameDocument("http://x/?scen=a#settings/providers", out), false);
});

test("forceCrossDocument opens a query string when there is none", () => {
  assert.equal(forceCrossDocument("http://x/#overview", "t"), `http://x/?${CELL_PARAM}=t#overview`);
  assert.equal(forceCrossDocument("http://x/", "t"), `http://x/?${CELL_PARAM}=t`);
});

test("a tag that would corrupt the query is escaped", () => {
  assert.equal(forceCrossDocument("http://x/?a=1", "b&c=2"), `http://x/?a=1&${CELL_PARAM}=b%26c%3D2`);
});

// ── 3. THE GUARD ─────────────────────────────────────────────────────────────

test("the guard rewrites ONLY what Chrome would have skipped", () => {
  const g = createCrossDocumentNavigator();
  assert.equal(g.next("http://x/?scen=a#providers"), "http://x/?scen=a#providers", "first navigation: untouched");
  const second = g.next("http://x/?scen=a#overview");
  assert.notEqual(second, "http://x/?scen=a#overview");
  assert.match(second, new RegExp(`[?&]${CELL_PARAM}=sdn1`));
  assert.equal(g.count, 1);
  // A genuinely different scenario is left exactly as the leg wrote it.
  assert.equal(g.next("http://x/?scen=b#overview"), "http://x/?scen=b#overview");
  assert.equal(g.count, 1);
});

test("REGRESSION SHAPE: the rewritten url is what the NEXT comparison uses", () => {
  // If the guard remembered the url it was ASKED for rather than the one it
  // navigated to, the cell after a rewrite would compare against a page the
  // browser is not on — and either fire spuriously or, worse, not fire.
  const g = createCrossDocumentNavigator();
  g.next("http://x/?s=a#one");
  const forced = g.next("http://x/?s=a#two");
  const third = g.next(forced);          // ask for exactly where we now are
  assert.notEqual(third, forced, "navigating to the current url is same-document too");
  assert.equal(g.count, 2);
});

test("reset() is what a fresh target buys — the next cell is not compared to the old one", () => {
  const g = createCrossDocumentNavigator();
  g.next("http://x/?s=a#one");
  g.reset();
  assert.equal(g.next("http://x/?s=a#one"), "http://x/?s=a#one", "a new target starts from about:blank");
  assert.equal(g.count, 0);
});

test("the guard SPEAKS ON A CLEAN RUN — a silent guard is indistinguishable from an absent one", () => {
  const g = createCrossDocumentNavigator();
  g.next("http://x/?s=a");
  assert.match(g.line(), /0 of this run's navigations were fragment-only/);
  // Note WHICH pair fires: `?s=a` -> `?s=a#one` is same-document too, because
  // the destination carries a fragment and the base is unchanged. A leg that
  // lands on a screen and then deep-links into it is the commonest shape here.
  g.next("http://x/?s=a#one");
  assert.match(g.line(), /1 navigation\(s\) would have been FRAGMENT-ONLY/);
  assert.match(g.line(), /\/\?s=a {2}→ {2}\/\?s=a#one/);
});

// ── 4. THE SCANNER ───────────────────────────────────────────────────────────

test("splitArgs survives a template literal holding commas, parens and quotes", () => {
  const src = "nav(`${BASE}/?scen=${scen}&theme=light#overview`, `document.querySelector('.a, .b')`)";
  const { args } = splitArgs(src, src.indexOf("("));
  assert.equal(args.length, 2);
  assert.equal(args[0].trim(), "`${BASE}/?scen=${scen}&theme=light#overview`");
});

test("splitArgs survives a nested template inside a ${} hole", () => {
  const src = "f(`a${g(`b,c`)}d`, 2)";
  const { args } = splitArgs(src, src.indexOf("("));
  assert.deepEqual(args.map((a) => a.trim()), ["`a${g(`b,c`)}d`", "2"]);
});

test("segments separates what the author typed from what only run time knows", () => {
  const segs = segments("`${BASE}/?scen=${scen}&theme=light#overview`");
  assert.deepEqual(segs.map((s) => s.kind), ["expr", "lit", "expr", "lit"]);
  assert.equal(segs[0].text, "BASE");
  assert.equal(segs[3].text, "&theme=light#overview");
});

test("segments reads across a `+` concatenation, which is how modal-oracle builds its url", () => {
  const expr = '`http://127.0.0.1:${port}/?scen=${s}` + (accent ? `&accent=${accent}` : "") + plan.suffix';
  const segs = segments(expr);
  assert.ok(segs.some((s) => s.kind === "lit" && s.text.includes("/?scen=")),
    "the literal query the author typed must survive the concatenation");
  assert.equal(segs[segs.length - 1].kind, "expr",
    "and the tail must stay a HOLE — plan.suffix is exactly where the fragment lives");
  // Which is the whole point: the fragment cannot be read out of this text, so
  // the census must refuse to claim there isn't one.
  assert.equal(splitFragment(expr).resolved, false);
});

test("splitFragment finds a LITERAL fragment and keeps the runtime holes in the base", () => {
  const f = splitFragment("`${BASE}/?scen=${scen}&theme=${theme}#overview`");
  assert.equal(f.base, "${BASE}/?scen=${scen}&theme=${theme}");
  assert.equal(f.frag, "#overview");
  assert.equal(f.resolved, true);
});

test("a fragment that could be hiding in a hole is UNRESOLVED, never assumed absent", () => {
  const f = splitFragment("`${BASE}/?scen=x&theme=${theme}${sc.deepLink}`");
  assert.equal(f.resolved, false);
  assert.equal(f.frag, null);
});

test("a wholly literal url with no fragment is resolved as HAVING no fragment", () => {
  const f = splitFragment('"http://127.0.0.1:9000/?scen=empty"');
  assert.equal(f.resolved, true);
  assert.equal(f.frag, "");
});

test("hasCellDiscriminator recognises W24-s1's own param and nothing else", () => {
  assert.equal(hasCellDiscriminator(segments("`${B}/?scen=${s}&cell=${tag}#overview`")), true);
  assert.equal(hasCellDiscriminator(segments("`${B}/?scen=${s}&cell=one#overview`")), false,
    "a CONSTANT cell param discriminates nothing — two cells would still share it");
  assert.equal(hasCellDiscriminator(segments("`${B}/?scen=${s}#overview`")), false);
});

// ── 5. THE NET, AGAINST THE REAL FILES ───────────────────────────────────────

test("guardedCallees is DERIVED from the bytes, not listed", () => {
  const guarded = guardedCallees(read("overflow-guard.mjs"));
  assert.ok(guarded.has("nav"), "overflow-guard's nav() routes through the navigator");
  // Strip the guard out of the helper's body and the verdict must follow.
  const unguarded = read("overflow-guard.mjs").replace(/crossDoc\.next\(url\)/g, "url");
  assert.equal(guardedCallees(unguarded).has("nav"), false,
    "a helper that loses its guard must stop being reported as guarded on the same edit");
});

test("THE MUTATION ARM: remove one fix and the census names the pair again", () => {
  const clean = census("overflow-guard.mjs", read("overflow-guard.mjs"));
  assert.equal(clean.open.length, 0, "the shipped file is clean");
  const mutated = census("overflow-guard.mjs", read("overflow-guard.mjs").replace(/crossDoc\.next\(url\)/g, "url"));
  assert.ok(mutated.open.length > 0, "removing the guard must red the census");
  const pair = mutated.open.find((p) => p.kind === "consecutive" && p.fragA === "#fleet" && p.fragB === "#overview");
  assert.ok(pair, "and it must name a CONCRETE pair, not just a count: #fleet → #overview");
  assert.equal(pair.file, "overflow-guard.mjs");
  assert.ok(pair.aLine > 0 && pair.bLine > pair.aLine);
});

test("every navigation site on the shipped roster has a verdict, and none is OPEN", () => {
  const reports = [];
  for (const f of ["overflow-guard.mjs", "breakpoint-sweep.mjs", "smoke.mjs", "modal-oracle.mjs", "cssom-parity.mjs"]) {
    reports.push(census(f, read(f)));
  }
  const { open } = formatCensus(reports);
  assert.equal(open, 0);
  for (const r of reports) {
    for (const s of r.sites) assert.notEqual(s.verdict, "OPEN", `${r.file}:${s.line} has no verdict`);
  }
});

test("THE TWO OUT-OF-SCOPE FILES ARE PROVEN out of scope, not assumed", () => {
  // smoke.mjs runs the SPA in a node:vm sandbox and cssom-parity.mjs injects an
  // inline <style> into a throwaway about:blank target per sheet. Neither
  // navigates, so neither can inherit a previous cell's DOM. That is a claim
  // about the bytes and it is checked here rather than written in a comment.
  for (const f of ["smoke.mjs", "cssom-parity.mjs"]) {
    assert.equal(findNavSites(read(f)).length, 0, `${f} must make no CDP navigation`);
    assert.equal(read(f).includes("Page.navigate"), false, `${f} must not mention Page.navigate`);
  }
});

test("the live roster census is green, and its report names the guarded helpers", async () => {
  const { text, open } = formatCensus(await censusRoster());
  assert.equal(open, 0, text);
  assert.match(text, /guarded helpers {5}nav\b/);
  assert.match(text, /guarded helpers {5}navSettle\b/);
  assert.match(text, /NO CDP NAVIGATION AT ALL/);
});

test(`a raw Page.navigate added tomorrow is caught — unless it carries ${ANNOTATION}`, () => {
  const base = 'const cells=[];\nfor (const c of cells) {\n  await cdp.send("Page.navigate", { url: `http://x/?s=1${c.hash}` }, s);\n}\n';
  assert.equal(census("new.mjs", base).open.length, 1, "an unannotated raw navigation is OPEN");
  const annotated = base.replace("await cdp.send", `// ${ANNOTATION} this cell reads only document.title\n  await cdp.send`);
  const r = census("new.mjs", annotated);
  assert.equal(r.open.length, 0);
  assert.equal(r.pairs[0].verdict, "REASONED");
  assert.equal(r.pairs[0].reason, "this cell reads only document.title",
    "the reason is carried into the report, so the claim is readable and not merely counted");
});
