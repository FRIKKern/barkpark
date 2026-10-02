/**
 * r4a: `/api/barkpark/webhook` read the whole request body (`req.text()`)
 * BEFORE it could check the HMAC — only the unsigned timestamp's freshness is
 * checked first — so any sender could make the route buffer an arbitrarily
 * large body. The route now reads through `readBodyCapped` and answers 413
 * past `WEBHOOK_MAX_BODY_BYTES`. The helper is exercised here, and the route is
 * pinned to use it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { WEBHOOK_MAX_BODY_BYTES, readBodyCapped } from "../lib/read-body-capped.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROUTE = path.resolve(HERE, "..", "app", "api", "barkpark", "webhook", "route.ts");

function streamOf(bytes: number, chunk = 64 * 1024) {
  let sent = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (sent >= bytes) {
        ctrl.close();
        return;
      }
      const n = Math.min(chunk, bytes - sent);
      sent += n;
      ctrl.enqueue(new Uint8Array(n).fill(0x61));
    },
  });
  return { body, pulled: () => sent };
}

test("a body under the cap is returned intact", async () => {
  const req = new Request("https://x.test/", { method: "POST", body: '{"a":"é"}' });
  assert.equal(await readBodyCapped(req, 1024), '{"a":"é"}');
});

test("a declared Content-Length over the cap is refused before reading", async () => {
  const req = new Request("https://x.test/", {
    method: "POST",
    headers: { "content-length": "4096" },
    body: "a".repeat(4096),
  });
  assert.equal(await readBodyCapped(req, 1024), null);
});

test("an undeclared streamed body stops being read at the cap", async () => {
  const { body, pulled } = streamOf(64 * 1024 * 1024);
  const req = new Request("https://x.test/", {
    method: "POST",
    body,
    duplex: "half",
  } as RequestInit);
  assert.equal(await readBodyCapped(req, 256 * 1024), null);
  assert.ok(pulled() < 2 * 1024 * 1024, `pulled ${pulled()} bytes of 64 MiB`);
});

test("the cap is a generous 4 MiB", () => {
  assert.equal(WEBHOOK_MAX_BODY_BYTES, 4 * 1024 * 1024);
});

test("the webhook route reads through the cap and answers 413, never a bare req.text()", () => {
  const src = readFileSync(ROUTE, "utf8");
  assert.ok(src.includes("readBodyCapped(req, WEBHOOK_MAX_BODY_BYTES)"));
  assert.ok(src.includes("status: 413"));
  assert.ok(!src.includes("await req.text()"), "the uncapped read is gone");
});
