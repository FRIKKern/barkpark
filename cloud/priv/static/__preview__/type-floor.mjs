#!/usr/bin/env node
// type-floor.mjs — THE LEGIBILITY FLOOR, TURNED INTO AN INSTRUMENT.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS FILE EXISTS (charter D240)
// ─────────────────────────────────────────────────────────────────────────────
//  app.css declares its own type scale at `:root` — "Type scale (decision 29)",
//  `--text-xs: 12px` — and then ships dozens of hand-written declarations UNDER
//  it. Measured across 30 cells (5 routes x 3 phone widths x 2 themes) the wave
//  read 228 of 1560 text-bearing instances computing below 12px, the largest
//  single contributor being `.instance-card-stat-k` at 10px: the front screen's
//  own CPU / RAM / DISK / DOCS legend, 48 instances in 6/6 #overview cells.
//
//  NO COMMITTED INSTRUMENT SAW IT, and that was proven by MUTATION rather than
//  by grep: `.instance-card-stat-k` 10px -> 6px left `__css_check` at
//  "0 error(s)" (its R4 reports every raw px font-size line and is REPORT-ONLY
//  by construction, __css_check.mjs R4), left the unit suite unchanged, and
//  left `overflow-guard --defect W18-overview-card-pill` printing
//  "28 / 28 cells clean" at rc=0 — on the very card whose legend was 6px.
//
//  This module is the missing refusal. It is a SOURCE parse, deliberately, and
//  it is paired with a DRIVEN leg (overflow-guard.mjs --defect
//  W20-type-floor-instances) that counts what those declarations actually
//  PAINT per route in a real browser. The source parse says "this declaration
//  is below the floor"; only the browser says "and it renders 48 times on the
//  front screen". Neither half is the other's evidence.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE FLOOR IS 12px, NOT 13px — AND THAT IS A DECISION, NOT AN OVERSIGHT
// ─────────────────────────────────────────────────────────────────────────────
//  Two floors are written down in this repo and they are NOT the same contract:
//
//    12px  `--text-xs` (app.css, "Type scale (decision 29)"). The type scale's
//          own smallest step. It is what the scale PROMISES about every label,
//          caption and eyebrow the console paints, and app.css already routes
//          ~18 declarations through `var(--text-xs)` and states the promise in
//          prose at the `.token-reveal` block: "12px is the type scale's
//          --text-xs floor and this rule stays ON it (D240): readability bought
//          with smaller type is not readability."
//
//    13px  the `.bp-console` theater contract, asserted in a real browser by
//          overflow-guard GR115 ("no theater text falls below 13px", computed
//          on `.bp-console-body` and `.bp-console-toggle` at 700x800). That
//          floor is SCOPED — it is about a dark monospace terminal pane whose
//          content is machine output a person reads line by line, and the
//          charter's own quotation of it ("under a 13px legibility floor this
//          epic has written down elsewhere") says "elsewhere" for exactly that
//          reason.
//
//  This module adopts 12px as the CONSOLE-WIDE floor because that is the floor
//  the type scale itself publishes, and because raising every chrome label to
//  13px would move ~46 declarations by 2-3px each — the "inflate a third of the
//  console's chrome" outcome the filing row explicitly refuses. 13px stays the
//  stricter, narrower contract inside `.bp-console`, and GR115 remains its
//  owner: this floor does not relax it and does not re-assert it.
//
//  WHAT THE FLOOR IS ABOUT: text a person READS. A `font-size` that sizes a
//  GLYPH — a caret, a rung dot, an icon inside a fixed-size box — is a
//  geometry declaration wearing typography's syntax, and raising it changes a
//  shape, not a legibility. Those sites are in ALLOWLIST below, ONE ENTRY EACH,
//  each with its own written reason. There is no class waiver: "glyphs are
//  exempt" would be a rule this file could not audit, and a new glyph-shaped
//  rule would inherit an exemption nobody granted it.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE ALLOWLIST IS A COMMITTED LITERAL AND ITS STALENESS IS FATAL (D180)
// ─────────────────────────────────────────────────────────────────────────────
//  D180: "THE ALLOWLIST MUST SHIP AS A COMMITTED LITERAL — an allowlist
//  computed from the current residue reports green even UNDER mutation, because
//  it grows with the artifact and can never refuse anything." So ALLOWLIST
//  below is typed out, selector by selector, and is NEVER derived from app.css.
//
//  D180 again: "AND THE STALENESS CLAUSE MUST BE FATAL: __css_check's allowlist
//  staleness reporter is `console.log`, never `errors.push` — a bogus
//  ALLOW_RAW_COLORS entry matching no line prints `stale … prune it` and EXITS
//  0. That is the one thing not to copy." An ALLOWLIST entry here that matches
//  no declaration in app.css is an ERROR with the same weight as a violation:
//  `audit().errors` carries it, the CLI exits 1, and the unit test reds.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHAT THE PARSE CAN AND CANNOT RESOLVE — SAID OUT LOUD, NOT SWALLOWED
// ─────────────────────────────────────────────────────────────────────────────
//  Resolved: `<n>px`, `<n>rem` (x16 — app.css sets no root font-size, so the
//  browser default is the only honest basis), and `var(--custom)` chains that
//  bottom out in a `:root` declaration of one of those two.
//
//  NOT resolved, and REPORTED BY NAME rather than counted clean: `em`, `%`,
//  `calc()`, `clamp()`, `min()`/`max()`, `inherit`/`smaller`/keywords, and any
//  `var()` whose fallback chain leaves the stylesheet. `audit()` returns them
//  in `.unresolved`; the CLI prints every one. A parse that silently dropped
//  them would be a floor with a hole in it that nobody could see.
//
//  BOTH SPELLINGS ARE READ. `font-size: 11px` and the `font:` SHORTHAND
//  (`font: 600 11px var(--font)`) are the same declaration to a browser, and
//  the filing row's own `grep -cE 'font-size:'` census cannot see the second —
//  it MISSED `.deploy-console-toggle`, which paints the deploy theater's header
//  at 11px eleven hundred lines above the `.bp-console` rule whose 13px floor
//  GR115 asserts in a browser.
//
// Run:  node cloud/priv/static/__preview__/type-floor.mjs          (inventory)
//       node cloud/priv/static/__preview__/type-floor.mjs --json
// Test: node --test cloud/priv/static/__preview__/type-floor.test.mjs

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const APP_CSS = path.resolve(HERE, "..", "app.css");

