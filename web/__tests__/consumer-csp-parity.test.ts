/**
 * Cross-consumer CSP parity guard (arpss-consumer-csp-parity-guard).
 *
 * One in-fence regression test that locks the WHOLE consumer cohort's CSP
 * posture in one place. It reads the CSP SOURCE TEXT of all three consumer
 * apps — web/ itself plus the two scaffold templates (in BOTH of their
 * mirrors: `cloud/priv/templates/` and
 * `js/packages/create-barkpark-app/templates/`) — and asserts:
 *
 *   1. POSTURE PARITY: no app's `script-src` ever contains `'unsafe-inline'`
 *      (with it present the nonce is meaningless and an injected inline
 *      `<script>` executes), every app's `script-src` is nonce-based with
 *      `'strict-dynamic'`, and every app reproduces the WHOLE fixed security
 *      floor exactly (see FIXED_FLOOR below).
 *   1b. DIRECTIVE-SET PARITY: every app declares exactly the same ten directive
 *      names. A DROPPED directive is the failure this catches — an absent
 *      `frame-ancestors` does not fall back to `'none'`, it falls back to
 *      framable, and a guard that only queries the directives it expects to
 *      find cannot see a deletion.
 *   1c. NO WILDCARD: no directive in any app may contain a bare `*` source.
 *
 * ## Why 1/1b/1c look the way they do (2026-08-31)
 *
 * This guard used to assert only FOUR directives — `script-src`, `object-src`,
 * `base-uri`, `default-src` — out of the ten each policy declares. The other
 * six (`style-src`, `img-src`, `font-src`, `connect-src`, `frame-ancestors`,
 * `form-action`) were read by nothing at all. MEASURED: rewriting
 *   "frame-ancestors 'none'"  ->  "frame-ancestors *"
 * in BOTH blog-starter mirrors — a total clickjacking hole in the template the
 * cloud deploy button ships and `create-barkpark-app` scaffolds — left this
 * suite at 12/12 pass, exit 0. DELETING the `frame-ancestors` line outright
 * also left it at 12/12 pass, exit 0. `frame-ancestors 'none'` is asserted for
 * `web/lib/csp.ts` (__tests__/csp.test.ts) and for the SDK
 * (js/packages/nextjs/tests/csp.test.ts), but for the two TEMPLATE apps nothing
 * checked it. A guard that compares a subset of the surface reads as coverage
 * while failing silently — worse than no guard. Hence: the floor is asserted
 * WHOLE, the directive SET is pinned, and additions are constrained rather
 * than ignored.
 *
 * The eventual fix is for all three apps to consume
 * `js/packages/nextjs/src/csp/index.ts` — the SDK module that already exists
 * precisely because "five copies later the policies had measurably DRIFTED"
 * (its own words). Until the templates can take an `@barkpark/*` dependency
 * without losing their copy-pasteable property, this guard is what keeps the
 * three forks honest.
 *   2. THE TWO-HEADER PATTERN: each app's proxy/middleware stamps
 *      `content-security-policy` on BOTH the forwarded REQUEST headers (so
 *      Next nonces its own inline bootstrap scripts — dropping this bricks
 *      App-Router hydration into a static shell) and the RESPONSE headers
 *      (the copy the browser actually enforces). A template that regresses
 *      to response-only reds here.
 *   3. MIRROR IDENTITY: each template's two mirrors are byte-identical, so a
 *      fix landing in one mirror and not the other is caught.
 *
 * Source-text analysis is deliberate: the template files are standalone by
 * design (copy-pasteable, importing nothing from `@barkpark/*`) and live
 * outside web/'s compile unit, so importing them here would couple web/'s
 * typecheck to foreign trees. Reading the text keeps the guard in-fence while
 * still failing when any of the five files vanishes (readFileSync throws).
 *
 * Run: `cd web && node --test --import ./__tests__/support/stub-server-only.mjs __tests__/consumer-csp-parity.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const read = (rel: string): string =>
  readFileSync(path.join(repoRoot, rel), "utf8");

/** The three consumer apps. `mirror` is the second copy of the same template
 * (create-barkpark-app ships what cloud/ scaffolds) — asserted byte-identical
 * below so a one-mirror fix cannot silently strand the other. */
