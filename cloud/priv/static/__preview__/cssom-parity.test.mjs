// cssom-parity.test.mjs — the resolver and the diff, proven without a browser.
//
// WHY THIS FILE EXISTS AT ALL. Until D222, cssom-parity.mjs carried ZERO `export`
// statements and called `main()` unconditionally at module scope, so nothing inside
// it could be driven except by launching Chrome over the whole roster — ~20s a shape,
// and a `process.exit()` at the end of every one. That is the same unexported-helper
// shape that made cch-w16-s7's criterion 3 unsatisfiable, and it is why the sidecar
// resolver's four merge shapes had only ever been OBSERVED through the instrument and
// never ASSERTED. A helper that expensive to probe is a helper nobody probes.
//
// TWO SUBJECTS, both of which passed GREEN on origin/main with the thing they
// describe already broken:
//
//   1. parseBaseline — "the FIRST non-comment line decides". A sidecar holding the
//      correct count and then a stale one exited 0 with PARITY PASS while the file
//      said two different things (driven on fc6ecdfdd6: rc=0). Three of the four
//      merge shapes were loud; that one was silent, and it is the shape a merge
//      keeping `ours` on top actually produces.
//
//   2. the diff — both sides were SETS, so a selector authored twice needed only ONE
//      of its two rules to reach the browser for MISSES to stay 0. The head counts
//      cannot see it either: the source still authors both.
//
// Every case here is written so it FAILS on the pre-D222 code. That is the only
// property that makes a test worth its bytes.

import test from "node:test";
import assert from "node:assert/strict";

import {
  authoredHeads,
  authoredIndex,
  baselineRefusal,
  cssomIndex,
  diffPopulations,
  duplicateCensus,
  parseBaseline,
  topLevelDuplicateHeads,
} from "./cssom-parity.mjs";

// The import above is itself an assertion: before the main guard, importing this
// module launched Chrome and exited the process, so this file could not have run at
// all. Reaching the first test IS the proof that the guard holds.
test("importing the module does not run the gate (the main guard holds)", () => {
  assert.equal(typeof parseBaseline, "function");
  assert.equal(typeof diffPopulations, "function");
});

// ── 1. THE FOUR SIDECAR SHAPES ───────────────────────────────────────────────
// The same four a merge can produce, in the same order the row drove them through
// HEADS_BASELINE=. The `rc` each produced on origin/main is quoted per case.

test("shape 1/4 — a single bare integer resolves (rc=0 on main, unchanged)", () => {
  const parsed = parseBaseline("# app.css authored-head baseline\n1342\n");
  assert.equal(parsed.count, 1342);
  assert.equal(parsed.payload.length, 1);
});

test("shape 2/4 — correct count FIRST then a stale one: THE SILENT SHAPE, now refused", () => {
  // On origin/main this exited 0 with PARITY PASS: parseBaseline returned 1342 and
  // the 9999 was invisible. It is the only one of the four that passed green.
  const text = "# app.css authored-head baseline\n1342\n# stale copy kept by a merge\n9999\n";
  const parsed = parseBaseline(text);
  assert.equal(parsed.count, null, "a sidecar holding two counts must not resolve to either");
  assert.equal(parsed.reason, "ambiguous");

  // The refusal must NAME BOTH INTEGERS AND THE LINES THEY SIT ON — a message that
  // will not say which lines it means costs the reader the minute this assertion
  // exists to save.
  const msg = baselineRefusal(parsed, { id: "app.css", path: "/tmp/two.baseline" });
  assert.match(msg, /GUARD \(exit 2\)/);
  assert.match(msg, /line 2: 1342/);
  assert.match(msg, /line 4: 9999/);
  assert.match(msg, /1342 on line 2, 9999 on line 4/);
});

test("shape 3/4 — stale count FIRST then the correct one (rc=1 on main) is now a refusal, not an accusation", () => {
  // On main this exited 1 — "BASELINE MISMATCH … sidecar baseline is 9999 (−8657)",
  // i.e. the gate accused the STYLESHEET of losing 8657 rules when the defect was in
  // the sidecar. Exit 1 is reserved for a fact about the CSS; this is a fact about
  // the environment, and the 1→2 move is the point of the assertion.
  const parsed = parseBaseline("# baseline\n9999\n# the real one, below\n1342\n");
  assert.equal(parsed.count, null);
  assert.equal(parsed.reason, "ambiguous");
  const msg = baselineRefusal(parsed, { id: "app.css", path: "/tmp/two.baseline" });
  assert.match(msg, /line 2: 9999/);
  assert.match(msg, /line 4: 1342/);
});

