/**
 * Tests for `normalizeHit` — the raw-document → `FindHit` mapper that every
 * finder result flows through (HTTP route AND the live WebSocket path). It owns
 * the messy CMS-envelope realities: null-guarding junk, deriving `status` from
 * `_draft` when the column isn't rendered, and reading fields off either the
 * top level or the spread `content`. Load-bearing and shipped untested.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/normalize-hit.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeHit } from "../lib/find.ts";

test("returns null for non-objects and docs missing _id/_type", () => {
  for (const junk of [null, undefined, 42, "x", {}, { _id: "p1" }, { _type: "post" }]) {
    assert.equal(normalizeHit(junk), null, `expected null for ${JSON.stringify(junk)}`);
  }
});

test("maps a minimal valid doc to a FindHit", () => {
  const h = normalizeHit({ _id: "p1", _type: "post" });
  assert.ok(h, "expected a hit");
  assert.equal(h!.id, "p1");
  assert.equal(h!.type, "post");
  assert.equal(h!.facets.type, "post");
  assert.equal(typeof h!.title, "string");
  assert.ok(h!.href.startsWith("/d/post/"), `href = ${h!.href}`);
});

test("derives status from _draft when there's no explicit column", () => {
  assert.equal(normalizeHit({ _id: "p1", _type: "post", _draft: true })!.facets.status, "draft");
  assert.equal(normalizeHit({ _id: "p1", _type: "post", _draft: false })!.facets.status, "published");
});

test("an explicit status wins over _draft", () => {
  const h = normalizeHit({ _id: "p1", _type: "post", status: "archived", _draft: true });
  assert.equal(h!.facets.status, "archived");
});

test("reads status off the spread content when absent up top", () => {
  const h = normalizeHit({ _id: "p1", _type: "post", content: { status: "published" } });
  assert.equal(h!.facets.status, "published");
});

test("promotes author/category to facets when present", () => {
  const h = normalizeHit({ _id: "p1", _type: "post", author: "alice", category: "tech" });
  assert.equal(h!.facets.author, "alice");
  assert.equal(h!.facets.category, "tech");
});

test("omits the status facet when no status signal exists", () => {
  const h = normalizeHit({ _id: "p1", _type: "post" });
  assert.equal(h!.facets.status, undefined);
});
