/**
 * task-0cf611238d4ad597 JQ5 (owner ruling #36): `NEXT_PUBLIC_BARKPARK_WS_TOKEN`
 * is inlined into the browser bundle, and the demo sets it by hand. The build
 * now bakes it only when the API says it is a public-read token
 * (`GET /v1/capabilities?token=1` → `auth_tier: "read"`, `token.public_read:
 * true`). Every other answer drops it, so an admin or private read token
 * never reaches a visitor.
 *
 * Run: `cd web && node --test __tests__/ws-token-guard.test.ts`.
 */

import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import config, { verifyPublicReadWsToken } from "../next.config.ts";

const ORIGIN = "https://api.example.test";
const TOKEN = "bp_web_ws_token";

type Answer = { auth_tier?: string; token?: { public_read?: boolean } };

/** A fetch that answers /v1/capabilities?token=1 with `body`. */
function answering(body: Answer, init: { ok?: boolean; status?: number } = {}) {
  const calls: string[] = [];
  const impl = (async (url: string | URL, opts?: RequestInit) => {
    calls.push(String(url));
    assert.equal(
      (opts?.headers as Record<string, string>).authorization,
      `Bearer ${TOKEN}`,
    );
    return {
      ok: init.ok ?? true,
      status: init.status ?? 200,
      json: async () => body,
    } as Response;
  }) as typeof fetch;
  return { impl, calls };
}

test("a public-read token is baked", async () => {
  const { impl, calls } = answering({ auth_tier: "read", token: { public_read: true } });
  const out = await verifyPublicReadWsToken(TOKEN, ORIGIN + "/", impl);
  assert.deepEqual(out, { token: TOKEN, note: "" });
  assert.deepEqual(calls, [`${ORIGIN}/v1/capabilities?token=1`]);
});

test("an admin token is dropped", async () => {
  const { impl } = answering({ auth_tier: "admin", token: { public_read: false } });
  const out = await verifyPublicReadWsToken(TOKEN, ORIGIN, impl);
  assert.equal(out.token, "");
  assert.match(out.note, /"admin" token/);
});

test("a write token is dropped", async () => {
  const { impl } = answering({ auth_tier: "write", token: { public_read: false } });
  assert.equal((await verifyPublicReadWsToken(TOKEN, ORIGIN, impl)).token, "");
});

test("a PRIVATE read token (token.public_read false) is dropped", async () => {
  const { impl } = answering({ auth_tier: "read", token: { public_read: false } });
  const out = await verifyPublicReadWsToken(TOKEN, ORIGIN, impl);
  assert.equal(out.token, "");
  assert.match(out.note, /private read token/);
});

test("a read token from a server that cannot classify it is dropped", async () => {
  const { impl } = answering({ auth_tier: "read" });
  const out = await verifyPublicReadWsToken(TOKEN, ORIGIN, impl);
  assert.equal(out.token, "");
  assert.match(out.note, /public-read/);
});

test("a token that does not authenticate is dropped", async () => {
  const { impl } = answering({ auth_tier: "none" });
  const out = await verifyPublicReadWsToken(TOKEN, ORIGIN, impl);
  assert.equal(out.token, "");
  assert.match(out.note, /does not authenticate/);
});

test("a non-2xx or unreachable API drops the token", async () => {
  const { impl } = answering({ auth_tier: "read", token: { public_read: true } }, {
    ok: false,
    status: 503,
  });
  assert.match((await verifyPublicReadWsToken(TOKEN, ORIGIN, impl)).note, /503/);

  const down = (async () => {
    throw Object.assign(new Error("connect ECONNREFUSED"), { name: "TypeError" });
  }) as typeof fetch;
  const out = await verifyPublicReadWsToken(TOKEN, ORIGIN, down);
  assert.equal(out.token, "");
  assert.match(out.note, /unreachable/);
});

test("an unset token is a no-op and calls nothing", async () => {
  const never = (async () => assert.fail("must not call the API")) as typeof fetch;
  assert.deepEqual(await verifyPublicReadWsToken(undefined, ORIGIN, never), {
    token: "",
    note: "",
  });
  assert.deepEqual(await verifyPublicReadWsToken("  ", ORIGIN, never), {
    token: "",
    note: "",
  });
});

// ── The config factory bakes the VERIFIED value, not the raw env ─────────────

const saved = { ...process.env };
const realFetch = globalThis.fetch;
const realWarn = console.warn;
afterEach(() => {
  process.env = { ...saved };
  globalThis.fetch = realFetch;
  console.warn = realWarn;
});

test("the config factory bakes an admin token as EMPTY and warns", async () => {
  process.env.NEXT_PUBLIC_BARKPARK_API_URL = ORIGIN;
  process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN = TOKEN;
  globalThis.fetch = answering({ auth_tier: "admin" }).impl;
  const warned: string[] = [];
  console.warn = (msg: string) => void warned.push(msg);

  const built = await config();
  assert.equal(built.env?.NEXT_PUBLIC_BARKPARK_WS_TOKEN, "");
  assert.equal(process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN, "");
  assert.equal(warned.length, 1);
  assert.match(warned[0], /not baked/);
  // The rest of the config survives the wrap.
  assert.equal(typeof built.redirects, "function");
});

test("the config factory bakes a public-read token unchanged", async () => {
  process.env.NEXT_PUBLIC_BARKPARK_API_URL = ORIGIN;
  process.env.NEXT_PUBLIC_BARKPARK_WS_TOKEN = TOKEN;
  globalThis.fetch = answering({ auth_tier: "read", token: { public_read: true } }).impl;

  const built = await config();
  assert.equal(built.env?.NEXT_PUBLIC_BARKPARK_WS_TOKEN, TOKEN);
});

test("the client hook still reads the env name the config bakes", () => {
  const hook = readFileSync(
    fileURLToPath(new URL("../lib/use-live-search.ts", import.meta.url)),
    "utf8",
  );
  assert.match(hook, /process\.env\.NEXT_PUBLIC_BARKPARK_WS_TOKEN/);
});
