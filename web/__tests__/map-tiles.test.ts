/**
 * Tests for the shared basemap-tile configuration (`lib/map-tiles.ts`).
 *
 * This module exists because two readers must agree exactly: the map builds
 * tile requests from these values, and the CSP builds the `img-src` directive
 * the browser enforces against those same requests. They disagreed — `img-src`
 * named no tile host at all — so every tile the map asked for was blocked by
 * the app's own policy, silently, in every deployment.
 *
 * `__tests__/csp.test.ts` owns the end-to-end arm (does the POLICY allow the
 * URL the MAP builds). These arms pin the derivation itself: what counts as an
 * origin, what the `{s}` expansion produces, and — the load-bearing ones —
 * which inputs must contribute NOTHING, because a fabricated host in a security
 * header is worse than a missing one.
 *
 * Run: `cd web && node --test --import ./__tests__/support/stub-server-only.mjs __tests__/map-tiles.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_TILE_URL,
  TILE_SUBDOMAINS,
  mapLandingActive,
  tileOrigins,
  tileUrlTemplate,
  tilesAllowedByCsp,
  tilesEnabled,
} from "../lib/map-tiles.ts";

const KEYS = [
  "NEXT_PUBLIC_FINDER_LANDING",
  "NEXT_PUBLIC_MAP_TILES",
  "NEXT_PUBLIC_MAP_TILE_URL",
] as const;

/** Run `fn` with exactly `env` set for the three map vars, then restore. */
function withEnv(
  env: Partial<Record<(typeof KEYS)[number], string>>,
  fn: () => void,
): void {
  const prior = KEYS.map((k) => [k, process.env[k]] as const);
  for (const k of KEYS) {
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

test("every value is read at CALL time, not captured at module load", () => {
  // The CSP is rebuilt per request in the edge proxy, so a module-load capture
  // would freeze whatever the very first import happened to see.
  withEnv({ NEXT_PUBLIC_MAP_TILE_URL: "https://one.example/{z}/{x}/{y}.png" }, () => {
    assert.deepEqual(tileOrigins(), ["https://one.example"]);
  });
  withEnv({ NEXT_PUBLIC_MAP_TILE_URL: "https://two.example/{z}/{x}/{y}.png" }, () => {
    assert.deepEqual(tileOrigins(), ["https://two.example"]);
  });
});

test("tileUrlTemplate falls back to the OSM default when unset", () => {
  withEnv({}, () => assert.equal(tileUrlTemplate(), DEFAULT_TILE_URL));
  withEnv({ NEXT_PUBLIC_MAP_TILE_URL: "https://x.example/{z}.png" }, () =>
    assert.equal(tileUrlTemplate(), "https://x.example/{z}.png"),
  );
});

test("tilesEnabled is true unless the value is exactly 'off'", () => {
  withEnv({}, () => assert.equal(tilesEnabled(), true));
  withEnv({ NEXT_PUBLIC_MAP_TILES: "off" }, () => assert.equal(tilesEnabled(), false));
  // Not a truthiness check: any other value keeps tiles on, matching the
  // component's own long-standing `!== "off"` reading.
  withEnv({ NEXT_PUBLIC_MAP_TILES: "on" }, () => assert.equal(tilesEnabled(), true));
  withEnv({ NEXT_PUBLIC_MAP_TILES: "" }, () => assert.equal(tilesEnabled(), true));
});

test("mapLandingActive is true ONLY for the exact value the page switches on", () => {
  // `app/(finder)/page.tsx` compares `landing === "map"`. A looser predicate
  // here would widen img-src on deployments that never mount the map.
  withEnv({ NEXT_PUBLIC_FINDER_LANDING: "map" }, () =>
    assert.equal(mapLandingActive(), true),
  );
  for (const v of ["graph", "Map", "map ", "1", ""]) {
    withEnv({ NEXT_PUBLIC_FINDER_LANDING: v }, () =>
      assert.equal(mapLandingActive(), false, `"${v}" must not activate the map`),
    );
  }
  withEnv({}, () => assert.equal(mapLandingActive(), false));
});

test("tileOrigins strips the path and keeps scheme + host + port", () => {
  withEnv(
    { NEXT_PUBLIC_MAP_TILE_URL: "http://localhost:8080/tiles/{z}/{x}/{y}.png" },
    () => assert.deepEqual(tileOrigins(), ["http://localhost:8080"]),
  );
});

test("tileOrigins expands {s} into one origin per subdomain, in order, deduped", () => {
  withEnv(
    { NEXT_PUBLIC_MAP_TILE_URL: "https://{s}.tile.example.com/{z}/{x}/{y}.png" },
    () =>
      assert.deepEqual(
        tileOrigins(),
        Array.from(TILE_SUBDOMAINS, (s) => `https://${s}.tile.example.com`),
      ),
  );
  // A template whose {s} does not vary the HOST collapses to one entry rather
  // than repeating the same origin three times in the header.
  withEnv(
    { NEXT_PUBLIC_MAP_TILE_URL: "https://tile.example.com/{s}/{z}/{x}/{y}.png" },
    () => assert.deepEqual(tileOrigins(), ["https://tile.example.com"]),
  );
});

test("tileOrigins contributes NOTHING for inputs that name no external host", () => {
  // Each of these would otherwise be a fabricated entry in a security header.
  const noHost: Array<[string, string]> = [
    ["/tiles/{z}/{x}/{y}.png", "same-origin — 'self' already covers it"],
    ["tiles/{z}/{x}/{y}.png", "relative — not a URL at all"],
    ["not-a-url", "garbage"],
    ["data:image/png;base64,AAAA", "opaque origin, never a usable source"],
  ];
  for (const [template, why] of noHost) {
    withEnv({ NEXT_PUBLIC_MAP_TILE_URL: template }, () =>
      assert.deepEqual(tileOrigins(), [], `${template} (${why})`),
    );
  }
  // An empty string is FALSY, so it takes the OSM default — "unset", not
  // "no host". Asserting it keeps that distinction from quietly flipping.
  withEnv({ NEXT_PUBLIC_MAP_TILE_URL: "" }, () =>
    assert.deepEqual(tileOrigins(), ["https://tile.openstreetmap.org"]),
  );
});

test("tilesAllowedByCsp answers 'will my requests be refused', not 'did the policy widen'", () => {
  // External host + the landing that widens the policy → allowed.
  withEnv({ NEXT_PUBLIC_FINDER_LANDING: "map" }, () =>
    assert.equal(tilesAllowedByCsp(), true),
  );

  // External host, landing NOT active → the shipped defect exactly: the map
  // requests tiles the policy refuses. The one case that must be false.
  withEnv({}, () => assert.equal(tilesAllowedByCsp(), false));

  // The three configurations that request nothing external cannot be blocked,
  // and must NOT be reported as blocked — a warning that fires while the map is
  // working correctly is how a real one gets ignored.
  withEnv({ NEXT_PUBLIC_MAP_TILES: "off" }, () =>
    assert.equal(tilesAllowedByCsp(), true, "tiles off: no request is made"),
  );
  withEnv({ NEXT_PUBLIC_MAP_TILE_URL: "/tiles/{z}/{x}/{y}.png" }, () =>
    assert.equal(tilesAllowedByCsp(), true, "same-origin: 'self' covers it"),
  );
  withEnv({ NEXT_PUBLIC_MAP_TILE_URL: "not-a-url" }, () =>
    assert.equal(tilesAllowedByCsp(), true, "unparseable: no request to block"),
  );
});
