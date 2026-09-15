/**
 * The web type ladder has ONE source: design/tokens.json, compiled by
 * design/emit.mjs into lib/tokens.gen.ts. This file is the WEB half of that
 * guard — it asserts the shape the web consumes and that the consumer restates
 * nothing. The other half (emitted NUMBERS === tokens.json numbers) lives in
 * design/check.mjs Part C2; what lives here is the STEP SET and its ORDER.
 *
 * WHY THE EXPECTED SIDE IS DERIVED, NOT TYPED (task-84a6c4bcd988fa44).
 * Until this change the assertion below read
 *
 *     assert.deepEqual([...chromeTypeOrder], ["2xl","xl","lg","base","sm","xs"]);
 *
 * — a SECOND HAND-TYPED COPY of the very list it was guarding, which is the
 * same defect the file's own prose (below) warns about one paragraph later.
 * A retyped expected side asserts the stale set against the stale set: it stays
 * green while the mirror is already wrong, and it reds for the wrong reason the
 * day the real source legitimately moves. It did exactly that. 1234c1c65
 * (PR #17942, spd-b11) added the `2xs` and `3xs` rungs to design/tokens.json
 * and to the emitted module; the literal here never moved, and the test has
 * failed on main ever since — reddening the web job on every unrelated head
 * that touches web/. Adding two strings to the literal would have bought a few
 * weeks and reproduced the defect, so the expected side now comes OUT of
 * design/tokens.json at test time.
 *
 * AND THE DERIVATION REFUSES RATHER THAN GOING BLIND. A parser that stops
 * matching would derive an empty ladder and `deepEqual([], [])` would pass:
 * clean-looking and completely blind. `ladderFrom` throws REFUSING TO MEASURE
 * on an unreadable file, on unparseable JSON, and on every malformed family in
 * design/ladder-refusal-fixture.json, and the two control tests below drive
 * those arms in-process so the refusal cannot itself rot. The malformed-family
 * half is SHARED with design/emit.mjs' typeLadderFrom and design/validate.mjs'
 * chromeLadderAscending — see the conformance-table block below and
 * design/ladder-refusal-conformance.test.mjs. That refuse-on-empty arm is
 * scripts/console-path-escape-check.test.sh case 6's, applied here.
 *
 * ORDER, NOT ONLY MEMBERSHIP. Display order is not tokens.json's key order —
 * tokens.json lists `type.chrome` smallest-first — it is DESCENDING SIZE, which
 * is the contract the emitted comment states ("largest → smallest") and the
 * second test below independently re-asserts on the numbers. So the derivation
 * sorts by size and refuses a tie, and the comparison is deepEqual on the
 * ARRAY: a precedence swap on one side only reds even though every character of
 * the set is identical.
 *
 * design/tokens.json is a cross-tree read from web/, so it is DECLARED in
 * scripts/web-path-escape-check.sh's set (row `design/tokens.json`) — without
 * that row its ratchet exits 1 and, worse, a tokens.json edit would dispatch no
 * web job while this test is the thing that pins it.
 *
 * WHY IT EXISTS. styleguide.tsx used to hand-keep its own six-step
 * {size,lh,weight} array beside a comment promising a later wave would wire the
 * emitted scale in (au-r4-web-type-ladder). A second copy of a scale is
 * invisible until someone retunes the token and only one of the two moves, so
 * the assertions below are about ABSENCE — no restated table, no dangling
 * promise — as much as about shape.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/type-ladder-emitted.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  chromeType,
  chromeTypeOrder,
  readingType,
  readingTypeOrder,
} from "../lib/tokens.gen.ts";

const at = (rel: string) => fileURLToPath(new URL(rel, import.meta.url));
const styleguide = readFileSync(at("../components/styleguide.tsx"), "utf8");

/** The ONE source of truth design/emit.mjs compiles lib/tokens.gen.ts from. */
const TOKENS_PATH = at("../../design/tokens.json");

const REFUSE = "REFUSING TO MEASURE";

/** Parse the token source, refusing rather than returning something empty. */
export function parseTokens(text: string, where = TOKENS_PATH): unknown {
  if (typeof text !== "string" || text.trim() === "")
    throw new Error(`${REFUSE} — ${where} read back empty; the ladder below would be derived from nothing`);
  try {
    return JSON.parse(text);
  } catch (e) {
    throw new Error(`${REFUSE} — ${where} did not parse as JSON: ${(e as Error).message}`);
  }
}

