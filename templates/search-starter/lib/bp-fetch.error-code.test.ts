import assert from "node:assert/strict";
import { register } from "node:module";
import { test } from "node:test";

// bp-fetch.ts is a server module (`server-only` + `undici`). These hooks make it
// importable in the dependency-free CI job; everything else in it runs for real.
register(new URL("./__test-stub-hooks.mjs", import.meta.url));

const { setFetch } = await import("./__test-stub-undici.mjs");
const { BpUpstreamError, bpFetchJson } = await import("./bp-fetch.ts");

/**
 * These tests pin the MACHINE-READABLE half of an upstream failure.
 *
 * The API deliberately emits distinct codes so a client can branch on the
 * FAILURE, not on prose: `storage_unavailable`, `runtime_unavailable`,
 * `runtime_capacity`, `import_failed`, `export_failed` are registered in the
 * API's `@public_inline_codes` precisely because clients are expected to read
 * them. A client that only has `status` + `message` can tell a retryable
 * capacity shed from a permanent defect only by string-matching a human
 * sentence — which is the thing the code field exists to prevent.
 *
 * This file exists because the fork of `bp-fetch.ts` shipped for weeks with a
 * `code` that was consumed as DISPLAY TEXT and then discarded: the envelope
 * decoder returned the code only as a MESSAGE FALLBACK, so an envelope carrying
 * BOTH a message and a code surfaced the message and lost the code entirely.
 * The first test below is exactly that shape, and it is the one that fails
 * against a naive port.
 */

/** One non-OK response with the given JSON body. */
function respondWith(status: number, body: string, headers: [string, string][] = []) {
  setFetch(async () => ({
    ok: false,
    status,
    headers: new Headers(headers),
    text: async () => body,
  }));
}

test("an envelope carrying BOTH a message and a code keeps the code on the thrown error", async () => {
  // The load-bearing case: a human message is present, so the old
  // message-fallback path never even looked at `code`.
  respondWith(
    503,
    JSON.stringify({
      error: { message: "search runtime is at capacity", code: "runtime_capacity" },
    }),
  );

  const err = await bpFetchJson("http://example.invalid/v1/search").then(
    () => null,
    (e: unknown) => e,
  );

  assert.ok(err instanceof BpUpstreamError, "expected a BpUpstreamError");
  // The message half is UNCHANGED — the code is an addition, not a replacement.
  assert.equal(err.message, "search runtime is at capacity");
  assert.equal(err.status, 503);
  assert.equal(err.definitive, true);
  // The half this test exists for: a caller can branch on the code without
  // string-matching the sentence above.
  assert.equal(err.code, "runtime_capacity");
});

test("a code-only envelope still doubles as the message, and still exposes the code", async () => {
  // The pre-existing fallback must SURVIVE: with no human message the code is
  // the best display string there is. It must now ALSO be readable as a code.
  respondWith(500, JSON.stringify({ error: { code: "storage_unavailable" } }));

  const err = (await bpFetchJson("http://example.invalid/v1/search").catch(
    (e: unknown) => e,
  )) as InstanceType<typeof BpUpstreamError>;

  assert.equal(err.message, "storage_unavailable");
  assert.equal(err.code, "storage_unavailable");
});

test("a message-only envelope leaves the code undefined, not empty-string", async () => {
  respondWith(422, JSON.stringify({ error: { message: "reindex failed" } }));

  const err = (await bpFetchJson("http://example.invalid/v1/search").catch(
    (e: unknown) => e,
  )) as InstanceType<typeof BpUpstreamError>;

  assert.equal(err.message, "reindex failed");
  assert.equal(err.code, undefined);
});

test("an infra blip that never reached an envelope carries no code", async () => {
  // A bodyless/HTML 5xx is not a structured answer — there is no code to lift,
  // and inventing one would let a caller branch on a guess. 401 so the retry
  // ladder does not sleep through the two transient backoffs.
  respondWith(401, "<html>502 Bad Gateway</html>");

  const err = (await bpFetchJson("http://example.invalid/v1/search").catch(
    (e: unknown) => e,
  )) as InstanceType<typeof BpUpstreamError>;

  assert.equal(err.code, undefined);
  assert.equal(err.definitive, false);
  assert.equal(err.message, "upstream 401");
});

test("the code rides alongside Retry-After — neither argument shadows the other", async () => {
  // Both optional constructor tails are populated on the same throw. This is
  // the regression a positional-argument port gets wrong: web/lib/bp-fetch.ts
  // orders them (…, definitive, code, retryAfterMs), and a fork that inserts
  // `code` without moving `retryAfterMs` silently reads the ms as the code.
  respondWith(
    429,
    JSON.stringify({ error: { message: "too many requests", code: "runtime_capacity" } }),
    [["retry-after", "12"]],
  );

  const err = (await bpFetchJson("http://example.invalid/v1/search").catch(
    (e: unknown) => e,
  )) as InstanceType<typeof BpUpstreamError>;

  assert.equal(err.code, "runtime_capacity");
  assert.equal(err.retryAfterMs, 12_000);
});
