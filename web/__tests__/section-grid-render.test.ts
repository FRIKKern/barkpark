/**
 * Render test for the `section` grid leg (composition-doctrine cd-11), now on
 * the CANONICAL renderer (`@barkpark/react`, W5 fork-retirement).
 *
 * A grid section (`layout.mode === "grid"`, per-child span/order) must render a
 * real adaptive grid — the same `.bp-section__grid` DOM the Elixir reader and Go
 * TUI produce, never a single-column stack. This suite drives the REAL canonical
 * `renderPortableDocument([block])` string emitter (no browser, no bundler, no
 * JSX transpile) and asserts the `bp-*` grid markup the reader's stylesheet skins.
 *
 * Cross-surface faithfulness (charter D-W3-2/3/4): span is UNCLAMPED to match the
 * Elixir reader; order honors negatives (the fixture carries an `order:-1` child);
 * the grid-template declaration lives ONLY in `paper-surface.css`, never inline,
 * so the 720px collapse MQ can override for free (the two removed asserts below
 * used to check that inlined rule — it now ships in the stylesheet, not the DOM).
 *
 * Run: `pnpm test` (or `node --test __tests__/section-grid-render.test.ts`).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { renderPortableDocument, type Block } from "@barkpark/react";

// The single canonical PortableDoc surface that now serves web + starters. Its
// `renderPortableDocument([block])` emits the same `bp-*` article markup Phoenix
// and the Go TUI render, so the section grid legs assert that DOM directly.
function renderHtml(input: Record<string, unknown>): string {
  return renderPortableDocument([input as Block]);
}

function present(html: string, needle: string, label: string): void {
  assert.ok(
    html.includes(needle),
    `${label}: rendered HTML is missing ${JSON.stringify(needle)}\n---\n${html}`,
  );
}

function absent(html: string, needle: string, label: string): void {
  assert.ok(
    !html.includes(needle),
    `${label}: rendered HTML unexpectedly contains ${JSON.stringify(needle)}\n---\n${html}`,
  );
}

/** A 3-track grid section with span + order children, incl. an order:-1 child
 * (charter D-W3-3: negatives are honored identically on every surface). Every
 * span is ≤ tracks so unclamped-web == clamped-Go. */
function gridSection(): Record<string, unknown> {
  return {
    type: "section",
    title: "Grid section",
    layout: { mode: "grid", tracks: 3, gap: "md" },
    blocks: [
      { type: "paragraph", span: 2, order: 1, content: [{ type: "text", value: "wide-first" }] },
      { type: "paragraph", order: -1, content: [{ type: "text", value: "hoisted" }] },
      { type: "paragraph", content: [{ type: "text", value: "bare-cell" }] },
    ],
  };
}

test("a grid section renders a real .bp-section__grid with the structural track count", () => {
  const html = renderHtml(gridSection());
  present(html, 'class="bp-section__grid"', "grid class");
  present(html, "--bp-tracks:3", "track count custom prop");
  present(html, "--bp-grid-gap:var(--bp-space-md,1.6rem)", "gap token var (md)");
});

test("each child rides a .bp-section__cell wrapper carrying present-only span/order", () => {
  const html = renderHtml(gridSection());
  // span:2, order:1 → both, span first (byte order mirrors the reader).
  present(html, "grid-column:span 2", "unclamped span (2 ≤ tracks)");
  present(html, "order:1", "positive order");
  // order:-1 with no span → order only, negative honored.
  present(html, "order:-1", "negative order honored");
  // bare cell (no span/order) → a plain wrapper with no inline layout style.
  present(html, 'class="bp-section__cell"', "cell wrapper class");
});

test("the grid-template declaration is never inline (so the 720px collapse is free)", () => {
  const html = renderHtml(gridSection());
  // The `repeat()` grid-template + the 720px collapse MQ ship in paper-surface.css
  // now (the canonical renderer emits no hoisted <style>), so they are asserted by
  // the stylesheet's own tests — NOT here. What this leg still guarantees: the
  // section's inline style must NOT carry grid-template-columns, or an inline
  // declaration would out-specify the MQ and defeat the mobile collapse.
  absent(html, 'style="grid-template-columns', "no inline grid-template on the grid div");
  present(html, "wide-first", "child prose nested");
});

test("gap token maps: none/sm/lg resolve to their space vars, unknown falls to md", () => {
  const mk = (gap: unknown) =>
    renderHtml({
      type: "section",
      layout: { mode: "grid", tracks: 2, gap },
      blocks: [{ type: "paragraph", content: [{ type: "text", value: "x" }] }],
    });
  present(mk("none"), "--bp-grid-gap:var(--bp-space-none,0)", "gap none");
  present(mk("sm"), "--bp-grid-gap:var(--bp-space-sm,0.8rem)", "gap sm");
  present(mk("lg"), "--bp-grid-gap:var(--bp-space-lg,2.4rem)", "gap lg");
  present(mk("bogus"), "--bp-grid-gap:var(--bp-space-md,1.6rem)", "unknown gap → md");
});

test("a stringy tracks parses; a malformed one falls safe to 2", () => {
  const mk = (tracks: unknown) =>
    renderHtml({
      type: "section",
      layout: { mode: "grid", tracks },
      blocks: [{ type: "paragraph", content: [{ type: "text", value: "x" }] }],
    });
  present(mk("4"), "--bp-tracks:4", "whole-string tracks");
  present(mk("2;background:url(x)"), "--bp-tracks:2", "malformed tracks → default 2");
  absent(mk("2;background:url(x)"), "background:url", "malformed tracks not injected");
});

test("a malformed per-cell span/order is DROPPED (no style injection, D2)", () => {
  const html = renderHtml({
    type: "section",
    layout: { mode: "grid", tracks: 3 },
    blocks: [
      { type: "paragraph", span: "2;background:url(x)", order: "notint", content: [{ type: "text", value: "x" }] },
    ],
  });
  absent(html, "grid-column:span 2;background", "malformed span not injected");
  absent(html, "background:url", "no style-injection via span");
  present(html, 'class="bp-section__cell"', "cell still renders (bare wrapper)");
});

test("a non-grid section (absent or stack layout) stays a flex-col stack — no grid chrome", () => {
  const stackNoLayout = renderHtml({
    type: "section",
    title: "Plain",
    blocks: [{ type: "paragraph", content: [{ type: "text", value: "flat" }] }],
  });
  const stackExplicit = renderHtml({
    type: "section",
    layout: { mode: "stack" },
    blocks: [{ type: "paragraph", content: [{ type: "text", value: "flat" }] }],
  });
  for (const html of [stackNoLayout, stackExplicit]) {
    absent(html, "bp-section__grid", "no grid class on a stack section");
    absent(html, "--bp-tracks", "no track custom prop on a stack section");
    present(html, "flat", "child still renders");
  }
});
