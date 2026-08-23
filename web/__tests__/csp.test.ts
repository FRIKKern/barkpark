/**
 * Tests for the web/ demo Content-Security-Policy helper (`lib/csp.ts`).
 *
 * These pin the ANTI-XSS invariants of the consumer-side backstop, not just
 * that a header exists. The load-bearing lock is `refute script-src has
 * 'unsafe-inline'`: with `'unsafe-inline'` present the nonce is meaningless and
 * an injected inline `<script>` executes — so that assertion is what makes the
 * policy a real defense-in-depth layer for the `dangerouslySetInnerHTML` sinks
 * in web/components. The nonce/`strict-dynamic` presence and a rotating nonce
 * are the mechanism that lets the app's own scripts through while blocking
 * injected ones.
 *
 * Run: `cd web && node --test --import ./__tests__/support/stub-server-only.mjs __tests__/csp.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { buildCspPolicy, generateNonce } from "../lib/csp.ts";

/** Pull the single `script-src …` directive out of the joined policy string. */
function directive(policy: string, name: string): string {
  const found = policy
    .split(";")
    .map((d) => d.trim())
    .find((d) => d === name || d.startsWith(`${name} `));
  assert.ok(found, `policy is missing the ${name} directive: ${policy}`);
  return found;
}

test("script-src has NO 'unsafe-inline' (the load-bearing anti-XSS lock)", () => {
  const scriptSrc = directive(buildCspPolicy("abc123"), "script-src");
  assert.ok(
    !scriptSrc.includes("'unsafe-inline'"),
    `script-src must not allow 'unsafe-inline': ${scriptSrc}`,
  );
});

test("script-src carries the request nonce and 'strict-dynamic'", () => {
  const scriptSrc = directive(buildCspPolicy("abc123"), "script-src");
  assert.ok(scriptSrc.includes("'nonce-abc123'"), scriptSrc);
  assert.ok(scriptSrc.includes("'strict-dynamic'"), scriptSrc);
  assert.ok(scriptSrc.includes("'self'"), scriptSrc);
});

test("default-src is 'self'", () => {
  assert.equal(directive(buildCspPolicy("n"), "default-src"), "default-src 'self'");
});

test("object-src is 'none'", () => {
  assert.equal(directive(buildCspPolicy("n"), "object-src"), "object-src 'none'");
});

test("base-uri is 'self'", () => {
  assert.equal(directive(buildCspPolicy("n"), "base-uri"), "base-uri 'self'");
});

test("frame-ancestors is 'none'", () => {
  assert.equal(
    directive(buildCspPolicy("n"), "frame-ancestors"),
    "frame-ancestors 'none'",
  );
});

test("form-action is 'self'", () => {
  assert.equal(directive(buildCspPolicy("n"), "form-action"), "form-action 'self'");
});

test("the nonce is interpolated verbatim into the policy", () => {
  const policy = buildCspPolicy("XYZ==");
  assert.ok(policy.includes("'nonce-XYZ=='"), policy);
});

test("generateNonce() returns distinct values on repeated calls", () => {
  const seen = new Set<string>();
  for (let i = 0; i < 100; i++) seen.add(generateNonce());
  assert.equal(seen.size, 100, "every minted nonce must be unique");
});

test("generateNonce() returns a non-empty string", () => {
  const nonce = generateNonce();
  assert.equal(typeof nonce, "string");
  assert.ok(nonce.length > 0, "nonce must be non-empty");
});

test("connect-src is bare 'self' when NEXT_PUBLIC_BARKPARK_WS_URL is unset", () => {
  const prior = process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
  delete process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
  try {
    assert.equal(directive(buildCspPolicy("n"), "connect-src"), "connect-src 'self'");
  } finally {
    if (prior === undefined) delete process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
    else process.env.NEXT_PUBLIC_BARKPARK_WS_URL = prior;
  }
});

test("connect-src adds the CONFIGURED WS origin, never a bare ws:/wss: wildcard", () => {
  const prior = process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
  process.env.NEXT_PUBLIC_BARKPARK_WS_URL = "wss://api.barkpark.cloud/socket";
  try {
    const connectSrc = directive(buildCspPolicy("n"), "connect-src");
    assert.equal(connectSrc, "connect-src 'self' wss://api.barkpark.cloud");
    assert.ok(
      !/\bws:\b/.test(connectSrc) && !/\bwss:\b/.test(connectSrc),
      `connect-src must never carry a bare ws:/wss: wildcard: ${connectSrc}`,
    );
  } finally {
    if (prior === undefined) delete process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
    else process.env.NEXT_PUBLIC_BARKPARK_WS_URL = prior;
  }
});

test("connect-src drops a port-carrying WS origin's path but keeps scheme+host+port", () => {
  const prior = process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
  process.env.NEXT_PUBLIC_BARKPARK_WS_URL = "ws://localhost:4000/socket/websocket";
  try {
    assert.equal(
      directive(buildCspPolicy("n"), "connect-src"),
      "connect-src 'self' ws://localhost:4000",
    );
  } finally {
    if (prior === undefined) delete process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
    else process.env.NEXT_PUBLIC_BARKPARK_WS_URL = prior;
  }
});

test("connect-src falls back to bare 'self' on an unparseable WS URL", () => {
  const prior = process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
  process.env.NEXT_PUBLIC_BARKPARK_WS_URL = "not-a-url";
  try {
    assert.equal(directive(buildCspPolicy("n"), "connect-src"), "connect-src 'self'");
  } finally {
    if (prior === undefined) delete process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
    else process.env.NEXT_PUBLIC_BARKPARK_WS_URL = prior;
  }
});
