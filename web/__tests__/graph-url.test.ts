/**
 * Tests for `corpusGraphUrl` — the ONE flat `/v1/graph` URL `lib/graph.ts`
 * calls for the landing's corpus graph (task-96fc3fb4fb41d242 /
 * task-c75c726062c0fc0c, the same defect filed twice).
 *
 * THE CASE THAT MATTERS is the SCOPED base. `web/` is deployed today against a
 * bare origin, so the old concatenation and the origin derivation agree and no
 * current environment exercises the difference — the defect is LATENT, not
 * live. The moment web is pointed at the managed deploy path's scoped
 * `BARKPARK_API_URL` (`<origin>/w/:ws/p/:proj`), concatenation produces
 * `…/w/ws/p/proj/v1/graph`, which 404s, and the landing renders an EMPTY graph
 * with no error. `templates/search-starter/lib/graph.ts` was fixed for exactly
 * that (PR #3842, live-caught: the health gate refused the deploy); web/ never
 * got the fix.
 *
 * The flat case is asserted alongside so the derivation cannot regress the
 * shape that IS in production.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/graph-url.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { corpusGraphUrl } from "../lib/graph-url.ts";

test("FLAT base — the shape web ships today — is unchanged", () => {
  assert.equal(
    corpusGraphUrl("https://api.barkpark.cloud", "production"),
    "https://api.barkpark.cloud/v1/graph?dataset=production",
  );
});

test("flat base with a port (the local-dev default) keeps the port", () => {
  assert.equal(
    corpusGraphUrl("http://localhost:4000", "production"),
    "http://localhost:4000/v1/graph?dataset=production",
  );
});

test("SCOPED base — the managed deploy shape — drops the /w/:ws/p/:proj prefix", () => {
  const url = corpusGraphUrl(
    "https://api.barkpark.cloud/w/acme/p/site",
    "production",
  );
  assert.equal(url, "https://api.barkpark.cloud/v1/graph?dataset=production");
  // The concatenation this replaces produced `…/w/acme/p/site/v1/graph`, which
  // 404s on this flat endpoint and empties the corpus. Name it explicitly so a
  // regression cannot pass by matching only the suffix.
  assert.equal(url.includes("/w/acme"), false, "scope prefix must be stripped");
  assert.equal(url.includes("/p/site"), false, "scope prefix must be stripped");
  assert.equal(new URL(url).pathname, "/v1/graph");
});

test("scoped base with a trailing slash also yields the bare origin", () => {
  assert.equal(
    corpusGraphUrl("https://api.barkpark.cloud/w/acme/p/site/", "production"),
    "https://api.barkpark.cloud/v1/graph?dataset=production",
  );
});

test("the dataset is URL-encoded", () => {
  assert.equal(
    corpusGraphUrl("https://api.barkpark.cloud/w/acme/p/site", "my dataset&x"),
    "https://api.barkpark.cloud/v1/graph?dataset=my%20dataset%26x",
  );
});