const APPS: {
  name: string;
  csp: string;
  proxy: string;
  mirror?: { csp: string; proxy: string };
}[] = [
  {
    name: "web demo",
    csp: "web/lib/csp.ts",
    proxy: "web/proxy.ts",
  },
  {
    name: "blog-starter template",
    csp: "cloud/priv/templates/blog-starter/lib/csp.ts",
    proxy: "cloud/priv/templates/blog-starter/middleware.ts",
    mirror: {
      csp: "js/packages/create-barkpark-app/templates/blog-starter/lib/csp.ts",
      proxy: "js/packages/create-barkpark-app/templates/blog-starter/middleware.ts",
    },
  },
  {
    name: "website-starter template",
    csp: "cloud/priv/templates/website-starter/lib/csp.ts",
    proxy: "cloud/priv/templates/website-starter/middleware.ts",
    mirror: {
      csp: "js/packages/create-barkpark-app/templates/website-starter/lib/csp.ts",
      proxy: "js/packages/create-barkpark-app/templates/website-starter/middleware.ts",
    },
  },
];

/**
 * Extract the policy's directive strings from a csp.ts source.
 *
 * Scoped to the `return [ … ].join` region of `buildCspPolicy` so prose in
 * file-header comments (which freely mentions `script-src`) is never read as
 * a directive. Within the region, a quoted string counts as a directive for
 * `name` only when it is `name` followed by a space and at least one value
 * token — a bare backticked \`script-src\` in an inline comment does not
 * qualify.
 */
