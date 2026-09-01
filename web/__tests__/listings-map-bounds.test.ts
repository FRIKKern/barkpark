/**
 * Bounds on the caller-controlled geometry `components/listings-map.tsx` feeds
 * into Canvas2D — the label text, the pin radius, and the index a pointer hit
 * resolves through.
 *
 * All three inputs are content, not code: `title` is CMS-authored,
 * `matches[].w` is a prop, and `listings` is a prop that can change between two
 * paints. Canvas2D punishes each differently — an unbounded string is
 * unbounded per-frame work, a negative radius THROWS, and a stale index
 * resolves to the wrong row — so each gets its own bound.
 *
 * MEASURED IN CHROMIUM against the pre-fix code (the shipped `drawLabel` and
 * the shipped radius expression, transplanted verbatim, 900x300 canvas):
 *
 *   drawLabel("Mocca")     0.01 ms/frame,  label box          53 px wide
 *   drawLabel(1k chars)    0.02 ms/frame,  label box       6,758 px wide
 *   drawLabel(10k chars)   0.10 ms/frame,  label box      67,455 px wide
 *   drawLabel(100k chars)  1.04 ms/frame,  label box     674,428 px wide
 *   drawLabel(1M chars)   10.25 ms/frame,  label box   6,744,155 px wide
 *
 *   r from w = -10  ->  -19.5  IndexSizeError: Failed to execute 'arc' on
 *                              'CanvasRenderingContext2D': The radius provided
 *                              (-19.5) is negative.
 *   r from w = 1e9  ->  2500000005.5   no throw, and no measurable cost
 *
 * Both the box width and the per-frame cost are LINEAR in the string's length,
 * so bounding the string is what bounds the box — that is why the assertions
 * below are on the returned text. A canvas is not available under `node --test`,
 * so a width cannot be re-measured here; the Chromium numbers above are the
 * measurement and these tests are the pin.
 *
 * The component is a "use client" module with JSX, which `node --test` cannot
 * parse, so it is transpiled with the repo's own TypeScript compiler and its
 * `@/lib/*` aliases rewritten to file URLs — the same loader
 * `listings-map-href.test.ts` uses. These assertions therefore run the REAL
 * shipped functions.
 *
 * Run: `pnpm test` (or `cd web && node --test __tests__/listings-map-bounds.test.ts`).
 */

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import ts from "typescript";

/* ── load the component (tsx → mjs, alias → file URLs) ────────────────────── */

const componentsDir = fileURLToPath(new URL("../components/", import.meta.url));
const libUrl = new URL("../lib/", import.meta.url).href;

const source = readFileSync(
  path.join(componentsDir, "listings-map.tsx"),
  "utf8",
);
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

const tmpPath = path.join(
  componentsDir,
  `.listings-map-bounds.test-${process.pid}.mjs`,
);
writeFileSync(tmpPath, rewritten);
after(() => {
  try {
    unlinkSync(tmpPath);
  } catch {
    /* already gone */
  }
});

const mod = (await import(pathToFileURL(tmpPath).href)) as {
  pinLabelText?: (title: string) => string;
  pinRadius?: (dim: boolean, weight: number | undefined) => number;
  PIN_LABEL_MAX_GRAPHEMES?: number;
};

const graphemeCount = (s: string) =>
  typeof Intl.Segmenter === "function"
    ? [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)]
        .length
    : [...s].length;

/* ── subject presence ─────────────────────────────────────────────────────── */

test("listings-map exports the two bounds the draw path is supposed to apply", () => {
  assert.equal(
    typeof mod.pinLabelText,
    "function",
    "listings-map.tsx must export pinLabelText — drawLabel's text bound",
  );
  assert.equal(
    typeof mod.pinRadius,
    "function",
    "listings-map.tsx must export pinRadius — drawPins' radius bound",
  );
  assert.equal(typeof mod.PIN_LABEL_MAX_GRAPHEMES, "number");
});

const CAP = 64;

/** `assert.match` on a 30KB source dumps the whole file into the TAP report,
 *  which buries the one line that failed. Assert on the boolean instead. */