test("shape 4a/4 — prose only, zero integers (rc=2 on main, still 2)", () => {
  const parsed = parseBaseline("# prose only\n# no count at all\nthe head count moved, ask the author\n");
  assert.equal(parsed.count, null);
  assert.equal(parsed.reason, "not-an-integer");
  const msg = baselineRefusal(parsed, { id: "app.css", path: "/tmp/prose.baseline" });
  assert.match(msg, /line 3: the head count moved, ask the author/);
});

test("shape 4b/4 — conflict markers kept (rc=2 on main, still 2)", () => {
  const parsed = parseBaseline("<<<<<<< HEAD\n1342\n=======\n9999\n>>>>>>> origin/main\n");
  assert.equal(parsed.count, null);
  assert.equal(parsed.reason, "ambiguous");
  const msg = baselineRefusal(parsed, { id: "app.css", path: "/tmp/conflict.baseline" });
  assert.match(msg, /line 2: 1342/);
  assert.match(msg, /line 4: 9999/);
  assert.match(msg, /line 1: <<<<<<< HEAD/, "the marker lines are payload too, and are named");
});

// THE NARROWER RULE WOULD HAVE LOOSENED THE RESOLVER. "Exactly one bare INTEGER"
// passes a conflict whose second side is prose — the `<<<<<<<` and `>>>>>>>` lines
// then sail through a check that only looks at integers, and main's resolver
// (first-non-comment-line) would have REFUSED that same file. The rule is therefore
// positive: exactly one payload line, and it must be the integer.
test("a conflict with only ONE integer is still refused — the strict rule never loosens main's", () => {
  const parsed = parseBaseline("<<<<<<< HEAD\n1342\n=======\n# theirs had no count\n>>>>>>> origin/main\n");
  assert.equal(parsed.count, null);
  assert.equal(parsed.reason, "ambiguous");
});

test("an empty sidecar refuses as `empty`, not as a zero count", () => {
  const parsed = parseBaseline("# nothing but comments\n\n\n");
  assert.equal(parsed.count, null);
  assert.equal(parsed.reason, "empty");
  assert.match(baselineRefusal(parsed, { id: "app.css", path: "/tmp/e" }), /NO payload line at all/);
});

test("0 is a legitimate count and must not be confused with the null refusal", () => {
  // `if (baseline === null)` at the call site is why this matters: a resolver that
  // returned a falsy 0 would have been read as "unparseable" by a `!baseline` guard.
  const parsed = parseBaseline("# an empty rostered sheet\n0\n");
  assert.equal(parsed.count, 0);
});

test("trailing whitespace and CRLF do not make a sidecar unresolvable", () => {
  assert.equal(parseBaseline("# c\r\n  1342  \r\n").count, 1342);
});

// ── 2. THE MULTISET — A RULE LOST BEHIND ITS OWN DUPLICATE ───────────────────
// The fixture authors `.card` twice. The CSSOM side is handed only ONE `.card`,
// which is exactly what a browser dropping one of the two rules produces.

const DUPED = `
.card { padding: 8px; }
.other { color: red; }
.card { border: 1px solid; }
`;

test("a duplicated authored head is COUNTED, not collapsed", () => {
  const authored = authoredIndex(DUPED);
  assert.equal(authored.get(".card").count, 2, "first-wins collapsed this to one slot before D222");
  assert.equal(authored.get(".other").count, 1);
  assert.deepEqual(
    authored.get(".card").sites.map((s) => s.line),
    [2, 4],
    "every authored site is retained so a deficit can name them all",
  );
  // The REPORTED location stays the first site, so existing accusations read as before.
  assert.equal(authored.get(".card").line, 2);
});

test("THE HOLE: one of two `.card` rules never reaches the CSSOM — set semantics say 0 misses", () => {
  const authored = authoredIndex(DUPED);
  const cssom = cssomIndex([".card", ".other"]); // the browser produced ONE .card
  const { misses, deficits } = diffPopulations(authored, cssom);

  // This is the pre-D222 verdict, asserted rather than described: membership holds
  // for every authored key, so the old Set-vs-Set diff was empty and the gate exited
  // 0 with a rule missing from the browser.
  assert.equal(misses.length, 0, "the selector IS present — set membership cannot see the loss");

  // And this is the close.
  assert.equal(deficits.length, 1);
  assert.equal(deficits[0].key, ".card");
  assert.equal(deficits[0].authoredCount, 2);
  assert.equal(deficits[0].seen, 1);
  assert.deepEqual(deficits[0].sites.map((s) => s.braceLine), [2, 4]);
});

