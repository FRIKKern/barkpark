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

/* ══ THE BINDING ARM — what makes the arms above non-vacuous ══════════════════
 *
 * Everything above runs against `fetchOrNull`, a LOCAL copy of the swallow. It
 * proves the SHAPE is correct; it proves nothing about the two files that ship.
 *
 * MEASURED, not argued: deleting the line
 *
 *     if (err instanceof BarkparkNotFoundError) return null
 *
 * from BOTH `blog-starter/lib/barkpark.ts` (getDocById) and
 * `website-starter/lib/barkpark.ts` (getDoc) — i.e. restoring the exact 500-on-
 * every-by-id-miss defect this file was written to prevent — left `pnpm test`
 * at "ran 560 tests from 69 files (pass 560, fail 0)", byte-identical to the
 * unmutated run, and left `pnpm --filter create-barkpark-app test` at the same
 * "2 failed | 141 passed | 1 skipped" it already reports on a clean tree (those
 * two are a pre-existing offline-install failure, confirmed by a clean-tree
 * control run). No suite anywhere in the repo noticed.
 *
 * The templates cannot be IMPORTED here: they open with `import 'server-only'`
 * and pull `@barkpark/nextjs/server` plus two sibling modules that do not exist
 * outside a scaffolded project. So the binding is to the bytes, in the same
 * style as `template-webhook-lazy.test.ts` in this directory — a behavioural
 * proof on a mirror, plus a pin that the mirror is still what ships.
 *
 * `readFileSync` throws on a missing path, so a moved or renamed template reds
 * here loudly rather than passing vacuously. */

import { readFileSync } from "node:fs";

const TEMPLATE_ROOT = new URL(
  "../../js/packages/create-barkpark-app/templates/",
  import.meta.url,
);

const SHIPPED: Array<{ rel: string; fn: string }> = [
  { rel: "blog-starter/lib/barkpark.ts", fn: "getDocById" },
  { rel: "website-starter/lib/barkpark.ts", fn: "getDoc" },
];

for (const { rel, fn } of SHIPPED) {
  test(`BINDING: ${rel} — ${fn} still swallows BarkparkNotFoundError to null`, () => {
    const src = readFileSync(new URL(rel, TEMPLATE_ROOT), "utf8");
    assert.ok(
      src.length > 0,
      `${rel} is empty — nothing was actually scanned.`,
    );

    // The corpus self-check: if the function this pin is about is not in the
    // file at all, the pin below would be asserting over the wrong module.
    assert.match(
      src,
      new RegExp(`export async function ${fn}\\b`),
      `${rel} no longer exports ${fn}() — this pin lost its subject; re-point it.`,
    );

    // The pin itself: the 404 -> null branch, and the rethrow that keeps it
    // from becoming a blanket swallow.
    assert.match(
      src,
      /if \(err instanceof BarkparkNotFoundError\) return null/,
      `${rel}: the BarkparkNotFoundError -> null branch is GONE. Every by-id ` +
        `miss now renders error.tsx (500) instead of not-found.tsx (404), and ` +
        `every downstream \`if (!doc) notFound()\` is dead code again.`,
    );
    assert.match(
      src,
      /if \(err instanceof BarkparkNotFoundError\) return null\s*\n\s*throw err/,
      `${rel}: the 404 branch is no longer followed by \`throw err\` — a ` +
        `catch that does not rethrow turns every 500 into a silent 404.`,
    );
  });
}