const hasSource = (re: RegExp, why: string) =>
  assert.ok(re.test(source), `listings-map.tsx: ${why}`);
const lacksSource = (re: RegExp, why: string) =>
  assert.ok(!re.test(source), `listings-map.tsx: ${why}`);

test("the draw path really is wired to those bounds, not to the raw values", () => {
  // A bound nothing calls is not a bound. These pin the live call sites, so a
  // future edit that goes back to measuring/painting `text` or to computing the
  // radius inline reds here rather than silently reopening the hole.
  hasSource(
    /const label = pinLabelText\(text\);/,
    "drawLabel must derive its label from pinLabelText",
  );
  hasSource(
    /ctx\.measureText\(label\)/,
    "drawLabel must measure the BOUNDED label — measureText is the cost",
  );
  hasSource(/ctx\.fillText\(label,/, "drawLabel must paint the bounded label");
  lacksSource(
    /ctx\.(measureText|fillText)\(text[,)]/,
    "no measure/paint may take the raw, unbounded title",
  );
  hasSource(
    /pinRadius\(dim, weight\)/,
    "drawPins must take its radius from pinRadius",
  );
  // The raw expression is allowed to exist exactly once — INSIDE `pinRadius`,
  // where the floor is applied to it. A second copy would be a fork that the
  // floor does not cover, which is how this class of defect comes back.
  const raw =
    source.match(/dim \? 4\.5 : 5\.5 \+ \(weight \? weight \* 2\.5 : 0\)/g) ?? [];
  assert.equal(
    raw.length,
    1,
    `the raw radius expression appears ${raw.length}x — it must live only in pinRadius`,
  );
  hasSource(
    /export function pinRadius\([\s\S]{0,200}?const r = dim \? 4\.5 : 5\.5/,
    "…and that one copy must be the one pinRadius floors",
  );
});

/* ── DEFECT 1: the canvas label is length-bounded ─────────────────────────── */

test("FAIL-BEFORE: the shipped label text was whatever the CMS said", () => {
  // What `drawLabel` measured and painted BEFORE the fix, verbatim: the raw
  // `l.title`, straight from `drawLabel(ctx, p.x, p.y, l.title)`. Kept here as
  // the baseline the assertions below are a fix OF — it is what produced the
  // 6,744,155px label box and the 10.25ms-per-frame draw quoted in the header.
  const preFixLabelText = (title: string) => title;
  const runaway = "x".repeat(1e6);
  assert.equal(preFixLabelText(runaway).length, 1e6);
  assert.ok(
    preFixLabelText(runaway).length > CAP + 1,
    "the pre-fix label was unbounded — that is the defect",
  );
});

test("a runaway CMS title is elided to a bounded label", () => {
  for (const n of [1e3, 1e4, 1e5, 1e6]) {
    const out = mod.pinLabelText!("x".repeat(n));
    assert.ok(
      graphemeCount(out) <= CAP + 1,
      `a ${n}-char title painted ${graphemeCount(out)} graphemes ` +
        `(cap ${CAP} + the ellipsis)`,
    );
    // measureText/fillText cost is linear in the string, so the code-unit
    // length is the thing that actually has to be bounded.
    assert.ok(
      out.length <= CAP + 1,
      `a ${n}-char title still painted ${out.length} code units`,
    );
    assert.ok(out.endsWith("…"), "an elided label must say it was elided");
  }
});

test("the label is elided, never dropped — the pin still says what it is", () => {
  // A fix that draws no label at all would satisfy a pure "is it bounded"
  // assertion. It must not satisfy this one.
  const out = mod.pinLabelText!(`Bislett hundepark ${"!".repeat(5000)}`);
  assert.ok(out.startsWith("Bislett hundepark"), `label was "${out}"`);
  assert.ok(out.length > 10, "the elided label must still carry the name");
});

test("an ordinary title passes through byte-identical", () => {
  // The subject must survive the bound: every real listing title is short, and
  // a short title must reach the canvas exactly as authored.
  for (const title of [
    "Mocca",
    "Frognerparken hundeområde",
    "Café Ø — Grünerløkka",
    "Sofienbergparken (nord)",
    "x".repeat(CAP),
  ]) {
    assert.equal(mod.pinLabelText!(title), title);
  }
});

test("elision cuts on grapheme boundaries, never mid-emoji", () => {
  const flag = "🇳🇴"; // one grapheme, two code points, four UTF-16 units
  const out = mod.pinLabelText!(flag.repeat(400));
  assert.ok(graphemeCount(out) <= CAP + 1);
  // A code-unit slice would leave a lone surrogate here; a grapheme walk cannot.
  assert.doesNotMatch(
    out,
    /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/,
    `elided label contains a lone surrogate: ${JSON.stringify(out)}`,
  );
  assert.ok(out.startsWith(flag));
});

test("a non-string title yields an empty label rather than throwing", () => {
  for (const junk of [undefined, null, 42, {}, ["a"]]) {
    assert.equal(mod.pinLabelText!(junk as unknown as string), "");
  }
});

/* ── DEFECT 2: the pin radius has a floor ─────────────────────────────────── */

test("FAIL-BEFORE: the shipped radius expression went negative", () => {
  // The expression `drawPins` computed BEFORE the fix, verbatim. Kept as the
  // baseline: it is what Chromium answered `IndexSizeError … radius (-19.5) is
  // negative` to, out of the middle of a frame.
  const preFixRadius = (dim: boolean, weight: number | undefined) =>
    dim ? 4.5 : 5.5 + (weight ? weight * 2.5 : 0);
  assert.equal(preFixRadius(false, -10), -19.5);
  assert.ok(preFixRadius(false, -10) < 0, "ctx.arc THROWS on this value");
  assert.ok(
    Number.isNaN(preFixRadius(false, "abc" as unknown as number)),
    "a non-numeric weight produced NaN, which ctx.arc silently ignores",
  );
  assert.equal(preFixRadius(false, Infinity), Infinity);
});

test("a negative finder weight can no longer produce a negative arc radius", () => {
  // Pre-fix, w = -10 gave r = -19.5, and ctx.arc threw IndexSizeError out of
  // drawPins — losing every pin queued after it, for the whole frame.
  for (const w of [-10, -1, -0.4, -1e9]) {
    const r = mod.pinRadius!(false, w);
    assert.ok(r >= 1, `pinRadius(false, ${w}) = ${r}, which ctx.arc rejects`);
  }
});

test("a non-finite finder weight lands on the floor instead of painting nothing", () => {
  // NaN/Infinity do not throw — ctx.arc just draws nothing, which is the same
  // hole seen from the other side (a pin that silently vanishes).
  for (const w of [NaN, Infinity, -Infinity, "abc" as unknown as number]) {
    const r = mod.pinRadius!(false, w as number);
    assert.ok(
      Number.isFinite(r) && r >= 1,
      `pinRadius(false, ${String(w)}) = ${r}`,
    );
  }
});

test("the radii the shipped app actually draws are unchanged", () => {
  // finder.tsx bounds w to [0.2, 1.0]; those pins must look exactly as before,
  // so the floor is provably inert on the live range.
  assert.equal(mod.pinRadius!(true, undefined), 4.5, "dim pin");
  assert.equal(mod.pinRadius!(true, 1), 4.5, "dim pin ignores weight");
  assert.equal(mod.pinRadius!(false, undefined), 5.5, "unweighted pin");
  assert.equal(mod.pinRadius!(false, 0), 5.5, "w=0 is falsy, as before");
  assert.equal(mod.pinRadius!(false, 0.2), 6, "finder's floor weight");
  assert.equal(mod.pinRadius!(false, 1), 8, "finder's ceiling weight");
});

/* ── DEFECT 3: a hit index never crosses a listings swap ──────────────────── */

/**
 * The window, stated once: `useEffect(… , [listings])` writes
 * `listingsRef.current` IMMEDIATELY and defers the repaint via
 * `scheduleDraw()` (rAF), while `posRef` is written only at the tail of
 * `drawPins`. For one frame after a `listings` prop change, `hitTest` walks the
 * PREVIOUS frame's positions while `endDrag`/`setHover` resolve that index
 * against the NEW array.
 *
 * Reproduced in Chromium with real pointer input against a transplant of this
 * exact ordering (10 pins drawn, array swapped on pointerdown, index resolved
 * on pointerup of the same physical click, redraw still pending):
 *
 *   shrink 10 -> 3 : idx 9 -> undefined -> "TypeError: Cannot read properties
 *                    of undefined (reading 'title')" (what the popover render
 *                    does at `selected.listing.title`)
 *   swap  10 -> 10 : idx 9 -> the WRONG listing (B9 where A9 was drawn), no throw
 *
 * NOT reachable through the shipped app: the only in-repo consumer,
 * `components/map-landing.tsx`, passes `listings` straight through as a server
 * prop and never mutates it client-side — filtering rides `matches`, not
 * `listings`. It is reachable by any external consumer of this exported
 * component that swaps the array.
 *
 * `hitTest` closes over component refs and cannot be imported, so the two
 * behavioural cases below run a MODEL of the ordering — the pre-fix resolution
 * and the post-fix guard side by side, the same shape `listings.test.ts` uses.
 * The source assertions that follow are what pin the real code.
 */

type Row = { id: string; title: string };
const rows = (n: number, tag: string): Row[] =>
  Array.from({ length: n }, (_, i) => ({ id: tag + i, title: tag + i }));

/** Resolution as it was BEFORE the fix: positions carry no identity. */
function resolvePreFix(
  pos: Array<{ x: number } | null>,
  list: Row[],
  idx: number,
): Row | undefined {
  return idx >= 0 && idx < pos.length ? list[idx] : undefined;
}

/** Resolution as it is NOW: positions carry the array they were drawn from. */
function resolvePostFix(
  drawn: { list: readonly Row[]; pos: Array<{ x: number } | null> },
  list: readonly Row[],
  idx: number,
): Row | undefined {
  if (drawn.list !== list) return undefined; // hitTest refuses: returns -1
  return idx >= 0 && idx < drawn.pos.length ? (list[idx] as Row) : undefined;
}

test("FAIL-BEFORE: an index taken across a listings swap resolved the wrong row", () => {
  const drawnList = rows(10, "A");
  const pos = drawnList.map((_, i) => ({ x: 90 + i * 40 }));

  // Same length, different rows: the popover opened on a listing that was never
  // under the pointer.
  assert.equal(resolvePreFix(pos, rows(10, "B"), 9)?.id, "B9");
  // Shrunk: `undefined`, which then throws at `selected.listing.title`.
  assert.equal(resolvePreFix(pos, rows(3, "B"), 9), undefined);
});

test("a hit index is refused when the listings array changed since the paint", () => {
  const drawnList = rows(10, "A");
  const drawn = { list: drawnList, pos: drawnList.map((_, i) => ({ x: 90 + i * 40 })) };

  assert.equal(resolvePostFix(drawn, rows(10, "B"), 9), undefined);
  assert.equal(resolvePostFix(drawn, rows(3, "B"), 9), undefined);
});

test("hits still land on the SAME array — the guard is not a mute button", () => {
  const drawnList = rows(10, "A");
  const drawn = { list: drawnList, pos: drawnList.map((_, i) => ({ x: 90 + i * 40 })) };
  assert.equal(resolvePostFix(drawn, drawnList, 9)?.id, "A9");
  assert.equal(resolvePostFix(drawn, drawnList, 0)?.id, "A0");
});

test("the live hitTest carries and checks the array its positions came from", () => {
  hasSource(
    /posRef\.current = \{ list, pos \};/,
    "drawPins must record WHICH array the positions were computed from",
  );
  hasSource(
    /const \{ list, pos \} = posRef\.current;[\s\S]{0,900}?if \(list !== listingsRef\.current\) return -1;/,
    "hitTest must refuse a hit whose positions predate the current listings",
  );
  // …and the resolution sites that consume that index still read the same ref.
  hasSource(
    /const l = listingsRef\.current\[idx\];/,
    "endDrag still resolves the listing off listingsRef",
  );
  hasSource(
    /const p = posRef\.current\.pos\[idx\];/,
    "endDrag reads the position out of the generation-stamped posRef",
  );
});
