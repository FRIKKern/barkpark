import { test } from "node:test";
import assert from "node:assert/strict";
import { slugText } from "../lib/slug-text.ts";

test("slugText returns bare strings unchanged", () => {
  assert.equal(slugText("foo"), "foo");
});

test("slugText unwraps the Barkpark slug object form", () => {
  assert.equal(slugText({ _type: "slug", current: "foo" }), "foo");
});

test("slugText returns null for undefined", () => {
  assert.equal(slugText(undefined), null);
});

test("slugText returns null for an object with no current", () => {
  assert.equal(slugText({}), null);
});

test("slugText returns null when current is not a string", () => {
  assert.equal(slugText({ current: 5 }), null);
});
