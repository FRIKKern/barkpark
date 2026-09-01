/**
 * `detailHref` (components/listings-map.tsx) is the map popover's
 * "Website ↗" target. Its input is `l.url` — CMS-authored listing content,
 * therefore caller-controlled — and its output is spliced straight into an
 * `<a href>`. It was the ONE `<a href>` in web/ that skipped the scheme
 * allow-list every other href goes through (`sheet-grid.tsx:282` already
 * routes the same class of value through `safeHref`).
 *
 * These cases pin that it now agrees with `safeHref`: a `javascript:` /
 * `data:` scheme and a protocol-relative host are dropped (no anchor is
 * rendered at all), while ordinary http(s) URLs still pass through unchanged
 * — a fix that broke real listing links would be no fix.
 *
 * The component is a "use client" module with JSX, which `node --test` cannot
 * parse, so it is transpiled with the repo's own TypeScript compiler and its
 * `@/lib/*` aliases rewritten to file URLs — the same loader
 * `sheet-grid-render.test.ts` uses. That means these assertions run the REAL
 * shipped function, not a re-model of it.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/listings-map-href.test.ts`).
 */

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import ts from "typescript";
import type { Listing } from "../lib/listings-data.ts";

/* ── load the component (tsx → mjs, alias → file URLs) ────────────────────── */

const componentsDir = fileURLToPath(new URL("../components/", import.meta.url));
const libUrl = new URL("../lib/", import.meta.url).href;

const source = readFileSync(path.join(componentsDir, "listings-map.tsx"), "utf8");
const transpiled = ts.transpileModule(source, {
  compilerOptions: {
    jsx: ts.JsxEmit.ReactJSX,
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: false,
  },
}).outputText;

const rewritten = transpiled.replace(
  /(["'])@\/lib\/([^"']+)\1/g,
  (_m, _q, mod: string) => JSON.stringify(`${libUrl}${mod}.ts`),
);

const tmpPath = path.join(componentsDir, `.listings-map.test-${process.pid}.mjs`);
writeFileSync(tmpPath, rewritten);
after(() => {
  try {
    unlinkSync(tmpPath);
  } catch {
    /* already gone */
  }
});

const mod = (await import(pathToFileURL(tmpPath).href)) as {
  detailHref?: (l: Listing) => string | null;
};

/** Subject presence: a pass must not be reachable by the function vanishing. */
test("detailHref is exported by listings-map and is the popover's href source", () => {
  assert.equal(
    typeof mod.detailHref,
    "function",
    "listings-map.tsx must export detailHref — the popover anchor reads it",
  );
  // …and the anchor really is wired to it, so this file guards the live sink.
  assert.match(
    source,
    /href=\{detailHref\(selected\.listing\)!\}/,
    "the popover <a href> must still be fed by detailHref",
  );
});

const detailHref = (l: Partial<Listing>): string | null =>
  mod.detailHref!(l as Listing);

const listing = (url: unknown): Partial<Listing> =>
  ({ id: "l1", name: "L", lat: 0, lng: 0, url }) as Partial<Listing>;

/* ── the defect ────────────────────────────────────────────────────────────── */

test("a javascript: listing url never reaches the popover anchor", () => {
  assert.equal(detailHref(listing("javascript:alert(document.cookie)")), null);
  assert.equal(detailHref(listing("JavaScript:alert(1)")), null);
  assert.equal(detailHref(listing("  javascript:alert(1)  ")), null);
});

test("a data: listing url never reaches the popover anchor", () => {
  assert.equal(
    detailHref(listing("data:text/html,<script>alert(1)</script>")),
    null,
  );
});

test("a protocol-relative listing url never reaches the popover anchor", () => {
  const base = "https://demo.barkpark.cloud/finder";
  for (const raw of [
    "//evil.example/phish",
    "/\\evil.example/phish",
    "/\t/evil.example/phish",
    "/\n/evil.example/phish",
  ]) {
    const href = detailHref(listing(raw));
    assert.equal(
      href,
      null,
      `detailHref(${JSON.stringify(raw)}) rendered an anchor to ` +
        `${href === null ? "(none)" : new URL(href, base).href}`,
    );
  }
});

/* ── the affordance still works ────────────────────────────────────────────── */

test("ordinary listing URLs still render their anchor unchanged", () => {
  assert.equal(
    detailHref(listing("https://hundesteder.no/parks/frogner")),
    "https://hundesteder.no/parks/frogner",
  );
  assert.equal(detailHref(listing("http://example.com/a?b=1")), "http://example.com/a?b=1");
});

test("an absent or non-string url yields no anchor", () => {
  assert.equal(detailHref(listing(undefined)), null);
  assert.equal(detailHref(listing("")), null);
  // A bare string is truthy AND iterable; a non-string must not slip through
  // whatever shape-branching the guard does.
  assert.equal(detailHref(listing(42)), null);
  assert.equal(detailHref(listing(["javascript:alert(1)"])), null);
  assert.equal(detailHref(listing({ toString: () => "javascript:alert(1)" })), null);
});