test("head counts and the sidecar are BLIND to it — the deficit is the only witness", () => {
  // The source is untouched, so authoredHeads() still returns 3 and any sidecar
  // pinned to 3 still matches. Nothing but the multiset can fire here.
  assert.equal(authoredHeads(DUPED).length, 3);
});

test("a clean tree produces ZERO deficits — the signal is silent when it should be", () => {
  const authored = authoredIndex(DUPED);
  const cssom = cssomIndex([".card", ".other", ".card"]);
  const { misses, deficits } = diffPopulations(authored, cssom);
  assert.equal(misses.length, 0);
  assert.equal(deficits.length, 0);
});

test("a fully absent selector is still a MISS, not a deficit — the two signals stay disjoint", () => {
  const authored = authoredIndex(DUPED);
  const { misses, deficits } = diffPopulations(authored, cssomIndex([".card", ".card"]));
  assert.deepEqual(misses.map((m) => m.key), [".other"]);
  assert.equal(deficits.length, 0);
});

test("a comma group contributes the same occurrence count to BOTH sides", () => {
  // The false-red this could have manufactured: if only one side split groups, every
  // grouped selector would read as a deficit. Both sides go through splitGroup().
  const authored = authoredIndex(`\n.a, .b { color: red; }\n`);
  const { misses, deficits } = diffPopulations(authored, cssomIndex([".a, .b"]));
  assert.equal(misses.length, 0);
  assert.equal(deficits.length, 0);
});

test("a selector nested in @media counts as its own occurrence on both sides", () => {
  const css = `\n.a { color: red; }\n@media (min-width: 40em) {\n  .a { color: blue; }\n}\n`;
  const authored = authoredIndex(css);
  assert.equal(authored.get(".a").count, 2);
  assert.equal(diffPopulations(authored, cssomIndex([".a", ".a"])).deficits.length, 0);
  assert.equal(diffPopulations(authored, cssomIndex([".a"])).deficits.length, 1);
});

// ── 3. THE DUPLICATE CENSUS — TWO POPULATIONS, EACH NAMING ITSELF ────────────
// The 8-vs-6 dispute was a population dispute (see the census note in the gate).
// These fixtures pin the two readings apart on a stylesheet small enough to count
// by eye, rather than pinning a number about app.css that goes stale every wave.

const CENSUS = `
html, body { height: 100%; }
body { margin: 0; }
:root { --a: 1px; }
@media (prefers-reduced-motion: reduce) {
  :root { --a: 0px; }
}
:root { --b: 2px; }
.solo { color: red; }
`;

test("the COMPARED population counts every depth — this is what the gate diffs", () => {
  const census = duplicateCensus(authoredIndex(CENSUS));
  assert.deepEqual(
    census.map((c) => [c.key, c.count]),
    [[":root", 3], ["body", 2]],
    "`:root` is authored twice at top level and once inside @media; `body` twice via the comma group",
  );
});

test("the TOP-LEVEL HEAD population excludes both the @media copy and the comma group", () => {
  const heads = topLevelDuplicateHeads(CENSUS);
  assert.deepEqual(
    heads.map((h) => [h.key, h.count]),
    [[":root", 2]],
    "`body` is authored ONCE as a head — its second flattened occurrence is `html, body`",
  );
});

test("depth is tracked so a nested head can never be mistaken for a top-level one", () => {
  const byLine = new Map(authoredHeads(CENSUS).map((h) => [h.head, h.depth]));
  assert.equal(byLine.get(".solo"), 0);
  const nested = authoredHeads(CENSUS).filter((h) => h.depth > 0);
  assert.equal(nested.length, 1);
  assert.equal(nested[0].head, ":root");
});

test("a stray `}` cannot push depth negative and hide later heads from the census", () => {
  const heads = authoredHeads(`\n}\n.a { color: red; }\n.a { color: blue; }\n`);
  assert.equal(heads.length, 2);
  assert.equal(topLevelDuplicateHeads(`\n}\n.a { color: red; }\n.a { color: blue; }\n`).length, 1);
});
