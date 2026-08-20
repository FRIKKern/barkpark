/**
 * Pins the by-id 404-swallow in the create-barkpark-app starter templates
 * (task wtc-w1-s1-byid-notfound-swallow):
 *
 *   - blog-starter/lib/barkpark.ts  → getDocById
 *   - website-starter/lib/barkpark.ts → getDoc
 *
 * Both now wrap `barkparkFetch` in try/catch: on a BarkparkNotFoundError (the
 * class `barkparkFetch` throws for a 404) they return null so App Router's
 * downstream `if (!doc) notFound()` renders not-found.tsx (404) instead of the
 * error boundary (500); every OTHER error rethrows. Without the swallow, the
 * raw throw carries no NEXT_NOT_FOUND digest and every by-id miss 500s.
 *
 * This test is self-contained by design (no `@/` or `@barkpark/*` imports — the
 * templates are not part of web/'s module graph). It inlines the EXACT swallow
 * shape from the templates and a minimal BarkparkNotFoundError-shaped error and
 * asserts both branches: NotFound → null, generic → rethrow.
 *
 * Run: `cd web && node --test __tests__/template-notfound-swallow.test.ts`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

// Minimal stand-in mirroring @barkpark/core's `BarkparkNotFoundError` (a
// subclass in the BarkparkError → BarkparkAPIError → BarkparkNotFoundError
// chain). The templates match with `instanceof`, so the branch under test only
// depends on the class identity, which this local class reproduces.
class BarkparkNotFoundError extends Error {
  readonly code = "BarkparkNotFoundError";
}

// The inlined swallow — byte-for-byte the shape both template helpers use:
// call the (injected) fetch, return its result; on BarkparkNotFoundError return
// null; rethrow all else.
async function fetchOrNull<T>(
  fetchFn: () => Promise<{ result: T | null }>,
): Promise<T | null> {
  try {
    const env = await fetchFn();
    return env.result;
  } catch (err) {
    if (err instanceof BarkparkNotFoundError) return null;
    throw err;
  }
}

test("swallow: a BarkparkNotFoundError (404) resolves to null", async () => {
  const result = await fetchOrNull<{ _id: string }>(() => {
    throw new BarkparkNotFoundError("no such document");
  });
  assert.equal(result, null);
});

test("swallow: a resolved envelope passes its result through untouched", async () => {
  const doc = { _id: "post-1" };
  const result = await fetchOrNull<{ _id: string }>(async () => ({
    result: doc,
  }));
  assert.equal(result, doc);
});

test("swallow: a null envelope result stays null", async () => {
  const result = await fetchOrNull<{ _id: string }>(async () => ({
    result: null,
  }));
  assert.equal(result, null);
});

test("rethrow: a generic Error (e.g. a 500) is NOT swallowed", async () => {
  await assert.rejects(
    fetchOrNull<{ _id: string }>(() => {
      throw new Error("upstream 500");
    }),
    /upstream 500/,
  );
});

test("rethrow: a non-404 Barkpark-shaped error is NOT swallowed", async () => {
  class BarkparkAuthError extends Error {
    readonly code = "BarkparkAuthError";
  }
  await assert.rejects(
    fetchOrNull<{ _id: string }>(() => {
      throw new BarkparkAuthError("401 unauthorized");
    }),
    /401 unauthorized/,
  );
});
