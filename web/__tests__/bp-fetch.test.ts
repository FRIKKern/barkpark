/**
 * Pins the machine-readable error code on `BpUpstreamError` (task
 * wbq-web-bpfetch-error-code): the upstream envelope's `{error:{code,message}}`
 * shape carries a `code` that callers need to branch on (two different 400s
 * are not the same failure) — before this fix, `errorEnvelopeMessage` read
 * `code` only as a MESSAGE fallback and then discarded it, so the thrown
 * `BpUpstreamError` had no way to expose it. Fails before the fix: the old
 * error had no `.code` property at all.
 *
 * The first test drives the real `bpFetchJson` path end to end against a
 * throwaway local HTTP server (no mocking) so the envelope-parsing logic in
 * `attempt()` is actually exercised, not just the constructor.
 *
 * Run: `cd web && node --test __tests__/bp-fetch.test.ts`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { bpFetchJson, BpUpstreamError } from "../lib/bp-fetch.ts";

/** Starts a one-shot local server that answers every request with the given
 * status + JSON body, and returns its base URL + a stop() to tear it down. */
async function localJsonServer(
  status: number,
  body: unknown,
): Promise<{ url: string; stop: () => Promise<void> }> {
  const server: Server = createServer((_req, res) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}/`,
    stop: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("bpFetchJson: a {error:{code,message}} envelope surfaces both on the thrown error", async () => {
  const { url, stop } = await localJsonServer(400, {
    error: { code: "x", message: "y" },
  });
  try {
    await assert.rejects(
      () => bpFetchJson(url),
      (err: unknown) => {
        assert.ok(err instanceof BpUpstreamError);
        assert.equal(err.code, "x");
        assert.equal(err.message, "y");
        assert.equal(err.status, 400);
        return true;
      },
    );
  } finally {
    await stop();
  }
});

test("bpFetchJson: a bodyless/HTML 5xx (no envelope) leaves code undefined", async () => {
  const server = createServer((_req, res) => {
    res.writeHead(502, { "content-type": "text/html" });
    res.end("<html>bad gateway</html>");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await assert.rejects(
      () => bpFetchJson(`http://127.0.0.1:${port}/`, {}),
      (err: unknown) => {
        assert.ok(err instanceof BpUpstreamError);
        assert.equal(err.code, undefined);
        return true;
      },
    );
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("BpUpstreamError: constructor carries both code and message directly", () => {
  const err = new BpUpstreamError(400, "y", "", true, "x");
  assert.equal(err.code, "x");
  assert.equal(err.message, "y");
});

test("BpUpstreamError: code is optional and defaults to undefined", () => {
  const err = new BpUpstreamError(0, "network error");
  assert.equal(err.code, undefined);
  assert.equal(err.message, "network error");
});