/**
 * Derive a ladder's step ids from tokens.json, in DISPLAY order (largest →
 * smallest by `size`). Every exit that would yield an empty or ambiguous
 * expectation throws instead — a derivation that cannot see must never report
 * a pass.
 */
export function ladderFrom(doc: unknown, family: "chrome" | "reading"): string[] {
  const block = (doc as { type?: Record<string, unknown> } | null)?.type?.[family];
  if (!block || typeof block !== "object")
    throw new Error(`${REFUSE} — tokens.type.${family} is missing or is not an object`);
  const steps = Object.entries(block as Record<string, unknown>)
    .filter(([k]) => !k.startsWith("_"))
    .map(([k, v]) => [k, (v as { size?: unknown } | null)?.size] as const)
    .filter((e): e is readonly [string, number] => typeof e[1] === "number" && Number.isFinite(e[1]) && e[1] > 0);
  if (steps.length === 0)
    throw new Error(`${REFUSE} — derived ZERO steps from tokens.type.${family}; every ladder assertion below would pass vacuously`);
  const sizes = new Set(steps.map(([, size]) => size));
  if (sizes.size !== steps.length)
    throw new Error(`${REFUSE} — tokens.type.${family} has two steps of the same size, so "largest → smallest" does not name one order`);
  return steps.slice().sort((a, b) => b[1] - a[1]).map(([k]) => k);
}

const tokens = parseTokens(readFileSync(TOKENS_PATH, "utf8"));
const chromeFromSource = ladderFrom(tokens, "chrome");
const readingFromSource = ladderFrom(tokens, "reading");

test("the derivation actually read a ladder, and refuses when it cannot", () => {
  // POSITIVE CONTROL. If the parse above ever went blind it would derive [] and
  // the deepEqual in the next test would pass against an empty emitted ladder.
  assert.ok(
    chromeFromSource.length >= 4,
    `derived only ${chromeFromSource.length} chrome step(s) from ${TOKENS_PATH} — the derivation has gone blind`,
  );
  assert.ok(
    readingFromSource.length >= 3,
    `derived only ${readingFromSource.length} reading step(s) from ${TOKENS_PATH} — the derivation has gone blind`,
  );
  // NEGATIVE CONTROLS on the READ, in-process: each way of failing to get any
  // JSON at all must throw, not hand back an empty expectation. (The malformed
  // FAMILY arms are the conformance table below — they are shared, these are not,
  // because no other implementation reads a file.)
  assert.throws(() => parseTokens(""), new RegExp(REFUSE), "an empty read must refuse");
  assert.throws(() => parseTokens("{ not json"), new RegExp(REFUSE), "an unparseable read must refuse");
});

// THE WEB ARM OF THE LADDER-REFUSAL CONFORMANCE TABLE (task-833f347eaa78a2a5).
// The malformed families below are NOT written here: they come out of
// design/ladder-refusal-fixture.json, the one list that design/emit.mjs'
// typeLadderFrom and design/validate.mjs' chromeLadderAscending are driven
// against too. Three implementations of one refusal contract, deliberately not
// shared (design/ladder-refusal-conformance.test.mjs states the two grounds), and
// on a well-formed tokens.json all three produce identical lists WHATEVER their
// refusal semantics are — so a relaxed tie-refusal in one copy is observable only
// on malformed input, which is what this fixture is.
//
// THIS ARM RUNS HERE AND NOT IN design/ FOR ONE MEASURED REASON: the doc-gates
// design job runs Node 20, which cannot execute TypeScript. Same fixture,
// different runner. design/ladder-refusal-conformance.test.mjs' enrolment arm
// reds if this block stops reading the fixture.
//
// The four arms it used to carry inline were THREE — there was no non-object
// family case — which is exactly the drift a per-site list produces.
const REFUSAL_FIXTURE_PATH = at("../../design/ladder-refusal-fixture.json");
const refusalFixture = JSON.parse(
  readFileSync(REFUSAL_FIXTURE_PATH, "utf8"),
) as {
  sentinel: string;
  cases: { id: string; kind: string; family?: unknown; why: string }[];
};

