/**
 * Error-vocabulary parity: `isEngineError` / `ENGINE_ERRORS` are the TS twins
 * of `Engine.error_values/0`.
 *
 * The SHARED fixture (`fixtures/engine-errors.json`) is generated FROM the
 * Elixir engine's `@error_values` list; the ExUnit errors axis in
 * `api/test/barkpark/sheets_parity_test.exs` asserts the same file equals
 * `Engine.error_values/0`. So if a new code is added engine-side, the fixture
 * (regenerated from the engine) gains it and this suite reds until `sheets.ts`
 * learns it too — a code can never mark red on one surface and plain on another.
 *
 * Run: `pnpm --filter web test`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { ENGINE_ERRORS, isEngineError } from "../lib/sheets.ts";

const fixture: string[] = JSON.parse(
  readFileSync(
    new URL("./fixtures/engine-errors.json", import.meta.url),
    "utf8",
  ),
);

test("fixture is non-empty and every code is recognised as an engine error", () => {
  assert.ok(fixture.length > 0, "engine-errors fixture must not be empty");
  for (const code of fixture) {
    assert.equal(
      isEngineError(code),
      true,
      `isEngineError(${JSON.stringify(code)}) should be true`,
    );
  }
});

test("ENGINE_ERRORS set equals the engine fixture exactly (no one-sided drift)", () => {
  const fromLib = [...ENGINE_ERRORS].sort();
  const fromFixture = [...fixture].sort();
  assert.deepEqual(
    fromLib,
    fromFixture,
    "sheets.ts ENGINE_ERRORS drifted from the engine-generated fixture",
  );
});

test("ordinary values are never engine errors", () => {
  assert.equal(isEngineError(""), false);
  assert.equal(isEngineError("hello"), false);
  assert.equal(isEngineError("42"), false);
  assert.equal(isEngineError("#HELLO!"), false);
  assert.equal(isEngineError(42), false);
  assert.equal(isEngineError(null), false);
  assert.equal(isEngineError(undefined), false);
  assert.equal(isEngineError(true), false);
});
