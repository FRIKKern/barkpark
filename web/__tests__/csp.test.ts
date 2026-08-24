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
import { DEFAULT_TILE_URL, TILE_SUBDOMAINS } from "../lib/map-tiles.ts";

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

/* ── img-src and the map landing's basemap tiles ─────────────────────────── */

/**
 * These arms exist because `img-src` was the bare `'self' data: blob:` while
 * `components/listings-map.tsx` loaded every basemap tile from an EXTERNAL
 * host. The app's own policy blocked its own map's tiles — on every request, in
 * every deployment — and the map degrades to a bare graticule without
 * complaining, so nothing on screen ever said so.
 *
 * The first arm is deliberately NOT a string comparison: it builds the tile URL
 * the way the MAP builds it and asks the POLICY whether that exact request is
 * allowed. A future edit that changes either side alone reds it.
 */

const MAP_ENV_KEYS = [
  "NEXT_PUBLIC_FINDER_LANDING",
  "NEXT_PUBLIC_MAP_TILES",
  "NEXT_PUBLIC_MAP_TILE_URL",
] as const;

/** Run `fn` with exactly `env` set for the three map vars, then restore. */
function withMapEnv(
  env: Partial<Record<(typeof MAP_ENV_KEYS)[number], string>>,
  fn: () => void,
): void {
  const prior = MAP_ENV_KEYS.map((k) => [k, process.env[k]] as const);
  for (const k of MAP_ENV_KEYS) {
    const v = env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    fn();
  } finally {
    for (const [k, v] of prior) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

/** The sources an `img-src` directive lists, minus the directive name. */
function imgSources(policy: string): string[] {
  return directive(policy, "img-src").split(/\s+/).slice(1);
}

/**
 * Would a browser enforcing `policy` let this exact URL load as an image?
 *
 * Host-source matching is by ORIGIN — the comparison the real defect turned on.
 * The keyword/scheme sources (`'self'`, `data:`, `blob:`) never match an
 * absolute cross-origin https URL, so ignoring them here is correct.
 */
function imgAllowed(policy: string, url: string): boolean {
  const origin = new URL(url).origin;
  return imgSources(policy).includes(origin);
}

/** The URL `listings-map.tsx`'s `getTile` builds for one tile, verbatim — the
 * same four placeholder substitutions, including `"abc"[(x + y) % 3]`. */
function mapTileRequestUrl(
  template: string,
  z: number,
  x: number,
  y: number,
): string {
  return template
    .replace("{z}", String(z))
    .replace("{x}", String(x))
    .replace("{y}", String(y))
    .replace("{s}", TILE_SUBDOMAINS[(x + y) % TILE_SUBDOMAINS.length]);
}

test("img-src ALLOWS the exact tile URL the map requests (the whole defect)", () => {
  withMapEnv({ NEXT_PUBLIC_FINDER_LANDING: "map" }, () => {
    const policy = buildCspPolicy("n");
    const url = mapTileRequestUrl(DEFAULT_TILE_URL, 5, 16, 11);
    assert.ok(
      imgAllowed(policy, url),
      `the map requests ${url} but img-src does not allow it: ${directive(policy, "img-src")}`,
    );
  });
});

test("img-src allows every {s} subdomain the map cycles through — not the literal {s}", () => {
  const template = "https://{s}.tile.example.com/{z}/{x}/{y}.png";
  withMapEnv(
    { NEXT_PUBLIC_FINDER_LANDING: "map", NEXT_PUBLIC_MAP_TILE_URL: template },
    () => {
      const policy = buildCspPolicy("n");
      // (x + y) % 3 reaches all three, so all three must be allowed.
      for (let i = 0; i < TILE_SUBDOMAINS.length; i++) {
        const url = mapTileRequestUrl(template, 4, i, 0);
        assert.ok(
          imgAllowed(policy, url),
          `subdomain tile ${url} is not allowed: ${directive(policy, "img-src")}`,
        );
      }
      // …and the unexpanded spelling, which is never requested, is not listed.
      assert.ok(
        !imgSources(policy).some((s) => s.includes("{s}")),
        `img-src must not carry the literal {s} template: ${directive(policy, "img-src")}`,
      );
    },
  );
});

test("img-src keeps 'self' data: blob: and adds ONLY the tile origin — never a wildcard", () => {
  withMapEnv(
    {
      NEXT_PUBLIC_FINDER_LANDING: "map",
      NEXT_PUBLIC_MAP_TILE_URL: "https://tiles.example.org/{z}/{x}/{y}.png",
    },
    () => {
      const policy = buildCspPolicy("n");
      assert.equal(
        directive(policy, "img-src"),
        "img-src 'self' data: blob: https://tiles.example.org",
      );
      // Same posture rule `connect-src` already holds: exact origins only. A
      // bare scheme wildcard would let an injected payload beacon anywhere.
      assert.ok(
        !imgSources(policy).includes("https:") && !imgSources(policy).includes("*"),
        `img-src must never carry a scheme/host wildcard: ${directive(policy, "img-src")}`,
      );
    },
  );
});

test("img-src is UNCHANGED on the default graph landing — the map never mounts", () => {
  withMapEnv({}, () => {
    assert.equal(
      directive(buildCspPolicy("n"), "img-src"),
      "img-src 'self' data: blob:",
    );
  });
});

test("img-src is UNCHANGED when tiles are switched off — nothing external is fetched", () => {
  withMapEnv(
    { NEXT_PUBLIC_FINDER_LANDING: "map", NEXT_PUBLIC_MAP_TILES: "off" },
    () => {
      assert.equal(
        directive(buildCspPolicy("n"), "img-src"),
        "img-src 'self' data: blob:",
      );
    },
  );
});

test("img-src adds nothing for a same-origin or unparseable tile template", () => {
  for (const template of [
    "/tiles/{z}/{x}/{y}.png",
    "not-a-url",
    "data:image/png;base64,x",
  ]) {
    withMapEnv(
      { NEXT_PUBLIC_FINDER_LANDING: "map", NEXT_PUBLIC_MAP_TILE_URL: template },
      () => {
        assert.equal(
          directive(buildCspPolicy("n"), "img-src"),
          "img-src 'self' data: blob:",
          `template ${template} must contribute no host ('self'/its own scheme covers it)`,
        );
      },
    );
  }
});
