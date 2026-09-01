/**
 * `sanitizeTrustedHtml` (components/document-detail.tsx) is the pass every
 * `body_html` paper goes through before it reaches `dangerouslySetInnerHTML`.
 * Its docstring used to promise it strips "script elements, inline `on*`
 * handlers, `javascript:` URLs". Measured against the shipped function, it
 * reliably strips ONE of those three, because HTML accepts `/` as an attribute
 * separator and every handler regex requires a literal `\s` before `on`:
 *
 *   UNCHANGED  <img/onerror=alert(1) src=x>
 *   UNCHANGED  <svg/onload=alert(1)>
 *   UNCHANGED  <a href="jav&#x61;script:alert(1)">x</a>
 *   UNCHANGED  <iframe srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;">
 *   stripped   <img src=x onerror=alert(1)>
 *
 * Regex HTML sanitizing is the bug, so the fix is NOT more regexes. The actual
 * control on this surface is the CSP (`lib/csp.ts`): an enforcing `script-src`
 * with no `'unsafe-inline'` / `'unsafe-eval'`, `object-src 'none'`, and a
 * per-request 128-bit nonce — inline handlers and `javascript:` URLs do not
 * execute under it. The filter stays as a cosmetic belt-and-braces pass; what
 * had to go was the comment.
 *
 * A comment claiming a defence the runtime does not deliver is worse than no
 * comment — it is why nobody added the real one. So this file makes the
 * comment LOAD-BEARING: every strip claim the docstring makes is executed
 * against a payload, and the docstring must carry the honesty marker naming
 * the CSP as the control. Re-add "inline `on*` handlers" to that comment
 * without making it true and this test goes red.
 *
 * `document-detail.tsx` is a server component whose import graph reaches the
 * built `@barkpark/react` dist, so instead of importing it this file extracts
 * the function's own source text, transpiles it with the repo's TypeScript
 * compiler and evaluates THAT — the shipped bytes, not a re-model.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/sanitize-trusted-html.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const SOURCE_PATH = fileURLToPath(
  new URL("../components/document-detail.tsx", import.meta.url),
);
const source = readFileSync(SOURCE_PATH, "utf8");

/* ── extract the docstring + the function, and run the real thing ──────────── */

const DECL = "function sanitizeTrustedHtml(";
const declAt = source.indexOf(DECL);

/** The `/** … *\/` block immediately above the declaration. */
function docCommentAbove(at: number): string {
  const end = source.lastIndexOf("*/", at);
  const start = source.lastIndexOf("/**", end);
  return start === -1 || end === -1 ? "" : source.slice(start, end + 2);
}

/** The declaration's source text, brace-matched from `{` to its closer. */
function functionSourceAt(at: number): string {
  const open = source.indexOf("{", at);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(at, i + 1);
  }
  throw new Error("unbalanced braces in sanitizeTrustedHtml");
}

const docComment = docCommentAbove(declAt);
const fnSource = declAt === -1 ? "" : functionSourceAt(declAt);

const sanitizeTrustedHtml: (html: string) => string =
  declAt === -1
    ? () => {
        throw new Error("sanitizeTrustedHtml not found in document-detail.tsx");
      }
    : (new Function(
        `${
          ts.transpileModule(fnSource, {
            compilerOptions: { target: ts.ScriptTarget.ES2022 },
          }).outputText
        }\nreturn sanitizeTrustedHtml;`,
      )() as (html: string) => string);

/* ── subject presence ──────────────────────────────────────────────────────── */

test("the filter exists and is still wired into the dangerouslySetInnerHTML sink", () => {
  assert.notEqual(declAt, -1, "sanitizeTrustedHtml must exist in document-detail.tsx");
  assert.match(
    source,
    /dangerouslySetInnerHTML=\{\{\s*__html:\s*sanitizeTrustedHtml\(html\)\s*\}\}/,
    "the body_html sink must still route through sanitizeTrustedHtml",
  );
  // …and it must still actually do something, so nothing below is vacuous.
  assert.equal(sanitizeTrustedHtml("<script>alert(1)</script>hi"), "hi");
});

/* ── the docstring is a promise, and this executes it ──────────────────────── */

/**
 * Each entry: a claim the docstring may make, and a payload proving it. A
 * claim present in the comment MUST hold. Nothing forces the comment to make
 * any given claim — it is free to promise less; it is not free to lie.
 */
const CLAIMS: { claim: string; probe: () => void }[] = [
  {
    claim: "script elements",
    probe: () => {
      assert.doesNotMatch(sanitizeTrustedHtml("<script>alert(1)</script>"), /<script/i);
      assert.doesNotMatch(sanitizeTrustedHtml("<script src=x></script>"), /<script/i);
    },
  },
  {
    claim: "inline `on*` handlers",
    probe: () => {
      for (const v of [
        "<img src=x onerror=alert(1)>",
        "<img/onerror=alert(1) src=x>",
        "<svg/onload=alert(1)>",
        '<body/onload="alert(1)">',
      ]) {
        assert.doesNotMatch(
          sanitizeTrustedHtml(v),
          /\bon[a-z]+\s*=/i,
          `docstring claims inline on* handlers are stripped, but ${JSON.stringify(v)} survives`,
        );
      }
    },
  },
  {
    claim: "`javascript:` URLs",
    probe: () => {
      for (const v of [
        '<a href="javascript:alert(1)">x</a>',
        '<a href="jav&#x61;script:alert(1)">x</a>',
        "<a href=javascript:alert(1)>x</a>",
      ]) {
        const out = sanitizeTrustedHtml(v);
        assert.doesNotMatch(
          out,
          /script:/i,
          `docstring claims javascript: URLs are stripped, but ${JSON.stringify(v)} survives as ${JSON.stringify(out)}`,
        );
      }
    },
  },
];

test("every strip the docstring claims, the function actually performs", () => {
  const made = CLAIMS.filter((c) => docComment.includes(c.claim));
  assert.ok(
    made.length > 0,
    "the docstring must still say what the filter does — it claims nothing at all",
  );
  for (const c of made) c.probe();
});

const HONESTY_MARKER = "the CSP in `lib/csp.ts` is the control";

test("the docstring names the CSP as the actual control, not itself", () => {
  assert.ok(
    docComment.includes(HONESTY_MARKER),
    `document-detail.tsx's sanitizeTrustedHtml docstring must contain the exact ` +
      `phrase ${JSON.stringify(HONESTY_MARKER)}. A regex pass over HTML cannot be ` +
      `the security control, and a comment implying it is stops the real one from ` +
      `being added. Docstring was:\n${docComment}`,
  );
});

/* ── the known limits, pinned as behaviour ─────────────────────────────────── */

/**
 * These are NOT aspirations. They are the measured, documented limits of a
 * regex pass, kept executable so nobody rediscovers them as a surprise — and
 * so the docstring above can never quietly reclaim them.
 */
test("KNOWN LIMITS: slash-separated handlers, entity-encoded schemes and srcdoc survive", () => {
  for (const v of [
    "<img/onerror=alert(1) src=x>",
    "<svg/onload=alert(1)>",
    '<a href="jav&#x61;script:alert(1)">x</a>',
    '<iframe srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;">',
  ]) {
    assert.equal(
      sanitizeTrustedHtml(v),
      v,
      `${JSON.stringify(v)} is now filtered — good, but the docstring's known-limits ` +
        `list and this test must be updated together`,
    );
  }
});
