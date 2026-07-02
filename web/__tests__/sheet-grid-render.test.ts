/**
 * Render tests for the web sheet grid (`components/sheet-grid.tsx`) — the two
 * snapshot features the web surface used to drop: `fmt:"checkbox"` cells
 * (raw TRUE/FALSE instead of a read-only checkbox glyph) and tab
 * `row_heights` (col_widths were applied, heights were not).
 *
 * Node's test runner strips types but cannot parse JSX, so this file
 * transpiles the component with the repo's own TypeScript compiler, rewrites
 * the `@/lib/*` alias to file URLs, imports the result, and asserts over
 * `renderToStaticMarkup` HTML — the real component render, not a re-model.
 *
 * Run: `npm test` (or `node --test __tests__/sheet-grid-render.test.ts`).
 */

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import ts from "typescript";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { SheetTab } from "../lib/sheets.ts";

/* ── load the component (tsx → mjs, alias → file URLs) ────────────────────── */

const componentsDir = fileURLToPath(new URL("../components/", import.meta.url));
const libUrl = new URL("../lib/", import.meta.url).href;

const source = readFileSync(path.join(componentsDir, "sheet-grid.tsx"), "utf8");
const transpiled = ts.transpileModule(source, {
  compilerOptions: {
    jsx: ts.JsxEmit.ReactJSX,
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: false,
  },
}).outputText;

// `@/lib/foo` → absolute file:// URL of the .ts source (node strips types).
const rewritten = transpiled.replace(
  /(["'])@\/lib\/([^"']+)\1/g,
  (_m, _q, mod: string) => JSON.stringify(`${libUrl}${mod}.ts`),
);

// The temp module must live inside web/ so `react/jsx-runtime` resolves.
const tmpPath = path.join(componentsDir, `.sheet-grid.test-${process.pid}.mjs`);
writeFileSync(tmpPath, rewritten);
after(() => {
  try {
    unlinkSync(tmpPath);
  } catch {
    /* already gone */
  }
});

const mod = await import(pathToFileURL(tmpPath).href);
const { SheetGrid } = mod as {
  SheetGrid: (props: { tabs: SheetTab[] }) => unknown;
};

function renderGrid(tabs: SheetTab[]): string {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return renderToStaticMarkup(createElement(SheetGrid as any, { tabs }));
}

/** Every `<span role="checkbox" …>…</span>` in document order. */
function checkboxSpans(html: string): string[] {
  return html.match(/<span[^>]*role="checkbox"[^>]*>[^<]*<\/span>/g) ?? [];
}

/* ── checkbox fmt ──────────────────────────────────────────────────────────── */

test("a fmt:checkbox cell renders a read-only checkbox glyph, not TRUE/FALSE", () => {
  const html = renderGrid([
    {
      name: "T",
      cells: {
        A1: { v: true, fmt: "checkbox" },
        B1: { v: false, fmt: "checkbox" },
        C1: { v: "plain" },
      },
    },
  ]);

  const boxes = checkboxSpans(html);
  assert.equal(boxes.length, 2, `expected 2 checkbox spans in: ${html}`);

  // A1: truthy → checked glyph.
  assert.match(boxes[0], /aria-checked="true"/);
  assert.match(boxes[0], />☑</);
  // B1: falsy → unchecked glyph.
  assert.match(boxes[1], /aria-checked="false"/);
  assert.match(boxes[1], />☐</);
  // Read-only affordance, and no raw boolean text leaks into the grid.
  assert.match(boxes[0], /aria-disabled="true"/);
  assert.doesNotMatch(html, />TRUE</);
  assert.doesNotMatch(html, />FALSE</);
});

test("a plain cell is unaffected: no checkbox markup, value renders verbatim", () => {
  const html = renderGrid([
    { name: "T", cells: { A1: { v: "plain" }, B1: { v: true } } },
  ]);
  assert.equal(checkboxSpans(html).length, 0);
  assert.match(html, />plain</);
  // A bare boolean WITHOUT the checkbox fmt still reads TRUE (Studio parity).
  assert.match(html, />TRUE</);
});

/* ── row heights ───────────────────────────────────────────────────────────── */

test("tab row_heights set the rendered row heights (1-based keys, like col_widths)", () => {
  const html = renderGrid([
    {
      name: "T",
      cells: { A1: { v: "a" }, A2: { v: "b" }, A3: { v: "c" } },
      row_heights: { "2": 40 },
    },
  ]);

  const sized = html.match(/<tr style="height:40px">/g) ?? [];
  assert.equal(sized.length, 1, `expected exactly one 40px row in: ${html}`);
  // The sized row is sheet row 2 — its gutter header reads "2".
  assert.match(html, /<tr style="height:40px"><th[^>]*>2</);
});

test("row_heights re-base across the frozen head band", () => {
  const html = renderGrid([
    {
      name: "T",
      cells: { A1: { v: "Head" }, A2: { v: "b" }, A3: { v: "c" } },
      frozen_rows: 1,
      row_heights: { "1": 30, "2": 40 },
    },
  ]);

  // Sheet row 1 became the head band; sheet row 2 is the first BODY row
  // (the body gutter re-numbers from 1 after the head split).
  assert.match(html, /<tr style="height:30px"><th[^>]*aria-hidden/);
  assert.match(html, /<tr style="height:40px"><th[^>]*>1</);
  assert.equal((html.match(/height:/g) ?? []).length, 2);
});

test("a tab without row_heights renders no height styles", () => {
  const html = renderGrid([
    { name: "T", cells: { A1: { v: "a" }, A2: { v: "b" } } },
  ]);
  assert.doesNotMatch(html, /height:/);
});
