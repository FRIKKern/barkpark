/**
 * Tests for `markHref` — the ATTRS-FIRST link-mark href resolver that keeps the
 * web reader in parity with the Go (`internal/pdrender/inline.go`) and Elixir
 * (`inline.ex`) renderers. A non-empty `attrs.href` (ProseMirror shape) wins,
 * else the top-level `href`; anything else is `undefined`. Precedence and edge
 * cases mirror `internal/pdrender/markhref_test.go`.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/mark-href.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { markHref } from "../lib/mark-href.ts";

test("resolves nested attrs.href", () => {
  assert.equal(markHref({ attrs: { href: "https://x" } }), "https://x");
});

test("resolves top-level href when no attrs", () => {
  assert.equal(markHref({ href: "https://y" }), "https://y");
});

test("attrs.href wins when both present", () => {
  assert.equal(
    markHref({ attrs: { href: "https://attrs" }, href: "https://top" }),
    "https://attrs",
  );
});

test("empty attrs.href falls through to top-level", () => {
  assert.equal(
    markHref({ attrs: { href: "" }, href: "https://z" }),
    "https://z",
  );
});

test("attrs present without href key falls through to top-level", () => {
  assert.equal(
    markHref({ attrs: { title: "t" }, href: "https://w" }),
    "https://w",
  );
});

test("returns undefined for string mark, null, and number", () => {
  assert.equal(markHref("not a map"), undefined);
  assert.equal(markHref(null), undefined);
  assert.equal(markHref(42), undefined);
});

test("returns undefined when neither href is present", () => {
  assert.equal(markHref({ foo: "bar" }), undefined);
});
