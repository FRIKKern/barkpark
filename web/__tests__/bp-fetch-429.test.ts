/**
 * A 429 IS A THROTTLE, NOT A VERDICT — the SSR reader's side of it.
 *
 * The failure this pins: `bpFetchJson` mapped every 429 to a hard
 * `BpUpstreamError`, so a one-second hold on the shared token bucket painted a
 * blank search page. The bucket is ONE bucket for the whole fleet, so a 429 is
 * an ordinary event under load.
 *
 * WHY THE OBVIOUS FIX WOULD NOT HAVE WORKED, and why this file tests behaviour
 * rather than set membership: Barkpark's limiters answer with a parseable
 * `{error:{code:"rate_limited",details:{retry_after}}}` envelope, which
 * `errorEnvelope` marks `definitive` — and `isTransient` bailed on `definitive`
 * BEFORE it ever consulted `TRANSIENT_STATUS`. Adding 429 to that set alone
 * changes nothing; the ORDER of the two checks is the fix.
 *
 * Both directions are proved in this one run, because a retry-everything fix
 * passes the first arm and breaks the second:
 *   - a 429 carrying `retry_after` is retried, waits as long as the SERVER
 *     asked (longer than the hardcoded first rung), and then succeeds;
 *   - a 403 is still hard and is requested exactly ONCE.
 * Plus the bound: advice that does not fit the sleep budget is refused
 * outright, and a limiter that never clears cannot outlast the attempt cap.
 *
 * Run: `cd web && node --test __tests__/bp-fetch-429.test.ts`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { bpFetchJson, BpUpstreamError } from "../lib/bp-fetch.ts";

/** The real limiter envelope: `retry_after` in SECONDS inside `details`, plus
 * the `retry-after` header — both carriers, exactly as
 * `api/lib/barkpark_web/plugs/rate_limit.ex` emits them. */
function rateLimitBody(retryAfterSeconds: number): string {
  return JSON.stringify({
    error: {
      code: "rate_limited",
      message: "too many requests",
      details: { retry_after: retryAfterSeconds },
    },
  });
}

/**
 * A server that answers 429 for its first `throttled` requests and 200 after,
 * counting every request it saw. `throttled: Infinity` never clears.
 */
async function throttlingServer(opts: {
  throttled: number;
  retryAfterSeconds: number;
  sendHeader?: boolean;
}): Promise<{ url: string; calls: () => number; stop: () => Promise<void> }> {
  let calls = 0;
  const server: Server = createServer((_req, res) => {
    calls += 1;
    if (calls <= opts.throttled) {
      const headers: Record<string, string> = {
        "content-type": "application/json",
      };
      if (opts.sendHeader !== false) {
        headers["retry-after"] = String(opts.retryAfterSeconds);
      }
      res.writeHead(429, headers);
      res.end(rateLimitBody(opts.retryAfterSeconds));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"ok":true}');
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}/v1/search`,
    calls: () => calls,
    stop: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("ARM 1: a 429 carrying retry_after is retried and succeeds, waiting as long as the SERVER asked", async () => {
  // 2s of advice against a 1s first rung: a build that ignored the advice and
  // took its own ladder would come back at ~1s, so the elapsed assertion is
  // what separates "honours retry_after" from "happens to retry".
  const srv = await throttlingServer({ throttled: 1, retryAfterSeconds: 2 });
  const startedAt = Date.now();
  try {
    const body = await bpFetchJson(srv.url);
    const elapsed = Date.now() - startedAt;
    assert.deepEqual(body, { ok: true });
    assert.equal(srv.calls(), 2, "expected exactly one retry after the throttle");
    assert.ok(
      elapsed >= 1_900,
      `expected to honour the server's 2s hold, waited only ${elapsed}ms — that is the hardcoded 1s rung`,
    );
  } finally {
    await srv.stop();
  }
});