// THE FLOOR. See the header for why it is 12 and not 13.
export const FLOOR_PX = 12;

// The root font-size basis for `rem`. app.css declares no `html`/`:root`
// `font-size`, so the UA default is the only honest basis; it is named here
// rather than buried in the resolver so a future `html { font-size }` shows up
// as a contradiction instead of a silent re-scaling.
export const ROOT_FONT_PX = 16;

// ── ALLOWLIST — a committed literal, one entry per site, each with a reason ──
// `selector` is matched against the NORMALISED selector prelude (whitespace
// collapsed) and `px` against the RESOLVED computed size, so a value change is
// a staleness red rather than a silent re-blessing. `where` is prose for the
// reader; it is not matched on, because a media prelude is exactly the kind of
// thing that moves.
//
// EVERY ENTRY BELOW SIZES A GLYPH, NOT PROSE — and each is argued on its own,
// because there is no class waiver here (see the header).
export const ALLOWLIST = [
  {
    selector: ".ov-chip-glyph",
    px: 10,
    where: "#overview attention chips",
    reason:
      "sizes the chip's leading SYMBOL (a single glyph in a `line-height: 1` box), never a word. " +
      "The chip's readable text is its sibling and rides the scale. Raising this grows the icon and " +
      "the chip's own height; it buys no character of legibility.",
  },
  {
    selector: ".dom-rung-glyph",
    px: 9,
    where: "#sites domain-verification ladder",
    reason:
      "the rung's state DOT — one glyph, `line-height: 1`, inside a fixed rung box. It carries no text " +
      "node a person reads; its meaning is carried by the rung label beside it, which is on the scale.",
  },
  {
    selector: ".inst-cli-caret",
    px: 10,
    where: "instance CLI disclosure",
    reason:
      "a disclosure CARET, `line-height: 1`, `display: inline-block`, rotated by a transform on open. " +
      "Its font-size is the arrow's SIZE; 12px visually oversizes the arrow against a 13px label.",
  },
  {
    selector: ".choice-ico.sm",
    px: 11,
    where: "choice rows (settings + modals)",
    reason:
      "a 24x24 `inline-grid` ICON BOX. The declaration centres a glyph inside a box whose dimensions are " +
      "declared on the same line; the box, not the scale, is what bounds it.",
  },
  {
    selector: ".cmdk-foot kbd",
    px: 11,
    where: "command palette footer key caps",
    reason:
      "NOT a glyph argument and not a comfortable one: these are key CAPS (esc, Enter) and they SHOULD be " +
      "on the scale. Raised to 12px and DRIVEN, they push `span.cmdk-hint` to 296.91 inside a card whose " +
      "own box ends at 296 — overflow-guard's W22 min-content leg goes from a reported 288.8/272 squeeze at " +
      "320 to a hard `1 of 112 descendants paint OUTSIDE the card` failure. The footer needs to WRAP before " +
      "its type can grow, and that reflow is a layout change this slice's fence does not cover. Held at 11px " +
      "with the cost written down rather than shipped as a regression; the follow-up is the `.cmdk-foot` wrap.",
  },
  {
    selector: ".toast-ico",
    px: 11,
    where: "toast status badge",
    reason:
      "an 18x18 `display: grid; place-items: center` STATUS GLYPH (check / bang / info), and the box is " +
      "declared three lines above the size in the same rule. The toast's words are `.toast-body`, which " +
      "rides `var(--text-xs)` already. This is the icon, not the message.",
  },
  {
    selector: ".org-avatar",
    px: 11,
    where: "workspace switcher + topbar",
    reason:
      "a MONOGRAM inside a fixed square badge (`border-radius: 5px`, `place-items: center`) whose " +
      "dimensions are declared in the same rule. One or two initials, never a phrase; at 12px the glyph " +
      "crowds the badge's own edge. Enlarging the badge is a topbar layout decision with its own owner, " +
      "not a legibility fix — the workspace NAME beside it (`.ws-name`) is on `--text-base`.",
  },
  {
    selector: ".team-avatar",
    px: 10,
    where: "#settings members / teams roster",
    reason:
      "the same monogram argument at a 20x20 circle declared on the rule's first line. The readable " +
      "identity in that row is `.team-name` and `.team-sub`, both raised by this slice; the initials are " +
      "a recognition token bounded by a circle, and 12px inside 20px leaves no optical ring.",
  },
];

