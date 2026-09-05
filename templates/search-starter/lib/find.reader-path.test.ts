/**
 * Tests for `isReaderPathActive` — the COMPARISON half of the `/d/<type>/<slug>`
 * encoding invariant, and the one the original fix (#3779) left broken.
 *
 * `usePathname()` hands the finder the ENCODED path. The old comparison built
 * its expected side raw (a '/d/' + type + '/' + slug template), so any slug carrying a
 * space, `#`, `?` or `/` never matched and the active result row silently
 * stopped highlighting — a defect with no error, just a missing highlight.
 * These tests pin the encoded-vs-encoded comparison.
 *
 * Run: `cd templates/search-starter && pnpm test`
 * (or `node --test lib/find.reader-path.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { isReaderPathActive, readerHref } from "./find.ts";

const spaced = { type: "post", slug: "my paper", href: null };
const hashed = { type: "post", slug: "a#b", href: null };

test("active match holds for a slug with a SPACE (encoded pathname)", () => {
  assert.equal(isReaderPathActive("/d/post/my%20paper", spaced), true);
});

test("active match holds for a slug with a '#' (encoded pathname)", () => {
  assert.equal(isReaderPathActive("/d/post/a%23b", hashed), true);
});

test("active match holds for an encoded TYPE too", () => {
  assert.equal(
    isReaderPathActive("/d/case%20study/x", { type: "case study", slug: "x", href: null }),
    true,
  );
});

test("the comparison agrees with the builder for encoding-requiring input", () => {
  assert.equal(isReaderPathActive(readerHref("post", "my paper"), spaced), true);
  assert.equal(isReaderPathActive(readerHref("post", "a#b"), hashed), true);
});

test("a plain kebab slug still matches (no double-encoding regression)", () => {
  assert.equal(
    isReaderPathActive("/d/post/hello-world", { type: "post", slug: "hello-world", href: null }),
    true,
  );
});

test("a different document does NOT match", () => {
  assert.equal(isReaderPathActive("/d/post/other", spaced), false);
});

test("a server-supplied hit.href still wins, and a null pathname never matches", () => {
  assert.equal(
    isReaderPathActive("/d/post/server-chosen", { type: "post", slug: "x", href: "/d/post/server-chosen" }),
    true,
  );
  assert.equal(isReaderPathActive(null, spaced), false);
});

test("the DOC_TYPES href lambdas encode (find.ts:69/:76, unencoded before this fix)", async () => {
  const { DOC_TYPES } = await import("./find.ts");
  const post = DOC_TYPES.find((t) => t.type === "post");
  assert.ok(post, "expected a 'post' doc type in the default set");
  assert.equal(post!.href("my paper"), "/d/post/my%20paper");
  assert.equal(post!.href("a#b"), "/d/post/a%23b");
});
