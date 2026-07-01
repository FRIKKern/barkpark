/**
 * lvw-t1 — the inline live-value pre-resolve pass (wire §3/§5/§9), web side.
 *
 * Driven by the SHARED golden fixtures (`fixtures/portable-doc-inline/`,
 * mirrored verbatim here, in `api/test/support/fixtures/` and in
 * `internal/pdrender/testdata/` — one JSON per case, consumed by all three
 * renderers). The web reader is server-pre-resolved: `stampResolvedValues`
 * stamps `resolved` onto valueref nodes and the component renders
 * `resolved ?? fallback` as a plain text node — so the pure helpers ARE the
 * behavior under test (collection, the scalar rule, the stamp).
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/valueref.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  collectValuerefPairs,
  stampResolvedValues,
  valuerefScalar,
  type Block,
} from "../lib/papers.ts";

interface Fixture {
  case: string;
  values?: Record<string, Record<string, unknown>>;
  block: Block;
  expect_visible: string;
  expect_absent: string;
}

function fixture(name: string): Fixture {
  const raw = readFileSync(
    join(import.meta.dirname, "fixtures", "portable-doc-inline", name),
    "utf8",
  );
  return JSON.parse(raw) as Fixture;
}

/** The component's display rule, applied over a stamped tree: text values,
 * valueref → resolved ?? fallback (children IGNORED — D6). Mirrors
 * portable-doc.tsx's valueref case so the golden text assertions hold. */
function visibleText(v: unknown): string {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v.map(visibleText).join("");
  if (v === null || typeof v !== "object") return "";
  const node = v as Record<string, unknown>;
  if (node.type === "valueref") {
    const resolved =
      typeof node.resolved === "string" && node.resolved !== ""
        ? node.resolved
        : null;
    return resolved ?? (typeof node.fallback === "string" ? node.fallback : "");
  }
  if (node.type === "text") {
    return typeof node.value === "string" ? node.value : "";
  }
  return visibleText(node.children ?? node.content ?? []);
}

for (const name of [
  "valueref-resolved.json",
  "valueref-unresolved-fallback.json",
  "valueref-missing-resolver.json",
]) {
  test(`golden: ${name}`, () => {
    const fx = fixture(name);
    // A missing `values` key = no resolver wired at all → no stamping.
    const blocks =
      fx.values !== undefined
        ? stampResolvedValues([fx.block], fx.values)
        : [fx.block];
    const text = visibleText(blocks);
    assert.equal(text, fx.expect_visible);
    assert.ok(
      !text.includes(fx.expect_absent),
      `${fx.case}: "${fx.expect_absent}" must not render`,
    );
  });
}

test("collectValuerefPairs deep-walks, dedupes, and drops wire violations", () => {
  const blocks = [
    {
      type: "paragraph",
      content: [
        { type: "valueref", target: "a", field: "f1", fallback: "x" },
        {
          type: "strong",
          children: [
            { type: "valueref", target: "a", field: "f1", fallback: "dup" },
            { type: "valueref", target: "b", field: "f2", fallback: "y" },
          ],
        },
        // Wire violations → dropped (the node then renders its fallback).
        { type: "valueref", target: "c", field: "a.b", fallback: "dot" },
        { type: "valueref", target: "c", field: "content.x", fallback: "pfx" },
        { type: "valueref", target: "", field: "f", fallback: "blank" },
        { type: "valueref", target: "d", fallback: "nofield" },
      ],
    },
  ] as Block[];

  assert.deepEqual(collectValuerefPairs(blocks), [
    { target: "a", field: "f1" },
    { target: "b", field: "f2" },
  ]);
});

test("valuerefScalar: the shared three-surface scalar rule", () => {
  assert.equal(valuerefScalar("6 weeks"), "6 weeks");
  assert.equal(valuerefScalar(42), "42");
  assert.equal(valuerefScalar(true), "true");
  // "" counts as UNRESOLVED (the Go convention) → fallback.
  assert.equal(valuerefScalar(""), null);
  assert.equal(valuerefScalar("   "), null);
  // Maps/lists/null never stringify (an encrypted _bpenc envelope degrades).
  assert.equal(valuerefScalar({ _bpenc: "…" }), null);
  assert.equal(valuerefScalar([1, 2]), null);
  assert.equal(valuerefScalar(null), null);
  assert.equal(valuerefScalar(undefined), null);
});

test("stampResolvedValues is non-mutating and leaves unresolved nodes untouched", () => {
  const blocks = [
    {
      type: "paragraph",
      content: [
        { type: "valueref", target: "a", field: "f", fallback: "fb" },
        { type: "valueref", target: "missing", field: "f", fallback: "fb2" },
      ],
    },
  ] as Block[];
  const before = JSON.stringify(blocks);

  const stamped = stampResolvedValues(blocks, { a: { f: "live" } });

  assert.equal(JSON.stringify(blocks), before, "input tree must not mutate");
  const content = stamped[0].content as Array<Record<string, unknown>>;
  assert.equal(content[0].resolved, "live");
  assert.ok(!("resolved" in content[1]), "unresolved node stays untouched");
});

test("injection stays data: a hostile value is carried verbatim as a STRING (React escapes text nodes)", () => {
  const hostile = '<script>alert(1)</script>"onmouseover="x';
  const blocks = [
    {
      type: "paragraph",
      content: [{ type: "valueref", target: "a", field: "f", fallback: "fb" }],
    },
  ] as Block[];

  const stamped = stampResolvedValues(blocks, { a: { f: hostile } });
  const content = stamped[0].content as Array<Record<string, unknown>>;
  // The value must remain a plain string on the node — the component renders
  // it as a React TEXT child (never dangerouslySetInnerHTML), so markup
  // arrives entity-escaped in the DOM.
  assert.equal(content[0].resolved, hostile);
  assert.equal(typeof content[0].resolved, "string");
});