// ── parse ───────────────────────────────────────────────────────────────────

// Blank out comments while PRESERVING every byte offset and newline, so line
// numbers reported below are line numbers in the file on disk.
export function blankComments(css) {
  let out = "";
  let i = 0;
  while (i < css.length) {
    if (css[i] === "/" && css[i + 1] === "*") {
      const end = css.indexOf("*/", i + 2);
      const stop = end === -1 ? css.length : end + 2;
      for (let j = i; j < stop; j++) out += css[j] === "\n" ? "\n" : " ";
      i = stop;
      continue;
    }
    out += css[i];
    i++;
  }
  return out;
}

const lineAt = (src, index) => src.slice(0, index).split("\n").length;
const norm = (s) => s.replace(/\s+/g, " ").trim();

// Custom properties declared at `:root` (the only place app.css declares the
// type scale). Returned as a raw map so the resolver can walk var() chains.
export function rootVars(css) {
  const vars = new Map();
  const blank = blankComments(css);
  const re = /(^|})\s*([^{}]*?):root([^{}]*?)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(blank))) {
    const body = m[4];
    const dre = /(--[A-Za-z0-9_-]+)\s*:\s*([^;]+)/g;
    let d;
    while ((d = dre.exec(body))) vars.set(d[1], d[2].trim());
  }
  return vars;
}

