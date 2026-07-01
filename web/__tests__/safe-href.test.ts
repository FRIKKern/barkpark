/**
 * Tests for `safeHref` — the scheme allow-list that guards every CMS-authored
 * href spliced into the PortableDoc reader. React does not sanitize href
 * schemes, so a paper authored as `[x](javascript:…)` or a `data:` URL is a
 * live XSS/navigation payload unless the renderer drops it. These cases pin the
 * allow-list: http/https/mailto and a few relative forms pass; everything else
 * (dangerous schemes, protocol-relative, junk) collapses to `undefined`.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/safe-href.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { safeHref } from "../lib/safe-href.ts";

test("drops javascript: scheme", () => {
  assert.equal(safeHref("javascript:alert(document.cookie)"), undefined);
  assert.equal(safeHref("JavaScript:alert(1)"), undefined);
  assert.equal(safeHref("  javascript:alert(1)  "), undefined);
});

test("drops data: scheme", () => {
  assert.equal(safeHref("data:text/html,<script>alert(1)</script>"), undefined);
});

test("drops vbscript: scheme", () => {
  assert.equal(safeHref("vbscript:msgbox(1)"), undefined);
});

test("drops protocol-relative //host", () => {
  assert.equal(safeHref("//evil.com"), undefined);
  assert.equal(safeHref("//evil.com/path"), undefined);
});

test("passes http/https/mailto through unchanged", () => {
  assert.equal(safeHref("http://example.com"), "http://example.com");
  assert.equal(safeHref("https://example.com/a?b=1"), "https://example.com/a?b=1");
  assert.equal(safeHref("mailto:hi@example.com"), "mailto:hi@example.com");
  assert.equal(safeHref("HTTPS://EXAMPLE.COM"), "HTTPS://EXAMPLE.COM");
});

test("passes relative/anchor/query forms through", () => {
  assert.equal(safeHref("#anchor"), "#anchor");
  assert.equal(safeHref("/d/post/x"), "/d/post/x");
  assert.equal(safeHref("./rel"), "./rel");
  assert.equal(safeHref("../up"), "../up");
  assert.equal(safeHref("?q=1"), "?q=1");
});

test("returns undefined for empty/whitespace/non-string", () => {
  assert.equal(safeHref(""), undefined);
  assert.equal(safeHref("   "), undefined);
  assert.equal(safeHref(undefined), undefined);
  assert.equal(safeHref(null), undefined);
  assert.equal(safeHref(42), undefined);
  assert.equal(safeHref({}), undefined);
});
