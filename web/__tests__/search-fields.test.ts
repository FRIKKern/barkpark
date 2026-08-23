/**
 * Tests for the SHARED column projection (`lib/search-fields.ts`) that both
 * finder transports now send.
 *
 * THE DEFECT. `find-search.ts` sent `?fields=` on the HTTP path — cutting the
 * browse payload ~2.7MB→732KB on the demo corpus — while `use-live-search.ts`
 * pushed `{q, engine, types, limit, seq}` on the channel with NO `fields` key.
 * `SearchChannel.build_reply/8` (api/lib/barkpark_web/channels/search_channel.ex
 * :189-200) therefore handed `nil` into `HitEnvelope.build(..., fields: fields)`
 * and every live keystroke came back as FULL documents. The projection could
 * not be shared because it was a private const inside a `server-only` module
 * and the hook is `"use client"` — the module boundary WAS the bug.
 *
 * The extracted `templates/search-starter` fork caught this live and records
 * the measurement: 9-15MB per frame on a papers corpus, the browser frozen for
 * seconds per keystroke. `web/` is the origin it was extracted from.
 *
 * NAMED MUTANTS each test kills:
 *   • unwire-the-channel        → the SHIPPED use-live-search test reds
 *   • unwire-the-http-path      → the SHIPPED find-search test reds
 *   • two-lists-again           → the one-source test reds
 *   • drop-a-field-the-shaper-reads → the coverage test reds, naming the field
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  SEARCH_FIELDS,
  SEARCH_FIELD_LIST,
  ALWAYS_PRESENT_META,
} from "../lib/search-fields.ts";

const shipped = (rel: string) =>
  readFileSync(fileURLToPath(new URL(`../${rel}`, import.meta.url)), "utf8");

/* ── the list itself ────────────────────────────────────────────────────── */

test("the wire form is the list, comma-joined, with no spaces", () => {
  assert.equal(SEARCH_FIELDS, SEARCH_FIELD_LIST.join(","));
  assert.ok(!/\s/.test(SEARCH_FIELDS), "a space would corrupt the allowlist");
  assert.equal(new Set(SEARCH_FIELD_LIST).size, SEARCH_FIELD_LIST.length);
});

test("blocks is requested — dropping it silently kills contextual snippets", () => {
  // deriveTitle / deriveExcerpt / deriveBody all walk the block tree. The
  // search-starter fork deliberately drops `blocks` on its channel to hit a
  // 40ms goal, accepting degraded snippets; that is a ratified tradeoff for a
  // DIFFERENT surface, and adopting it here would change what this reader shows.
  assert.ok(SEARCH_FIELD_LIST.includes("blocks"));
});

/* ── coverage: the shaper must not read a field nobody asked for ────────── */

test("every document field normalizeHit reads is requested (or always rides along)", () => {
  // Derived from the SHIPPED shaper rather than restated, so adding a
  // `doc.newField` read without extending the projection reds here instead of
  // silently returning undefined at runtime.
  const src = shipped("lib/find.ts");
  const read = new Set<string>();
  for (const m of src.matchAll(/\bdoc\.([A-Za-z_][A-Za-z0-9_]*)/g)) read.add(m[1]);
  for (const m of src.matchAll(/\bcontent\.([A-Za-z_][A-Za-z0-9_]*)/g)) read.add(m[1]);

  const requested = new Set<string>([
    ...SEARCH_FIELD_LIST,
    ...ALWAYS_PRESENT_META,
    // `Envelope.render` spreads `content` to the top level, so the nested
    // lookups above are a defensive fallback on a key the server never emits.
    "content",
  ]);

  const missing = [...read].filter((f) => !requested.has(f));
  assert.deepEqual(
    missing,
    [],
    `normalizeHit reads ${missing.join(", ")} but the projection never asks for it`,
  );
});

test("the projection has no field the shaper never reads", () => {
  // The other direction: a stale entry costs payload on every keystroke.
  const src = shipped("lib/find.ts");
  const unread = SEARCH_FIELD_LIST.filter(
    (f) => !new RegExp(`\\b(doc|content)\\.${f}\\b`).test(src),
  );
  assert.deepEqual(unread, [], `requested but never read: ${unread.join(", ")}`);
});

/* ── shipped wiring: BOTH transports ────────────────────────────────────── */

test("SHIPPED (lib/find-search.ts): the HTTP path sends the shared projection", () => {
  const src = shipped("lib/find-search.ts");
  assert.match(src, /from "@\/lib\/search-fields"/);
  assert.match(src, /fields:\s*SEARCH_FIELDS,/);
  assert.ok(
    !/const SEARCH_FIELDS\s*=/.test(src),
    "the private copy must be gone — two lists is how they drift apart",
  );
});

test("SHIPPED (lib/use-live-search.ts): the CHANNEL sends the shared projection", () => {
  // This is the whole fix. Without it the socket reply is full documents.
  const src = shipped("lib/use-live-search.ts");
  assert.match(src, /from "@\/lib\/search-fields"/);
  assert.match(
    src,
    /\.push\("query",\s*\{[\s\S]*?fields:\s*SEARCH_FIELDS,[\s\S]*?\}\)/,
    "the `query` push must carry fields",
  );
});

test("SHIPPED: both transports name the SAME identifier — one source, not two", () => {
  for (const rel of ["lib/find-search.ts", "lib/use-live-search.ts"]) {
    const src = shipped(rel);
    assert.match(
      src,
      /import \{ SEARCH_FIELDS \} from "@\/lib\/search-fields";/,
      `${rel} must import the one list, not restate it`,
    );
  }
});