function directiveCandidates(source: string, name: string): string[] {
  // Both shapes in the wild are covered: `return [ … ].join(…)` (web, the
  // blog template) and `const directives = [ … ]; return directives.join(…)`
  // (the website template) — everything from the function keyword to its
  // first `.join` is the policy-array region.
  const start = source.indexOf("function buildCspPolicy");
  const end = source.indexOf(".join", start);
  assert.ok(
    start !== -1 && end > start,
    "csp source no longer contains a joined buildCspPolicy array — update this guard's extractor",
  );
  const region = source.slice(start, end);
  const out: string[] = [];
  // One quoted string literal at a time; quotes differ per file (web uses
  // double quotes, templates use single quotes and backticks).
  // Same-quote pairs: the content may contain the OTHER quote characters
  // (every directive value uses inner single quotes, e.g. `object-src 'none'`).
  const literal = /(["'`])((?:(?!\1)[^\n])+)\1/g;
  for (const m of region.matchAll(literal)) {
    const s = m[2];
    if (s === name || s.startsWith(`${name} `)) out.push(s);
  }
  return out;
}

/**
 * EVERY directive name declared in the policy array, in source order.
 *
 * Unlike {@link directiveCandidates} this does not take a name to look for —
 * that asymmetry was the old guard's blind spot: you cannot notice a DELETED
 * directive by querying for the ones you expect. A string literal counts as a
 * directive when it looks like `<lowercase-dashed-name> <at least one token>`.
 */
function declaredDirectives(source: string): string[] {
  const start = source.indexOf("function buildCspPolicy");
  const end = source.indexOf(".join", start);
  assert.ok(
    start !== -1 && end > start,
    "csp source no longer contains a joined buildCspPolicy array — update this guard's extractor",
  );
  const region = source.slice(start, end);
  const out: string[] = [];
  const literal = /(["'`])((?:(?!\1)[^\n])+)\1/g;
  for (const m of region.matchAll(literal)) {
    const s = m[2];
    const name = /^([a-z]+(?:-[a-z]+)*) \S/.exec(s)?.[1];
    if (name) out.push(name);
  }
  return out;
}

/**
 * The directives whose value is IDENTICAL in every consumer app and is not a
 * per-app knob. Literal, committed expectations — never derived from any file
 * under test, which would agree with a gutted one by construction.
 */
const FIXED_FLOOR: Record<string, string> = {
  "default-src": "default-src 'self'",
  "style-src": "style-src 'self' 'unsafe-inline'",
  "font-src": "font-src 'self'",
  "object-src": "object-src 'none'",
  "base-uri": "base-uri 'self'",
  "frame-ancestors": "frame-ancestors 'none'",
  "form-action": "form-action 'self'",
};

/**
 * The directives an app may legitimately WIDEN, and the sources each must still
 * carry no matter how it widens (website-starter adds `https:` to `img-src` for
 * hosted hero images; web/ adds a WebSocket origin to `connect-src`).
 */
const WIDENABLE_MINIMUM: Record<string, string[]> = {
  "script-src": ["'self'", "'nonce-", "'strict-dynamic'"],
  "img-src": ["'self'", "data:", "blob:"],
  "connect-src": ["'self'"],
};

/**
 * The complete directive set every consumer app must declare — a literal,
 * committed list of ten names. An app that DROPS one reds here.
 */
const REQUIRED_DIRECTIVE_SET: string[] = [
  ...Object.keys(FIXED_FLOOR),
  ...Object.keys(WIDENABLE_MINIMUM),
].sort();

/** The single real directive for `name`, asserted to exist exactly once. */
function directive(source: string, name: string, app: string): string {
  const found = directiveCandidates(source, name).filter((s) =>
    s.startsWith(`${name} `),
  );
  assert.equal(
    found.length,
    1,
    `${app}: expected exactly one ${name} directive in the policy array, got ${JSON.stringify(found)}`,
  );
  return found[0];
}

test("extractor self-test: finds a real directive, refuses prose and impossible names", () => {
  const sample = [
    "// `script-src` allows only nonced inline scripts",
    "export function buildCspPolicy(nonce: string): string {",
    "  return [",
    "    `default-src 'self'`,",
    "    // prose mentioning `script-src` mid-array",
    "    `script-src 'self' 'nonce-${'${nonce}'}'`,",
    "  ].join('; ');",
    "}",
  ].join("\n");
  assert.equal(directive(sample, "default-src", "self-test"), "default-src 'self'");
  assert.ok(directive(sample, "script-src", "self-test").includes("'nonce-"));
  // Impossible-name control: a directive that exists nowhere yields zero
  // candidates — proving the extractor does not match everything.
  assert.equal(directiveCandidates(sample, "no-such-src").length, 0);
});

test("self-test: the new legs catch a rewritten, a deleted, and a wildcarded directive", () => {
  const good = [
    "export function buildCspPolicy(nonce: string): string {",
    "  return [",
    "    \"default-src 'self'\",",
    "    `script-src 'self' 'nonce-${'${nonce}'}' 'strict-dynamic'`,",
    "    \"style-src 'self' 'unsafe-inline'\",",
    "    \"img-src 'self' data: blob:\",",
    "    \"font-src 'self'\",",
    "    \"connect-src 'self'\",",
    "    \"object-src 'none'\",",
    "    \"base-uri 'self'\",",
    "    \"frame-ancestors 'none'\",",
    "    \"form-action 'self'\",",
    "  ].join('; ');",
    "}",
  ].join("\n");

  // Baseline: the shape the real files have must SATISFY all three new legs,
  // or the legs are testing something other than what ships.
  assert.deepEqual(
    [...new Set(declaredDirectives(good))].sort(),
    REQUIRED_DIRECTIVE_SET,
  );
  assert.equal(directive(good, "frame-ancestors", "self-test"), "frame-ancestors 'none'");

  // 1. REWRITTEN — the exact mutation that passed the old guard at 12/12.
  const wildcarded = good.replace("frame-ancestors 'none'", "frame-ancestors *");
  assert.notEqual(
    directive(wildcarded, "frame-ancestors", "self-test"),
    FIXED_FLOOR["frame-ancestors"],
  );

  // 2. DELETED — the case a name-query guard structurally cannot see.
  const deleted = good
    .split("\n")
    .filter((l) => !l.includes("frame-ancestors"))
    .join("\n");
  assert.ok(
    !declaredDirectives(deleted).includes("frame-ancestors"),
    "the set extractor must NOTICE a deleted directive",
  );
  assert.notDeepEqual(
    [...new Set(declaredDirectives(deleted))].sort(),
    REQUIRED_DIRECTIVE_SET,
  );

  // 3. WILDCARD — a `*` source anywhere is detectable by the regex used above.
  assert.ok(/(^|\s)\*(\s|$)/.test("frame-ancestors *"));
  assert.ok(!/(^|\s)\*(\s|$)/.test("img-src 'self' data: blob: https:"));
});

for (const app of APPS) {
  const cspSource = read(app.csp);
  const proxySource = read(app.proxy);

  test(`${app.name}: script-src is nonce-based and NEVER 'unsafe-inline'`, () => {
    // Every candidate is checked, not just the first — a second, laxer
    // script-src entry could not hide behind a strict one.
    const candidates = directiveCandidates(cspSource, "script-src").filter(
      (s) => s.startsWith("script-src "),
    );
    assert.ok(candidates.length >= 1, `${app.csp}: no script-src directive found`);
    for (const scriptSrc of candidates) {
      assert.ok(
        !scriptSrc.includes("unsafe-inline"),
        `${app.csp}: script-src must never allow 'unsafe-inline': ${scriptSrc}`,
      );
      assert.ok(
        scriptSrc.includes("'nonce-"),
        `${app.csp}: script-src must be nonce-based: ${scriptSrc}`,
      );
      assert.ok(
        scriptSrc.includes("'strict-dynamic'"),
        `${app.csp}: script-src must carry 'strict-dynamic': ${scriptSrc}`,
      );
    }
  });

  test(`${app.name}: the WHOLE fixed security floor, verbatim`, () => {
    // All seven, not the three this guard used to check. A `frame-ancestors *`
    // rewrite passed the old version of this test at 12/12.
    for (const [name, expected] of Object.entries(FIXED_FLOOR)) {
      assert.equal(
        directive(cspSource, name, app.name),
        expected,
        `${app.csp}: ${name} must be exactly \`${expected}\` — it is part of the fixed floor, not a per-app knob`,
      );
    }
  });

  test(`${app.name}: declares the complete ten-directive set (nothing DROPPED)`, () => {
    const declared = [...new Set(declaredDirectives(cspSource))].sort();
    assert.deepEqual(
      declared,
      REQUIRED_DIRECTIVE_SET,
      `${app.csp}: the declared directive set drifted from the cohort. A MISSING directive is the ` +
        `dangerous case — an absent frame-ancestors is framable, not 'none'. ` +
        `missing=${JSON.stringify(REQUIRED_DIRECTIVE_SET.filter((d) => !declared.includes(d)))} ` +
        `unexpected=${JSON.stringify(declared.filter((d) => !REQUIRED_DIRECTIVE_SET.includes(d)))}`,
    );
  });

  test(`${app.name}: widenable directives still carry their base sources, and NO directive is a wildcard`, () => {
    for (const [name, required] of Object.entries(WIDENABLE_MINIMUM)) {
      const found = directive(cspSource, name, app.name);
      for (const src of required) {
        assert.ok(
          found.includes(src),
          `${app.csp}: ${name} must still carry ${src} however it is widened: ${found}`,
        );
      }
    }
    // A bare `*` source defeats whatever directive carries it. Checked across
    // EVERY declared directive, floor and widenable alike.
    const start = cspSource.indexOf("function buildCspPolicy");
    const region = cspSource.slice(start, cspSource.indexOf(".join", start));
    for (const m of region.matchAll(/(["'`])((?:(?!\1)[^\n])+)\1/g)) {
      const s = m[2];
      if (!/^[a-z]+(?:-[a-z]+)* \S/.test(s)) continue;
      assert.ok(
        !/(^|\s)\*(\s|$)/.test(s),
        `${app.csp}: a bare \`*\` source makes the directive meaningless: ${s}`,
      );
    }
  });

  test(`${app.name}: CSP is stamped on BOTH the forwarded request headers and the response`, () => {
    // 1. Request-header copy — what Next's renderer reads to nonce its own
    //    inline bootstrap scripts. Without it, hydration dies.
    assert.match(
      proxySource,
      /requestHeaders\.set\(\s*["'`]content-security-policy["'`]/,
      `${app.proxy}: must set content-security-policy on the FORWARDED REQUEST headers (the copy Next reads to nonce its bootstrap scripts)`,
    );
    // 2. …and those forwarded headers actually ride the render pass.
    assert.match(
      proxySource,
      /NextResponse\.next\(\s*\{\s*request/,
      `${app.proxy}: must forward the mutated request headers via NextResponse.next({ request: … })`,
    );
    // 3. Response copy — the one the browser enforces.
    assert.match(
      proxySource,
      /response\.headers\.set\(\s*["'`]content-security-policy["'`]/,
      `${app.proxy}: must set content-security-policy on the RESPONSE headers (the copy the browser enforces)`,
    );
  });

  const mirror = app.mirror;
  if (mirror) {
    test(`${app.name}: both mirrors are byte-identical (cloud/priv vs create-barkpark-app)`, () => {
      assert.equal(
        cspSource,
        read(mirror.csp),
        `${app.csp} and ${mirror.csp} have drifted — land template fixes in BOTH mirrors`,
      );
      assert.equal(
        proxySource,
        read(mirror.proxy),
        `${app.proxy} and ${mirror.proxy} have drifted — land template fixes in BOTH mirrors`,
      );
    });
  }
}
