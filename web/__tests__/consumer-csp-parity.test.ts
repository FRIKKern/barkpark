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
 *      `'strict-dynamic'`, and every app carries `object-src 'none'`,
 *      `base-uri 'self'`, `default-src 'self'`.
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

  test(`${app.name}: object-src 'none', base-uri 'self', default-src 'self'`, () => {
    assert.equal(directive(cspSource, "object-src", app.name), "object-src 'none'");
    assert.equal(directive(cspSource, "base-uri", app.name), "base-uri 'self'");
    assert.equal(
      directive(cspSource, "default-src", app.name),
      "default-src 'self'",
    );
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
