/**
 * Builder-side tests for the `/d/<type>/<slug>` encoding invariant in the
 * search-starter tree. `web/__tests__/find-href.test.ts` and
 * `web/__tests__/prefix-seed.test.ts` hold the equivalents in the `web/` tree;
 * this fork had NEITHER, which is how `lib/prefix-seed.ts` stayed unencoded for
 * five weeks after #3779 fixed web's copy of the same line.
 *
 * Run: `cd templates/search-starter && pnpm test`
 * (or `node --test lib/find.href.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readerHref } from "./find.ts";
import { seedDocToFindHit } from "./prefix-seed.ts";

test("readerHref encodes a space in the slug", () => {
  assert.equal(readerHref("post", "my post"), "/d/post/my%20post");
});

test("readerHref encodes a reserved '#' in the slug", () => {
  assert.equal(readerHref("post", "a#b"), "/d/post/a%23b");
});

test("readerHref encodes the TYPE segment too", () => {
  assert.equal(readerHref("case study", "x"), "/d/case%20study/x");
});

test("readerHref leaves a plain kebab slug byte-identical (no double-encoding)", () => {
  assert.equal(readerHref("post", "hello-world"), "/d/post/hello-world");
});

test("seedDocToFindHit percent-encodes href segments (the #3779 gap in this tree)", () => {
  const hit = seedDocToFindHit({ id: "1", title: "T", slug: "a#b c", type: "case study" });
  assert.equal(hit.href, "/d/case%20study/a%23b%20c");
  assert.equal(hit.href, readerHref(hit.type, hit.slug));
});

test("seedDocToFindHit leaves a plain slug byte-identical", () => {
  const hit = seedDocToFindHit({ id: "1", title: "T", slug: "javascript-guide", type: "paper" });
  assert.equal(hit.href, "/d/paper/javascript-guide");
});
