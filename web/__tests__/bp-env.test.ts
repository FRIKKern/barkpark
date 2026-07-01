/**
 * Pins the env-var name unification (task dwb-3): the demo reads the CANONICAL
 * names first and falls back to the pre-unification names, so an already-deployed
 * Vercel project (whose env still carries the old names) keeps working after the
 * rename. These cases guard the fallback precedence in `lib/bp-env.ts`.
 *
 * Run: `cd web && node --test __tests__/bp-env.test.ts`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  resolveApiUrl,
  resolveReadToken,
  DEFAULT_API_URL,
} from "../lib/bp-env.ts";

test("API URL: canonical NEXT_PUBLIC_BARKPARK_API_URL wins", () => {
  assert.equal(
    resolveApiUrl({
      NEXT_PUBLIC_BARKPARK_API_URL: "https://new.example",
      NEXT_PUBLIC_API_URL: "https://old.example",
    }),
    "https://new.example",
  );
});

test("API URL: falls back to legacy NEXT_PUBLIC_API_URL when canonical absent", () => {
  assert.equal(
    resolveApiUrl({ NEXT_PUBLIC_API_URL: "https://old.example" }),
    "https://old.example",
  );
});

test("API URL: defaults to localhost when neither name is set", () => {
  assert.equal(resolveApiUrl({}), DEFAULT_API_URL);
});

test("read token: canonical BARKPARK_TOKEN wins", () => {
  assert.equal(
    resolveReadToken({ BARKPARK_TOKEN: "new-tok", BARKPARK_READ_TOKEN: "old-tok" }),
    "new-tok",
  );
});

test("read token: falls back to legacy BARKPARK_READ_TOKEN when canonical absent", () => {
  assert.equal(
    resolveReadToken({ BARKPARK_READ_TOKEN: "old-tok" }),
    "old-tok",
  );
});

test("read token: undefined (anonymous) when neither name is set", () => {
  assert.equal(resolveReadToken({}), undefined);
});
