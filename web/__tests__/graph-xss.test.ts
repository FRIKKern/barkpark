/**
 * Regression guard for the vanilla graph widget's legend `innerHTML` sink.
 *
 * `web/public/bp-graph.js` draws a "Types" legend where each row is built with
 * `row.innerHTML = "<span style='…'></span>" + <type-name>`. The type name is a
 * document `type` string. V3 proved that string is NOT a controlled vocabulary:
 * neither `Content.Document`'s changeset nor `SchemaDefinition.name` constrains
 * its charset, and the `:scoped_mutate` pipeline accepts schemaless writes from a
 * non-admin RequireWritePermission (WRITER) token — so `type` can be
 * `"<img src=x onerror=alert(1)>"` verbatim and flow into the legend. The fix
 * (fail-closed) routes the type name through the widget's `esc()` HTML-escaper,
 * and hardens `esc()` so its character class also covers the single-quote (it
 * escaped `& < > "` but not `'`, leaving single-quoted attribute contexts open).
 *
 * This test reads the shipped source and asserts BOTH halves survive:
 *   1. the legend sink interpolates `esc(ty)`, and no bare `"</span>" + ty` remains
 *      (mutation: dropping esc(ty) reds this);
 *   2. the actual `esc()` body, reconstructed and executed, neutralizes a breakout
 *      payload — no `<img`, no raw `"`, no raw `'` survives
 *      (mutation: weakening the regex class or the map reds this).
 *
 * Run: `cd web && node --test --import ./__tests__/support/stub-server-only.mjs __tests__/graph-xss.test.ts`
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SRC = readFileSync(
  fileURLToPath(new URL("../public/bp-graph.js", import.meta.url)),
  "utf8",
);

test("legend sink interpolates esc(ty), not raw ty", () => {
  // The fixed sink is present.
  assert.ok(
    SRC.includes(`"<span style='" + swStyle + "'></span>" + esc(ty)`),
    "expected the fullColor legend row to interpolate esc(ty)",
  );
  // The unescaped form is gone — a revert to raw `+ ty` reds this.
  assert.ok(
    !/<\/span>"\s*\+\s*ty\b/.test(SRC),
    "found a bare `\"</span>\" + ty` — the type name is being injected unescaped",
  );
});

test("esc() neutralizes an HTML/attribute breakout payload", () => {
  // Reconstruct the SHIPPED esc() and exercise it, so weakening the real
  // escaper (not a copy) reds this assertion.
  const m = SRC.match(/function esc\(s\)\s*\{([\s\S]*?)\n {4}\}/);
  assert.ok(m, "could not locate the esc() function body in bp-graph.js");
  const esc = new Function("s", m![1]) as (s: string) => string;

  const payload = `"><img src=x onerror=alert(1)>`;
  const out = esc(payload);

  assert.ok(!out.includes("<img"), "unescaped <img survived esc()");
  assert.ok(!out.includes("<"), "raw < survived esc()");
  assert.ok(!out.includes(">"), "raw > survived esc()");
  assert.ok(!out.includes('"'), "raw double-quote survived esc()");
  assert.ok(!out.includes("'"), "raw single-quote survived esc()");

  // Positive: the characters are escaped to their entities.
  assert.equal(
    esc(`<>&"'`),
    "&lt;&gt;&amp;&quot;&#39;",
    "esc() must cover all five of < > & \" '",
  );
});