// Resolve a font-size value expression to px, or null with a stated reason.
export function resolvePx(value, vars, seen = new Set()) {
  const v = norm(value).replace(/\s*!important\s*$/, "");
  let m = /^(-?\d*\.?\d+)px$/i.exec(v);
  if (m) return { px: Number(m[1]), basis: "px" };
  m = /^(-?\d*\.?\d+)rem$/i.exec(v);
  if (m) return { px: Number(m[1]) * ROOT_FONT_PX, basis: `rem x${ROOT_FONT_PX}` };
  m = /^var\(\s*(--[A-Za-z0-9_-]+)\s*(?:,([\s\S]*))?\)$/i.exec(v);
  if (m) {
    const name = m[1];
    if (seen.has(name)) return { px: null, why: `var() cycle at ${name}` };
    seen.add(name);
    if (vars.has(name)) {
      const inner = resolvePx(vars.get(name), vars, seen);
      if (inner.px !== null) return { px: inner.px, basis: `${name} = ${vars.get(name)}` };
      return { px: null, why: `${name} resolves to "${vars.get(name)}" (${inner.why})` };
    }
    if (m[2] !== undefined) {
      const fb = resolvePx(m[2], vars, seen);
      if (fb.px !== null) return { px: fb.px, basis: `${name} undeclared -> fallback ${norm(m[2])}` };
      return { px: null, why: `${name} is not declared at :root and its fallback is unresolvable` };
    }
    return { px: null, why: `${name} is not declared at :root` };
  }
  if (/^-?\d*\.?\d+(em|%|ex|ch|vw|vh|vmin|vmax|pt)$/i.test(v)) {
    return { px: null, why: `relative/absolute unit "${v}" — depends on an inherited or viewport basis this parse has no browser for` };
  }
  if (/^(calc|clamp|min|max)\(/i.test(v)) {
    return { px: null, why: `${v.slice(0, v.indexOf("("))}() expression — needs a layout to evaluate` };
  }
  return { px: null, why: `keyword or unrecognised value "${v}"` };
}

// The `font:` shorthand's size is the token immediately before an optional
// `/<line-height>` and the font family list. Grammar-lite on purpose: we want
// the SIZE, and any shorthand whose size we cannot find is reported unresolved
// rather than assumed absent.
export function fontShorthandSize(value) {
  const v = norm(value);
  if (/^inherit$/i.test(v)) return null; // inherits — carries no size of its own
  const m = /(^|\s)(-?\d*\.?\d+(?:px|rem|em|%)|var\(--[A-Za-z0-9_-]+\))(?:\s*\/\s*[^\s]+)?\s+\S/.exec(v);
  return m ? m[2] : "__UNPARSED__";
}

// Walk every rule block (including inside @media / @supports / @keyframes) and
// emit one record per font-size-bearing declaration.
export function fontSizeDeclarations(css) {
  const blank = blankComments(css);
  const vars = rootVars(css);
  const out = [];
  const stack = [];
  let preludeStart = 0;
  for (let i = 0; i < blank.length; i++) {
    const c = blank[i];
    if (c === "{") {
      const prelude = norm(blank.slice(preludeStart, i));
      stack.push({ prelude, bodyStart: i + 1 });
      preludeStart = i + 1;
      continue;
    }
    if (c === "}") {
      const frame = stack.pop();
      if (frame) {
        // A block whose body contains `{` is a container (@media etc.); its
        // declarations were emitted by the inner frames.
        const body = blank.slice(frame.bodyStart, i);
        if (!body.includes("{") && !frame.prelude.startsWith("@")) {
          const at = stack.map((f) => f.prelude).filter((p) => p.startsWith("@"));
          collect(frame.prelude, body, frame.bodyStart, at);
        }
      }
      preludeStart = i + 1;
      continue;
    }
    if (c === ";" && stack.length === 0) preludeStart = i + 1; // top-level @import/@charset
  }
  return out;

  function collect(selector, body, bodyStart, at) {
    const re = /(^|[;{\s])(font-size|font)\s*:\s*([^;}]+)/g;
    let m;
    while ((m = re.exec(body))) {
      const prop = m[2].toLowerCase();
      const raw = m[3].trim();
      const absIndex = bodyStart + m.index + m[0].indexOf(m[2]);
      let value = raw;
      if (prop === "font") {
        const size = fontShorthandSize(raw);
        if (size === null) continue; // `font: inherit` declares no size
        value = size;
      }
      const rec = {
        selector,
        prop,
        raw,
        value,
        line: lineAt(css, absIndex),
        media: at.join(" / ") || null,
      };
      if (value === "__UNPARSED__") {
        out.push({ ...rec, px: null, why: `font: shorthand whose size token could not be located in "${raw}"` });
        continue;
      }
      const r = resolvePx(value, vars, new Set());
      out.push({ ...rec, px: r.px, basis: r.basis || null, why: r.why || null });
    }
  }
}

// ── the audit ───────────────────────────────────────────────────────────────

export function audit(css, { floor = FLOOR_PX, allowlist = ALLOWLIST } = {}) {
  const decls = fontSizeDeclarations(css);
  const resolved = decls.filter((d) => d.px !== null);
  const unresolved = decls.filter((d) => d.px === null);
  const below = resolved.filter((d) => d.px < floor);

  const used = new Set();
  const violations = [];
  for (const d of below) {
    const idx = allowlist.findIndex((a) => a.selector === d.selector && a.px === d.px);
    if (idx === -1) violations.push(d);
    else used.add(idx);
  }
  const stale = allowlist.filter((_, i) => !used.has(i));

  const errors = [];
  for (const v of violations) {
    errors.push(
      `BELOW FLOOR  app.css:${v.line}  ${v.selector}  ${v.prop}: ${v.raw}  -> ${v.px}px < ${floor}px` +
      (v.media ? `  [${v.media}]` : "") +
      `\n    Not in ALLOWLIST. Either raise it to the type scale's floor, or add a literal entry ` +
      `naming this selector with a written reason — there is no class waiver.`,
    );
  }
  for (const s of stale) {
    errors.push(
      `STALE ALLOWLIST ENTRY  ${s.selector} @ ${s.px}px  matches NO declaration in app.css.\n` +
      `    D180: this is FATAL, not a console.log. Either the rule was deleted/renamed or its size ` +
      `changed; prune or re-argue the entry. A stale entry is an exemption nobody can audit.`,
    );
  }

  const histogram = {};
  for (const d of below) histogram[d.px] = (histogram[d.px] || 0) + 1;

  return { floor, decls, resolved, unresolved, below, violations, stale, errors, histogram };
}

// ── CLI ─────────────────────────────────────────────────────────────────────

function main(argv) {
  const json = argv.includes("--json");
  const css = fs.readFileSync(APP_CSS, "utf8");
  const r = audit(css);
  if (json) {
    process.stdout.write(JSON.stringify(r, null, 2) + "\n");
    return r.errors.length ? 1 : 0;
  }
  const hist = Object.keys(r.histogram)
    .map(Number).sort((a, b) => a - b)
    .map((k) => `${k}px:${r.histogram[k]}`).join(" / ");
  process.stdout.write(
    `\ntype-floor — app.css, floor ${r.floor}px (--text-xs, "Type scale (decision 29)")\n` +
    `  ${r.decls.length} font-size-bearing declarations parsed ` +
    `(${r.decls.filter((d) => d.prop === "font").length} via the \`font:\` shorthand)\n` +
    `  ${r.resolved.length} resolved to px · ${r.unresolved.length} unresolved (named below)\n` +
    `  ${r.below.length} below the floor${hist ? ` — ${hist}` : ""}\n` +
    `  ${r.below.length - r.violations.length} allowlisted · ${r.violations.length} violation(s) · ${r.stale.length} stale entr(ies)\n\n`,
  );
  if (r.below.length) {
    process.stdout.write(`BELOW ${r.floor}px — every one, allowlisted or not:\n`);
    for (const d of r.below.slice().sort((a, b) => a.px - b.px || a.line - b.line)) {
      const allowed = ALLOWLIST.some((a) => a.selector === d.selector && a.px === d.px);
      process.stdout.write(
        `  ${allowed ? "allow" : "VIOLA"}  ${String(d.px).padStart(5)}px  app.css:${String(d.line).padStart(4)}  ${d.selector}` +
        `${d.media ? `  [${d.media}]` : ""}\n`,
      );
    }
    process.stdout.write("\n");
  }
  if (r.unresolved.length) {
    process.stdout.write(`UNRESOLVED — reported by name, never counted clean:\n`);
    for (const d of r.unresolved) {
      process.stdout.write(`  app.css:${String(d.line).padStart(4)}  ${d.selector}  ${d.prop}: ${d.raw}  — ${d.why}\n`);
    }
    process.stdout.write("\n");
  }
  if (r.errors.length) {
    for (const e of r.errors) process.stderr.write(`  ✗ ${e}\n`);
    process.stderr.write(`\nTYPE FLOOR FAIL — ${r.violations.length} below-floor declaration(s), ${r.stale.length} stale allowlist entr(ies)\n`);
    return 1;
  }
  process.stdout.write(`TYPE FLOOR PASS — no declaration resolves below ${r.floor}px outside the ${ALLOWLIST.length}-entry literal allowlist\n`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
