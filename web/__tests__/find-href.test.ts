/**
 * Tests for `readerHref` — the canonical reader URL builder used by the finder
 * result rows and the global quick-switcher (`router.push(readerHref(...))`).
 * A slug is CMS data that can fall back to an arbitrary `_id`, so a space, a
 * reserved char (`#`/`?`), or non-ASCII must be percent-encoded or the pushed
 * path is malformed / 404s. Kebab slugs must pass through byte-identical (no
 * double-encoding). Next.js decodes `[type]/[slug]`, so reads are unchanged.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/find-href.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readerHref } from "../lib/find.ts";

test("encodes a space in the slug", () => {
  assert.equal(readerHref("post", "my post"), "/d/post/my%20post");
});

test("encodes a reserved '#' in the slug", () => {
  assert.equal(readerHref("post", "a#b"), "/d/post/a%23b");
});

test("leaves a plain kebab slug byte-identical (no double-encoding)", () => {
  assert.equal(readerHref("post", "hello-world"), "/d/post/hello-world");
});
