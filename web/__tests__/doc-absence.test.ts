/**
 * The ABSENT-vs-MISCONFIGURED split for `lib/doc-absence.ts`, which
 * `lib/get-document.ts` routes every fetch through (task-2811a42a66c7b649).
 * Not a hand-kept mirror: this module imports only `@barkpark/core`, so
 * `node --test` loads the shipped code and the SHIPPED error classes directly.
 *
 * THE DEFECT UNDER PIN, in two acts. #13431 fixed a soft-404 — `get-document.ts`
 * turned EVERY throw into `{ doc: null, error: message }`, so a document that
 * did not exist wore the red "Failed to load document." panel behind an HTTP
 * 200. That fix over-shot: it ruled a `BarkparkNotFoundError` ABSENT, verbatim
 * "from the reader's point of view the document is ABSENT, so it 404s".
 *
 * But `js/packages/core/src/docs.ts` is asymmetric on purpose (wave-7 D72): a
 * public type with zero matching documents RESOLVES null, a missing or private
 * TYPE REJECTS, and the by-id leg swallows its own 404 inside core
 * (`js/packages/core/src/doc.ts`). So the only `BarkparkNotFoundError` that can
 * reach the ruling is the TYPE. And `app/(finder)/d/[type]/[slug]/page.tsx`
 * gates on a hard-coded `KNOWN_TYPES` set before any fetch, so an unknown type
 * cannot arrive from a hand-typed URL — it means THIS SITE'S config is wrong.
 * Mistype a schema name and the demo rendered a clean, confident 404 with
 * nothing red and nothing logged.
 *
 * THE TEST THAT WOULD HAVE CAUGHT IT is `both paths are driven, and they
 * DIFFER` below: covering only the absent path is the state that let this ship,
 * so the two are asserted against each other in ONE test rather than apart.
 *
 * NAMED MUTANTS each test kills:
 *   • collapse the buckets (NotFound -> { doc: null, error: null })
 *       → "both paths are driven, and they DIFFER"
 *       → and "an unknown TYPE is surfaced, never reported as a normal absence"
 *   • surface a resolved-null as an error        → "absent is not an error"
 *   • swallow a non-NotFound throw to absent     → "a real outage keeps its message"
 *   • instanceof-instead-of-code                 → the cross-realm test reds
 *   • drop the type from the message             → the message test reds
 *   • unwire-get-document                        → the SHIPPED wiring test reds
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
import { resolveDocOutcome, unknownTypeMessage } from "../lib/doc-absence.ts";

interface Doc {
  _id: string;
}

const DOC: Doc = { _id: "doc-1" };

/** A valid, public type whose slug filter matched nothing: core resolves null. */
const absentDocument = () => Promise.resolve(null);

/** A type the API does not know, or that this token cannot read: core rejects. */
const unknownType = () =>
  Promise.reject(new BarkparkNotFoundError("schema unknown: pots", { status: 404 }));

/* ── the test that would have caught it ──────────────────────────────────── */

test("both paths are driven, and they DIFFER", async () => {
  const absent = await resolveDocOutcome<Doc>("post", absentDocument);
  const misconfigured = await resolveDocOutcome<Doc>("pots", unknownType);

  // A valid type with no matching slug: absent, and that is fine. This is the
  // signal `page.tsx`'s `if (!doc && !error) notFound()` reads.
  assert.deepEqual(absent, { doc: null, error: null });

  // An unknown type name: the operator must see it (document-detail.tsx renders
  // `error` verbatim inside the red panel).
  assert.equal(misconfigured.doc, null);
  assert.equal(typeof misconfigured.error, "string");

  // The whole point. Two 404-shaped outcomes, two different answers — collapse
  // them and this line is the one that reds.
  assert.notDeepEqual(
    absent,
    misconfigured,
    "an absent document and an unknown TYPE must not produce the same result",
  );
});

/* ── bucket 1: absence of DATA is a normal state ─────────────────────────── */

test("absent is not an error — a valid type with no matching slug 404s honestly", async () => {
  const r = await resolveDocOutcome<Doc>("post", absentDocument);
  assert.deepEqual(r, { doc: null, error: null });
});

test("a resolved document passes through untouched", async () => {
  const r = await resolveDocOutcome<Doc>("post", () => Promise.resolve(DOC));
  assert.deepEqual(r, { doc: DOC, error: null });
});