test("web: ladderFrom REFUSES every malformed family in the shared fixture", () => {
  assert.equal(
    refusalFixture.sentinel,
    REFUSE,
    `${REFUSAL_FIXTURE_PATH} declares a different sentinel than this file's REFUSE`,
  );
  assert.ok(
    refusalFixture.cases.length >= 4,
    `${REFUSAL_FIXTURE_PATH} carries only ${refusalFixture.cases.length} malformed case(s) — the loop below would prove almost nothing`,
  );
  for (const c of refusalFixture.cases) {
    const doc = c.kind === "omit" ? { type: {} } : { type: { chrome: c.family } };
    let refused: string | null = null;
    let got: string[] | undefined;
    try {
      got = ladderFrom(doc, "chrome");
    } catch (e) {
      refused = String((e as Error).message);
    }
    assert.ok(
      refused !== null,
      `IMPLEMENTATION "web" (web/__tests__/type-ladder-emitted.test.ts ladderFrom) DIVERGED on ladder-refusal-fixture.json case "${c.id}": it returned ${JSON.stringify(got)} instead of refusing. ${c.why}`,
    );
    assert.ok(
      refused.includes(REFUSE),
      `IMPLEMENTATION "web" refused case "${c.id}" without the sentinel "${REFUSE}": ${refused}`,
    );
  }
  // POSITIVE CONTROL: the real tokens.json still derives a ladder, so the loop
  // above is not passing because ladderFrom refuses everything.
  assert.ok(
    chromeFromSource.length >= 4,
    `derived only ${chromeFromSource.length} chrome step(s) from the real ${TOKENS_PATH} — the arm above proves nothing`,
  );
});

test("both emitted ladders are complete, typed steps in display order", () => {
  // The expected side is DERIVED (above), never retyped here. deepEqual on the
  // array pins ORDER as well as membership: swap two steps in the emitted
  // chromeTypeOrder and this reds with every character of the set unchanged.
  assert.deepEqual([...chromeTypeOrder], chromeFromSource);
  assert.deepEqual([...readingTypeOrder], readingFromSource);
  for (const [family, order, table] of [
    ["chromeType", chromeTypeOrder, chromeType],
    ["readingType", readingTypeOrder, readingType],
  ] as const) {
    for (const k of order) {
      const s = (table as Record<string, { size: number; lineHeight: number; weight: number }>)[k];
      assert.ok(s, `${family}.${k} is missing`);
      assert.ok(Number.isFinite(s.size) && s.size > 0, `${family}.${k}.size`);
      assert.ok(Number.isFinite(s.lineHeight) && s.lineHeight > 0, `${family}.${k}.lineHeight`);
      assert.ok(Number.isInteger(s.weight) && s.weight >= 100 && s.weight <= 900, `${family}.${k}.weight`);
    }
  }
});

test("the chrome ladder descends in size and never gets lighter as it grows", () => {
  const steps = chromeTypeOrder.map((k) => chromeType[k]);
  for (let i = 1; i < steps.length; i++) {
    assert.ok(steps[i].size < steps[i - 1].size, `chrome step ${chromeTypeOrder[i]} is not smaller than ${chromeTypeOrder[i - 1]}`);
    assert.ok(steps[i].weight <= steps[i - 1].weight, `chrome step ${chromeTypeOrder[i]} is heavier than the larger ${chromeTypeOrder[i - 1]}`);
  }
});

test("the reading display step clears the prose step by the editorial floor", () => {
  // The same 2.0x floor design/validate.mjs pins on tokens.json — asserted again
  // on what the web actually received, so a build shipping a flattened ladder
  // fails here even if the source was fine at emit time.
  assert.ok(readingType.h1.size / readingType.body.size >= 2.0);
});

test("the styleguide reads both ladders from the emitted module", () => {
  assert.match(styleguide, /from "@\/lib\/tokens\.gen"/);
  for (const name of ["chromeType", "chromeTypeOrder", "readingType", "readingTypeOrder"]) {
    assert.ok(styleguide.includes(name), `styleguide.tsx does not consume ${name}`);
  }
});

test("the styleguide restates no type scale of its own", () => {
  // A hand-kept ladder looks like `{ label: "xl", size: 20, ... }`, or a bare
  // `fontWeight: 700` on the page's own chrome. The wired page carries neither:
  // every number it renders arrives through a spread of an emitted step.
  assert.doesNotMatch(styleguide, /\bsize:\s*\d/, "styleguide.tsx declares a literal type size");
  assert.doesNotMatch(styleguide, /\blh:\s*\d/, "styleguide.tsx declares a literal line height");
  assert.doesNotMatch(styleguide, /\bfontWeight:\s*\d{3}\b/, "styleguide.tsx declares a literal font weight");
  // And no promise of a migration that already happened.
  assert.doesNotMatch(styleguide, /W3\.9/, "styleguide.tsx still promises W3.9 will wire the scale");
  assert.doesNotMatch(styleguide, /type\.ui/, "styleguide.tsx still names the non-existent tokens.json type.ui");
});
