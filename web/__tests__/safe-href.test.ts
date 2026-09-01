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

test("drops backslash protocol-relative /\\host (browser-normalized to //host)", () => {
  // JS string "/\\evil.com" is the two chars slash + backslash then "evil.com".
  assert.equal(safeHref("/\\evil.com"), undefined);
  assert.equal(safeHref("/\\evil.com/path"), undefined);
});

test("passes http/https/mailto/tel through unchanged", () => {
  assert.equal(safeHref("http://example.com"), "http://example.com");
  assert.equal(safeHref("https://example.com/a?b=1"), "https://example.com/a?b=1");
  assert.equal(safeHref("mailto:hi@example.com"), "mailto:hi@example.com");
  assert.equal(safeHref("HTTPS://EXAMPLE.COM"), "HTTPS://EXAMPLE.COM");
  assert.equal(safeHref("tel:+4712345678"), "tel:+4712345678");
  assert.equal(safeHref("TEL:+47"), "TEL:+47");
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

/* ── the tab / newline protocol-relative bypass ────────────────────────────── */

/**
 * The WHATWG URL parser DELETES every ASCII tab (0x09), LF (0x0A) and CR (0x0D)
 * from a URL string BEFORE it parses it — measured over 0x00-0x20, those three
 * and only those three collapse. So `/<TAB>/evil.example` is not a path called
 * "<TAB>": the browser resolves it as the protocol-relative `//evil.example`
 * and navigates off-site. A guard that strips control characters LEADING-ONLY
 * and then tests position 1 for `/` or `\` never sees that.
 *
 * These cases assert the RESOLVED URL, not just the returned string —
 * resolution is where the harm lands, and a returned string that "looks
 * relative" is exactly how this hid.
 */
const RESOLUTION_BASE = "https://demo.barkpark.cloud/d/paper/x";

/** Where a browser would actually go for this href on a Barkpark page. */
function resolves(href: string): string {
  return new URL(href, RESOLUTION_BASE).href;
}

test("subject presence: safeHref is the exported guard under test", () => {
  assert.equal(typeof safeHref, "function");
  // A pass must not be obtainable by the guard degrading to a pass-through.
  assert.equal(safeHref("javascript:alert(1)"), undefined);
});

test("an embedded tab/LF/CR cannot smuggle a protocol-relative host past safeHref", () => {
  for (const raw of [
    "/\t/evil.example/phish",
    "/\n/evil.example/phish",
    "/\r/evil.example/phish",
    "/\t\\evil.example/phish",
    "/\n\\evil.example/phish",
    "/\r\\evil.example/phish",
    "/\t\t//evil.example/phish",
    "/\r\n/evil.example/phish",
  ]) {
    const out = safeHref(raw);
    assert.equal(
      out,
      undefined,
      `safeHref(${JSON.stringify(raw)}) returned ${JSON.stringify(out)}, ` +
        `which a browser resolves to ${resolves(out!)}`,
    );
  }
});

test("an embedded tab/LF/CR cannot smuggle a dangerous scheme past safeHref", () => {
  assert.equal(safeHref("jav\tascript:alert(1)"), undefined);
  assert.equal(safeHref("jav\nascript:alert(1)"), undefined);
  assert.equal(safeHref("java\r\nscript:alert(1)"), undefined);
});

test("what safeHref returns is what the browser resolves — no smuggled chars", () => {
  // Whatever comes back must already be free of the three characters the URL
  // parser deletes, so the string that was CHECKED is the string that RESOLVES.
  for (const raw of ["/d/po\tst/x", "https://example.com/a\nb", "#an\rchor"]) {
    const out = safeHref(raw);
    if (out === undefined) continue;
    assert.doesNotMatch(
      out,
      /[\t\n\r]/,
      `safeHref(${JSON.stringify(raw)}) returned ${JSON.stringify(out)} — the ` +
        `browser strips those bytes, so the checked string is not the resolved one`,
    );
  }
});

test("legitimate URLs are untouched by the control-character clean", () => {
  assert.equal(safeHref("/d/paper/my-paper"), "/d/paper/my-paper");
  assert.equal(safeHref("https://example.com/a?b=1#c"), "https://example.com/a?b=1#c");
  assert.equal(resolves(safeHref("/d/paper/x")!), "https://demo.barkpark.cloud/d/paper/x");
});
