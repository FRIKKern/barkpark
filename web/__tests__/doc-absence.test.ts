/**
 * Tests for the REAL absent-vs-unavailable ruling (`lib/doc-absence.ts`) that
 * `lib/get-document.ts` routes every throw through. Not a hand-kept mirror:
 * this module imports only `@barkpark/core`, so `node --test` loads the shipped
 * code and the SHIPPED error classes directly.
 *
 * The defect under pin: `get-document.ts` turned EVERY throw into
 * `{ doc: null, error: message }`, which its three consumers read as "upstream
 * unavailable". `js/packages/core/src/docs.ts` makes the slug-query leg REJECT
 * with `BarkparkNotFoundError` when the TYPE is unknown or private to the token
 * (a decided asymmetry, wave-7 D72), so a document that does not exist rendered
 * the red "Failed to load document." panel behind an HTTP 200 instead of a
 * 404 — a soft-404 reachable by a hand-typed URL and by any crawler.
 *
 * NAMED MUTANTS each test kills:
 *   • swallow-everything-as-failure → the not-found tests red (no 404)
 *   • swallow-everything-as-absent  → the outage tests red (real failures hidden)
 *   • instanceof-instead-of-code    → the cross-realm test reds
 *   • drop-the-message              → the message-preserved test reds
 *   • unwire-get-document           → the SHIPPED wiring test reds
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  BarkparkNotFoundError,
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkTimeoutError,
} from "@barkpark/core";
import { docResultFromError } from "../lib/doc-absence.ts";

/* ── absent → 404 ───────────────────────────────────────────────────────── */

test("an upstream 404 is ABSENCE — no error, so the page 404s honestly", () => {
  const err = new BarkparkNotFoundError("schema unknown: project", {
    status: 404,
  });
  assert.deepEqual(docResultFromError(err), { doc: null, error: null });
});

test("the not-found message is DISCARDED on purpose, not surfaced", () => {
  // Surfacing it is what produced the red panel. `error: null` is the whole
  // point: it is the signal `page.tsx`'s `if (!doc && !error) notFound()` reads.
  const { error } = docResultFromError(
    new BarkparkNotFoundError("no such type", { status: 404 }),
  );
  assert.equal(error, null);
});

/* ── unavailable → keep the panel ───────────────────────────────────────── */

test("a real outage stays a FAILURE and keeps its message", () => {
  // The opposite mistake would be just as dishonest: degrading a 500 or a
  // timeout to a 404 hides an outage behind a "not found".
  for (const err of [
    new BarkparkAPIError("upstream exploded", { status: 500 }),
    new BarkparkAuthError("token rejected", { status: 401 }),
    new BarkparkTimeoutError("request timed out", { status: 0 }),
  ]) {
    const out = docResultFromError(err);
    assert.equal(out.doc, null);
    assert.equal(
      out.error,
      err.message,
      `${err.name} must keep its message, not become an absence`,
    );
  }
});

test("a plain Error keeps its message", () => {
  assert.deepEqual(docResultFromError(new Error("boom")), {
    doc: null,
    error: "boom",
  });
});

test("a NON-Error throw is stringified rather than lost", () => {
  assert.deepEqual(docResultFromError("just a string"), {
    doc: null,
    error: "just a string",
  });
  assert.equal(docResultFromError(null).error, "null");
  assert.equal(docResultFromError(undefined).error, "undefined");
});

/* ── the predicate ──────────────────────────────────────────────────────── */

test("membership keys on the error CODE, not on instanceof", () => {
  // `@barkpark/core` is linked by `file:` in this monorepo, so a second copy of
  // the class in another module realm would defeat an `instanceof` check while
  // the code comparison holds. This shape-only object is that second realm.
  const foreign = Object.assign(new Error("not found"), {
    code: "BarkparkNotFoundError",
    status: 404,
  });
  assert.deepEqual(docResultFromError(foreign), { doc: null, error: null });
});

test("an error carrying a DIFFERENT barkpark code is not an absence", () => {
  const foreign = Object.assign(new Error("rate limited"), {
    code: "BarkparkRateLimitError",
  });
  assert.equal(docResultFromError(foreign).error, "rate limited");
});

/* ── shipped wiring ─────────────────────────────────────────────────────── */

test("SHIPPED (lib/get-document.ts): every throw is routed through the ruling", () => {
  // `get-document.ts` imports `next/cache`, which does not resolve under bare
  // `node --test`, so this reads the shipped bytes — the idiom
  // `template-webhook-lazy.test.ts` uses. Without it, unwiring the catch would
  // leave every test above green while the soft-404 came back.
  const src = readFileSync(
    fileURLToPath(new URL("../lib/get-document.ts", import.meta.url)),
    "utf8",
  );
  assert.match(
    src,
    /catch \(err\) \{\s*return docResultFromError\(err\);\s*\}/,
    "the catch must delegate to docResultFromError, not shape the result itself",
  );
  assert.ok(
    !/error:\s*err instanceof Error \? err\.message : String\(err\)/.test(src),
    "the old catch-all that made every throw a failure must be gone",
  );
});
