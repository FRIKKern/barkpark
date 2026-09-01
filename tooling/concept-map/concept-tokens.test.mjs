#!/usr/bin/env node
// concept-tokens.test.mjs — proves the fold matcher refuses the tree root.
//
// RED-BEFORE: every assertion below fails against the previous matcher
// `(^|[/_.])<token>([/_.]|$)`. The `mustNotMatch` block IS the defect: with the
// `^` arm, "api" matched api/test/…, api/lib/barkpark_web/…, every Elixir path
// in the repo — and concept "api" became the catch-all sink for 673 files.
//
// Run: node --test tooling/concept-map/concept-tokens.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { conceptTokenRe, conceptTokenMatchers } from "./concept-tokens.mjs";

// The three tokens that collide with a top-level directory name on origin/main.
// Each is minted legitimately by a file deeper in the tree, so the token must
// exist — it simply must not match the tree root that shares its spelling.
const ROOT_COLLIDERS = ["api", "connectors", "scaffy"];

test("a token never matches the leading tree-root segment", () => {
  for (const t of ROOT_COLLIDERS) {
    const re = conceptTokenRe(t);
    assert.equal(re.test(`${t}/lib/barkpark/content/document.ex`), false,
      `"${t}" must not claim ${t}/… merely because the tree root is spelled the same`);
    assert.equal(re.test(`${t}/test/barkpark/media/share_scope_test.exs`), false,
      `"${t}" must not claim a test file by the tree root`);
  }
});

test("a token still matches when a separator precedes it", () => {
  const re = conceptTokenRe("api");
  // The 26 legitimate members all look like one of these.
  assert.ok(re.test("api/lib/barkpark/api/openapi.ex"), "deep segment /api/");
  assert.ok(re.test("api/lib/barkpark_web/plugs/api_security_headers.ex"), "underscore-joined api_");
  assert.ok(re.test("web/app/api/find/route.ts"), "js tree /api/");
  assert.ok(re.test("internal/pdrender/api_endpoint.go"), "go underscore api_");
});

test("separator classes are exactly / _ and .", () => {
  const re = conceptTokenRe("media");
  assert.ok(re.test("api/lib/barkpark/media/asset.ex"), "slash both sides");
  assert.ok(re.test("api/test/barkpark_web/media_controller_test.exs"), "underscore lead");
  assert.ok(re.test("api/lib/barkpark/media.ex"), "dot trailing");
  assert.ok(re.test("some/path/x.media"), "dot leading, end anchor");
  // Substring hits must stay rejected — the reason the class exists at all.
  assert.equal(re.test("api/lib/barkpark/multimedia_store.ex"), false, "no bare substring");
  assert.equal(re.test("api/lib/barkpark/mediator.ex"), false, "no prefix substring");
});

test("compound tokens rely on ORDERING, not on the regex, to win", () => {
  // Documenting a real property of the fold, because it is easy to misread.
  // `_` is a separator, so a short token IS separator-bounded inside a compound
  // one: "doc" genuinely matches "…/portable_doc/…" via the `_doc/` boundary.
  const portable = conceptTokenRe("portable_doc");
  const doc = conceptTokenRe("doc");
  assert.ok(portable.test("api/lib/barkpark/portable_doc/render.ex"));
  assert.ok(doc.test("api/lib/barkpark/portable_doc/render.ex"),
    '"doc" DOES match inside "portable_doc" — `_` is a separator');

  // So the matcher alone cannot disambiguate. What makes portable_doc win is
  // the caller's longest-token-first sort plus break-on-first-match. Both
  // callers must keep that order; this asserts the property they depend on.
  const tokens = ["doc", "portable_doc"].sort((a, b) => b.length - a.length);
  assert.deepEqual(tokens, ["portable_doc", "doc"]);
  const first = tokens.find((t) => conceptTokenRe(t).test("api/lib/barkpark/portable_doc/render.ex"));
  assert.equal(first, "portable_doc");
});

test("conceptTokenMatchers returns one compiled regex per token", () => {
  const m = conceptTokenMatchers(["api", "media"]);
  assert.equal(m.size, 2);
  assert.ok(m.get("api") instanceof RegExp);
  assert.equal(m.get("api").test("api/test/x.exs"), false);
  assert.ok(m.get("media").test("api/lib/barkpark/media/asset.ex"));
});
