// The absent-vs-misconfigured split, pinned (task-3771c96a4b554eeb).
//
// THE DEFECT: `getDocument` caught EVERY `BarkparkNotFoundError` into
// `{ doc: null, error: null }` — the "absent, and that is fine" bucket — and a
// confident comment defended it. But `js/packages/core/src/docs.ts` is
// asymmetric on purpose (wave-7 D72): a public type with zero matching
// documents RESOLVES null, a missing or private TYPE REJECTS, and the by-id leg
// swallows its own 404 inside core. So the only `BarkparkNotFoundError` that
// can reach the ruling is the TYPE — and it was being reported as an ordinary
// empty result. Mistype a schema name in the template's config (which is where
// `DOC_TYPES`, and therefore the route's own `KNOWN_TYPES` guard, comes from)
// and the site renders a clean, confident 404. Nothing red, nothing logged.
//
// THE TEST THAT WOULD HAVE CAUGHT IT is `both paths are driven, and they
// DIFFER` below: covering only the absent path is the state that let this ship,
// so the two are asserted against each other in one test rather than apart.
//
// MUTATION MAP — reintroduce the defect and a NAMED assertion reds:
//   • collapse the buckets (NotFound -> { doc: null, error: null })
//       → "an unknown TYPE is surfaced, never reported as a normal absence"
//       → and the differ-assertion in the both-paths test
//   • surface a resolved-null as an error       → "absent is not an error"
//   • swallow a non-NotFound throw to absent    → "a real outage keeps its message"
import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";

// doc-absence.ts imports `@barkpark/core` (a `file:` vendor tarball). These
// hooks point that specifier at a four-line port of `isBarkparkError`; the
// ruling itself runs unstubbed.
register(new URL("./__test-stub-hooks.mjs", import.meta.url));

const { BarkparkNotFoundError } = await import("./__test-stub-barkpark-core.mjs");
const { resolveDocOutcome, unknownTypeMessage } = await import("./doc-absence.ts");

interface Doc {
  _id: string;
}

const DOC: Doc = { _id: "doc-1" };

/** A valid, public type whose slug filter matched nothing: core resolves null. */
const absentDocument = () => Promise.resolve(null);

/** A type the API does not know, or that this token cannot read: core rejects. */
const unknownType = () =>
  Promise.reject(new BarkparkNotFoundError("schema unknown: pots"));

/* ── the test that would have caught it ──────────────────────────────────── */

test("both paths are driven, and they DIFFER", async () => {
  const absent = await resolveDocOutcome<Doc>("post", absentDocument);
  const misconfigured = await resolveDocOutcome<Doc>("pots", unknownType);

  // A valid type with no matching slug: absent, and that is fine.
  assert.deepEqual(absent, { doc: null, error: null });

  // An unknown type name: the operator must see it.
  assert.equal(misconfigured.doc, null);
  assert.equal(typeof misconfigured.error, "string");

  // The whole point. Two upstream 404s, two different answers — collapse them
  // and this line is the one that reds.
  assert.notDeepEqual(
    absent,
    misconfigured,
    "an absent document and an unknown TYPE must not produce the same result",
  );
});

/* ── bucket 1: absence of DATA is a normal state ─────────────────────────── */

test("a valid type with no matching slug is absent, not an error", async () => {
  const r = await resolveDocOutcome<Doc>("post", absentDocument);
  assert.equal(r.doc, null);
  assert.equal(r.error, null, "absent is not an error");
});

test("a document that resolves is returned with no error", async () => {
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
    "a 404 on the TYPE is a misconfiguration, not an absent document",
  );
});

test("the surfaced message names the type and both causes", async () => {
  const r = await resolveDocOutcome<Doc>("pots", unknownType);
  assert.equal(r.error, unknownTypeMessage("pots"));
  // An operator reading a red panel needs the offending name and where to look.
  assert.match(r.error ?? "", /"pots"/);
  assert.match(r.error ?? "", /misspelled/);
  assert.match(r.error ?? "", /token/);
});

test("classification is keyed on the code STRING, not the class", async () => {
  // A foreign realm's copy of the class — no prototype relationship at all, so
  // `instanceof` would miss it. This is why the ruling uses `isBarkparkError`.
  const foreign = Object.assign(new Error("no such type"), {
    code: "BarkparkNotFoundError",
    status: 404,
  });
  const r = await resolveDocOutcome<Doc>("pots", () => Promise.reject(foreign));
  assert.equal(r.error, unknownTypeMessage("pots"));
});

/* ── bucket 2, the other half: a real outage keeps its own message ───────── */

test("a real outage keeps its message — degrading it to a 404 would hide it", async () => {
  const r = await resolveDocOutcome<Doc>("post", () =>
    Promise.reject(new Error("upstream 503")),
  );
  assert.equal(r.doc, null);
  assert.equal(r.error, "upstream 503", "a real outage keeps its message");
  assert.notEqual(r.error, unknownTypeMessage("post"));
});

test("a non-Error throw is stringified, not swallowed", async () => {
  const r = await resolveDocOutcome<Doc>("post", () => Promise.reject("boom"));
  assert.deepEqual(r, { doc: null, error: "boom" });
});