test("ARM 1b: the hold is read from the BODY when a proxy strips the header", async () => {
  const srv = await throttlingServer({
    throttled: 1,
    retryAfterSeconds: 2,
    sendHeader: false,
  });
  const startedAt = Date.now();
  try {
    const body = await bpFetchJson(srv.url);
    const elapsed = Date.now() - startedAt;
    assert.deepEqual(body, { ok: true });
    assert.ok(
      elapsed >= 1_900,
      `details.retry_after was ignored: waited ${elapsed}ms, expected the 2s the body named`,
    );
  } finally {
    await srv.stop();
  }
});

test("ARM 2: a 403 is still a HARD error and is requested exactly ONCE", async () => {
  // The arm a naive retry-everything fix breaks. A forbidden answer does not
  // become allowed by waiting, so retrying it only burns the render's deadline.
  let calls = 0;
  const server = createServer((_req, res) => {
    calls += 1;
    res.writeHead(403, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { code: "forbidden", message: "nope" } }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await assert.rejects(
      () => bpFetchJson(`http://127.0.0.1:${port}/v1/search`),
      (err: unknown) => {
        assert.ok(err instanceof BpUpstreamError);
        assert.equal(err.status, 403);
        assert.equal(err.code, "forbidden");
        return true;
      },
    );
    assert.equal(calls, 1, `a 403 must not be retried, but it was requested ${calls} times`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("ARM 2b: an ENVELOPED 500 is hard too — the hard arm is about the ANSWER, not the digit", async () => {
  // Kept next to ARM 2 so the distinction cannot rot into "5xx retries, 4xx
  // does not": what makes an answer hard is that it is a deliberate verdict,
  // and a 500 that arrives with a real `{error:…}` envelope is one. Only the
  // 429 crosses that line, and only because waiting is what clears it.
  let calls = 0;
  const server = createServer((_req, res) => {
    calls += 1;
    res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { code: "internal_error", message: "boom" } }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await assert.rejects(() => bpFetchJson(`http://127.0.0.1:${port}/v1/search`));
    assert.equal(calls, 1, `an enveloped 500 is definitive; requested ${calls} times`);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("BOUND 1: advice that does not fit the sleep budget is REFUSED, not truncated", async () => {
  // `retry-after: 30` clamps to MAX_RETRY_AFTER_MS (20s), which does not fit a
  // 5s budget. A truncated wait would land back inside the hold the server just
  // named — so the call gives up NOW, after one attempt, and fast.
  const srv = await throttlingServer({ throttled: Infinity, retryAfterSeconds: 30 });
  const startedAt = Date.now();
  try {
    await assert.rejects(
      () => bpFetchJson(srv.url, undefined, 5_000),
      (err: unknown) => {
        assert.ok(err instanceof BpUpstreamError);
        assert.equal(err.status, 429);
        return true;
      },
    );
    const elapsed = Date.now() - startedAt;
    assert.equal(srv.calls(), 1, "an unaffordable wait must not be taken at all");
    assert.ok(elapsed < 2_000, `expected an immediate refusal, took ${elapsed}ms`);
  } finally {
    await srv.stop();
  }
});

test("BOUND 2: a limiter that never clears cannot hang the caller — the attempt cap ends it", async () => {
  // retry_after: 0 is the cheapest way to reach the cap: the ladder's own
  // 1s + 2s rungs still apply (retryDelayMs takes the LONGER of the two), so
  // the call ends after 3 attempts and ~3s rather than looping.
  const srv = await throttlingServer({ throttled: Infinity, retryAfterSeconds: 0 });
  try {
    await assert.rejects(
      () => bpFetchJson(srv.url),
      (err: unknown) => err instanceof BpUpstreamError && err.status === 429,
    );
    assert.equal(srv.calls(), 3, `expected RETRIES(2) + 1 attempts, saw ${srv.calls()}`);
  } finally {
    await srv.stop();
  }
});