/* ── bucket 2: a misconfiguration the operator must see ──────────────────── */

test("an unknown TYPE is surfaced, never reported as a normal absence", async () => {
  const r = await resolveDocOutcome<Doc>("pots", unknownType);
  assert.equal(r.doc, null);
  assert.notEqual(
    r.error,
    null,
    "a TYPE 404 must NOT land in the absent bucket — that is the whole defect",
  );
  assert.equal(r.error, unknownTypeMessage("pots"));
});

test("the message NAMES the type and BOTH causes", async () => {
  const msg = unknownTypeMessage("pots");
  assert.match(msg, /"pots"/, "the operator must be told WHICH type");
  assert.match(msg, /misspelled/i, "cause 1: the schema name is wrong");
  assert.match(msg, /token/i, "cause 2: the type is not readable by this token");
  // It must not be the upstream's own words: "schema unknown: pots" tells an
  // operator nothing about which of the two things to go and fix.
  const r = await resolveDocOutcome<Doc>("pots", unknownType);
  assert.equal(r.error, msg);
});

/* ── everything else stays a real failure ────────────────────────────────── */

test("a real outage keeps its message", async () => {
  // The opposite mistake would be just as dishonest: degrading a 500 or a
  // timeout to a 404 hides an outage behind a "not found".
  for (const err of [
    new BarkparkAPIError("upstream exploded", { status: 500 }),
    new BarkparkAuthError("token rejected", { status: 401 }),
    new BarkparkTimeoutError("request timed out", { status: 0 }),
  ]) {
    const r = await resolveDocOutcome<Doc>("post", () => Promise.reject(err));
    assert.equal(r.doc, null);
    assert.equal(
      r.error,
      err.message,
      `${err.name} must keep its message, not become an absence`,
    );
    assert.notEqual(
      r.error,
      unknownTypeMessage("post"),
      `${err.name} must not be mislabelled an unknown type`,
    );
  }
});

test("a NON-Error throw is stringified rather than lost", async () => {
  assert.deepEqual(await resolveDocOutcome<Doc>("post", () => Promise.reject("boom")), {
    doc: null,
    error: "boom",
  });
  assert.equal((await resolveDocOutcome<Doc>("post", () => Promise.reject(null))).error, "null");
});

/* ── the predicate ──────────────────────────────────────────────────────── */

test("membership keys on the error CODE, not on instanceof", async () => {
  // `@barkpark/core` is linked by `file:` in this monorepo, so a second copy of
  // the class in another module realm would defeat an `instanceof` check while
  // the code comparison holds. This shape-only object is that second realm.
  const foreign = Object.assign(new Error("schema unknown: pots"), {
    code: "BarkparkNotFoundError",
    status: 404,
  });
  const r = await resolveDocOutcome<Doc>("pots", () => Promise.reject(foreign));
  assert.equal(r.error, unknownTypeMessage("pots"));
});

test("an error carrying a DIFFERENT barkpark code is not an unknown type", async () => {
  const foreign = Object.assign(new Error("rate limited"), {
    code: "BarkparkRateLimitError",
  });
  const r = await resolveDocOutcome<Doc>("post", () => Promise.reject(foreign));
  assert.equal(r.error, "rate limited");
});

/* ── shipped wiring ─────────────────────────────────────────────────────── */

test("SHIPPED (lib/get-document.ts): the fetch is routed through the ruling", () => {
  // `get-document.ts` imports `next/cache`, which does not resolve under bare
  // `node --test`, so this reads the shipped bytes — the idiom
  // `template-webhook-lazy.test.ts` uses. Without it, unwiring the call would
  // leave every test above green while the silent 404 came back.
  const src = readFileSync(
    fileURLToPath(new URL("../lib/get-document.ts", import.meta.url)),
    "utf8",
  );
  assert.match(
    src,
    /resolveDocOutcome<GenericDoc>\(\s*type,\s*\(\) => cachedDoc\(type\)\(slug\),?\s*\)/,
    "getDocument must delegate to resolveDocOutcome, not shape the result itself",
  );
  assert.ok(
    !/catch \(err\)/.test(src),
    "get-document.ts must own no try/catch of its own — the ruling owns classification",
  );
});
