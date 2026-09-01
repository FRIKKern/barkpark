/**
 * `coord()` in `lib/listings.ts` is the ONLY thing standing between a bad
 * upstream coordinate and a permanently blank map. This file exists so nobody
 * relaxes it by accident.
 *
 * WHY IT IS LOAD-BEARING — measured in Chromium against the map's own drawing
 * code: `ctx.arc` swallows a `NaN` centre silently (no throw, no pin), and
 * `listings-map.tsx`'s offscreen cull (`x < -30 || x > w + 30 || …`) FAILS OPEN
 * on `NaN` because every comparison against `NaN` is false — so a `NaN` pin is
 * never culled and never drawn. Worse, one `NaN` coordinate reaching
 * `fitToListings` poisons `viewRef`, and from then on the ENTIRE map — tiles
 * included — draws nothing, permanently, with no error anywhere.
 *
 * So the gate is `Number.isFinite`, not `typeof v === "number"`: `NaN`,
 * `Infinity` and `-Infinity` are all `typeof "number"`, and `Number("")`,
 * `Number(" ")` and `Number(null)` are all `0` — a coordinate that reads as the
 * equator rather than as absent.
 *
 * `listings.ts` imports `server-only`, `next/cache` and `@/` path aliases, so it
 * cannot be loaded under bare `node --test`. These tests instead lift the
 * `coord` function's SOURCE TEXT out of the shipped file and evaluate it, so
 * they run the real implementation and fail loudly the moment it is renamed,
 * removed, or weakened.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/listings-coord-finite.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const listingsPath = fileURLToPath(new URL("../lib/listings.ts", import.meta.url));
const source = readFileSync(listingsPath, "utf8");

/** Lift `function coord(...) { … }` verbatim, up to its column-0 closing brace. */
const block = /^function coord\([\s\S]*?\n\}/m.exec(source);

test("lib/listings.ts still defines coord — the map's coordinate gate", () => {
  assert.ok(
    block,
    "could not find `function coord(` in lib/listings.ts; if it was renamed, " +
      "re-point this test at the new name — do not delete the coverage",
  );
});

const js = ts.transpileModule(block![0], {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
}).outputText;
const coord = new Function(`${js}\nreturn coord;`)() as (
  v: unknown,
) => number | undefined;

/* ── the invariant ────────────────────────────────────────────────────────── */

test("a non-finite number never becomes a coordinate", () => {
  for (const v of [NaN, Infinity, -Infinity]) {
    assert.equal(
      coord(v),
      undefined,
      `coord(${String(v)}) leaked a non-finite coordinate — one of these ` +
        `reaching fitToListings blanks the entire map, permanently and silently`,
    );
  }
});

test("a non-finite NUMERIC STRING never becomes a coordinate either", () => {
  // The string branch is the one that actually parses upstream JSON.
  for (const v of ["NaN", "Infinity", "-Infinity", "abc", "12abc", "1,5"]) {
    assert.equal(coord(v), undefined, `coord(${JSON.stringify(v)})`);
  }
});

test("blank and null-ish input does not collapse to 0 (the equator)", () => {
  // Number("") === 0, Number(" ") === 0, Number(null) === 0, Number([]) === 0.
  // An absent coordinate must read as ABSENT, not as a point off Ghana.
  for (const v of ["", "   ", "\t\n", null, undefined, [], {}, true, false]) {
    assert.equal(coord(v), undefined, `coord(${JSON.stringify(v)})`);
  }
});

test("real coordinates — number and string — still pass through", () => {
  // The gate must not be so tight that it drops the data it exists to admit.
  assert.equal(coord(59.9139), 59.9139);
  assert.equal(coord(-0.1276), -0.1276);
  assert.equal(coord(0), 0, "a literal 0 is a real coordinate at this layer");
  assert.equal(coord("59.9139"), 59.9139);
  assert.equal(coord(" 10.7522 "), 10.7522);
  assert.equal(coord("-1e2"), -100);
});

/* ── the gate is still wired into the read path ───────────────────────────── */

test("every lat/lng the map receives is still routed through coord", () => {
  const readLatLng = /function readLatLng\([\s\S]*?\n\}/m.exec(source)?.[0];
  assert.ok(readLatLng, "readLatLng must still exist in lib/listings.ts");
  // Each candidate field is wrapped, so no path reaches `lat`/`lng` unchecked.
  const wrapped = readLatLng!.match(/coord\(/g)?.length ?? 0;
  assert.ok(
    wrapped >= 8,
    `readLatLng routes only ${wrapped} candidate fields through coord() — a ` +
      `field read outside the gate is a NaN path back into the map`,
  );
  assert.doesNotMatch(
    readLatLng!,
    /^\s*(const|let)\s+(lat|lng)\s*=\s*(row|dig)\b/m,
    "a lat/lng read straight off the row bypasses the finite check",
  );
});

test("the check is Number.isFinite, not a bare typeof", () => {
  assert.match(
    block![0],
    /Number\.isFinite/,
    "coord must gate on Number.isFinite — `typeof v === 'number'` admits NaN",
  );
});
