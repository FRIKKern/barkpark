/**
 * The web type ladder has ONE source: design/tokens.json, compiled by
 * design/emit.mjs into lib/tokens.gen.ts. This file is the WEB half of that
 * guard — it asserts the shape the web consumes and that the consumer restates
 * nothing. The other half (emitted numbers === tokens.json numbers) lives in
 * design/check.mjs Part C2, on purpose: reading design/tokens.json from here
 * would be a cross-tree read of the web gate that ci.yml does not dispatch on,
 * which scripts/web-path-escape-check.sh refuses (measured, not assumed).
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

test("both emitted ladders are complete, typed steps in display order", () => {
  assert.deepEqual([...chromeTypeOrder], ["2xl", "xl", "lg", "base", "sm", "xs"]);
  assert.deepEqual([...readingTypeOrder], ["h1", "h2", "h3", "body"]);
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
