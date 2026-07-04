#!/usr/bin/env node
// __css_check.mjs — the SPA's design contract, machine-checked (epic charter
// decision 2: "A new __css_check.mjs validator (dead classes, undefined tokens)
// gates every SPA slice").
//
// ERRORS (exit 1):
//   E1  var(--x) consumed anywhere in app.css / app.js / index.html where --x
//       has no definition in app.css (a fallback does not excuse it — every
//       consumed token must be part of the contract).
//   E2  a class name emitted by index.html or an app.js template string /
//       classList call / className assignment that has no rule in app.css.
//   E3  a dynamic class composition site in app.js (e.g. 'dot ' + kind) whose
//       static head is not explicitly allowlisted below — dynamic names cannot
//       be statically resolved, so every such site must be a conscious entry.
//       Static fragments in the dynamic TAIL (e.g. the " is-revoked" ternary
//       arm after the concat boundary) ARE extracted and E2-checked: inside
//       the attribute region, a double-quoted string starting with whitespace
//       is by construction a class fragment.
//   E4  a class token the checker cannot statically parse (e.g. a template
//       literal's ${...} inside class="..."). The extractor understands this
//       codebase's single-quoted concat style; anything else must fail loudly
//       here rather than ship unchecked — rewrite the site in concat style
//       (with an ALLOW_PREFIXES entry if dynamic).
//   E5  WCAG contrast (charter decision 28): every pair in CONTRAST_PAIRS —
//       a DECLARED manifest of the fg/bg token combinations the SPA actually
//       renders — is resolved for BOTH themes and must clear its threshold
//       (4.5:1 for text roles, 3:1 for non-text UI). Tune token values in the
//       app.css token blocks until green; never silence a pair.
//   E6  raw color literal in app.css outside the :root / [data-theme="dark"]
//       token blocks (was report R1; promoted to error per decision 28). The
//       conscious exceptions live in ALLOW_RAW_COLORS below — exact trimmed
//       lines, each with a reason; an edited line goes stale and fails until
//       re-ratified here.
//   E7  an external-host RESOURCE LOAD (link/script/img/@import/url(...)
//       pointing at http(s):// or //) in index.html, styleguide.html or
//       app.css — the console must render fully offline (decision 27).
//       Plain <a href> navigation links are deliberately allowed.
//   E8  scoped-theme alias leak: a token declared only in :root whose value
//       references a token the dark block re-themes. var() substitutes where
//       the property is DECLARED, so such an alias freezes the LIGHT value in
//       any subtree that scopes [data-theme="dark"] onto a non-root element
//       (the styleguide panes). Re-declare the alias in the dark block.
//
// REPORTS (printed, never exit-affecting):
//   R2  tokens defined in app.css that nothing consumes yet.
//   R3  REPORT-ONLY: known violations whose fix would require editing app.js
//       (app.js is owned by another slice — leave, don't touch).
//   R4  raw px font-sizes in app.css rules outside the token blocks — the
//       type-scale migration backlog for the decision-24 sweep.
//
// Zero dependencies. Run: node __css_check.mjs

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const read = (f) => fs.readFileSync(path.join(dir, f), "utf8");

// ── Allowlists — every entry is printed on every run so the list stays honest ─

// Exact static head (the text before the first concat boundary) of each KNOWN
// dynamic class composition site in app.js. Seeded by inspecting the actual
// sites; a new dynamic site fails E3 until it is consciously added here.
const ALLOW_PREFIXES = [
  "toast toast-",      // showToast(): kind ∈ success | error | info
  "choice-ico ",       // provider picker tile: + p.cls (brand-hetzner | brand-do | brand-aws | brand-vultr)
  "choice-ico sm ",    // provider row mini-tile: + m.cls (same brand-* set)
  "fleet-row token-row", // token row: + (revoked ? " is-revoked" : "")
  "dot ",              // badge(): + esc(kind) (up | down | unknown | online | offline | warn)
  "dep-pill dep-",     // deployment status pill: + esc(st) (live | failed | building | pushing | queued)
  "deploy-fail",       // deploy-fail row: + (failureTone === "blocked" ? " deploy-fail--blocked" : "")
  "deploy-console",    // + (open ? "" : " is-collapsed")
  "tier",              // + " tier-current" / " tier-free" conditionals
  "auth-tab",          // /new auth tabs: + (mode ? " is-active" : "")
  "new-console",       // + (collapsed ? " is-collapsed" : "")
  "new-step ",         // + cls (done | active | failed)
  "status-pill status-pill--", // statusPill(): + role (ok | info | warn | danger | neutral)
  "rollup-card rollup-card--",  // rollupCard(): + bucket (attention | inflight | healthy)
  "bp-tl-step bp-tl-step--",    // timelineHtml(): + role (ok | active | failed | pending)
  "bp-console",                 // timelineConsoleHtml(): + (collapsed ? " is-collapsed" : "")
  "inst-tab",                   // instanceTabStripHtml(): + (on ? " is-active" : "")
  "wh-del-status wh-del-status--", // deliveryRowHtml(): + tone (ok | danger | info)
];

// Classes that intentionally have no style rule: they are JS/structural hooks
// (selector targets, event delegation markers), not visual classes. Each is
// printed on every run; removing the hook from the markup should remove the
// entry too.
const ALLOW_HOOK_CLASSES = [
  "view",              // section container app.js shows/hides per route ($$(".view"))
  "modal-body",        // openModal() innerHTML target (selected by #modal-body)
  "session-revoke",    // querySelectorAll(".session-revoke") — revoke button in the sessions panel
  "notif-smtp",        // querySelector(".notif-smtp") — SMTP fieldset container in notifications
  "token-revoke",      // querySelectorAll(".token-revoke[data-id]") — per-token revoke button
  "token-ab",          // querySelectorAll(".token-ab") — ability checkboxes in the new-token modal
  "fleet-open-studio", // querySelectorAll(".fleet-open-studio") — Open Studio button per fleet row
  "new-plan",          // querySelectorAll(".new-plan") — plan-choice buttons on the /new pricing step
  "wh-event-cb",       // querySelectorAll(".wh-event-cb") — event checkboxes in the create-webhook modal
];

// R3 — violations we know about that live in app.js (another slice owns app.js
// this wave). Keep entries until the owning slice lands the fix.
const REPORT_ONLY = [];

// E6 — the conscious raw-color exceptions (decision 28). EXACT trimmed line
// text as it appears in app.css (comments stripped); each entry carries its
// reason and is printed on every run. Editing the line invalidates the entry.
const ALLOW_RAW_COLORS = [
  { line: ".modal-backdrop { position: absolute; inset: 0; background: rgba(0, 0, 0, 0.5); backdrop-filter: blur(2px); }", why: "scrim — theme-invariant by design" },
  { line: "color: #fff; font-weight: 700; font-size: 13px;", why: "white initials on the fixed provider brand tiles" },
  { line: ".brand-hetzner { background: #d50c2d; }", why: "Hetzner brand colour" },
  { line: ".brand-do { background: #0080ff; }", why: "DigitalOcean brand colour" },
  { line: ".brand-aws { background: #232f3e; }", why: "AWS brand colour" },
  { line: ".brand-vultr { background: #007bfc; }", why: "Vultr brand colour" },
  { line: "background: rgba(127, 127, 127, 0.12);", why: "hue-neutral token-chip tint, works in both themes" },
  { line: ".btn-vercel { background: #000; color: #fff; border-color: #000; }", why: "Vercel brand button" },
  { line: ".btn-vercel:hover { background: #111; text-decoration: none; }", why: "Vercel brand button hover" },
  { line: '[data-theme="dark"] .btn-vercel { background: #fff; color: #000; border-color: #fff; }', why: "Vercel brand button (dark)" },
  { line: '[data-theme="dark"] .btn-vercel:hover { background: #eee; }', why: "Vercel brand button hover (dark)" },
];

// E5 — THE contrast manifest (decision 28). Each entry is a fg/bg pairing the
// SPA really renders; `over` names the surface a translucent bg composites
// onto first. min 4.5 = text, min 3 = non-text UI (dots, borders, glyphs).
// Both themes are checked. Add a pair when a new component pairs tokens;
// removing one requires removing the component that renders it.
const CONTRAST_PAIRS = [
  { fg: "--text", bg: "--bg", min: 4.5, why: "body copy" },
  { fg: "--text", bg: "--surface", min: 4.5, why: "copy on cards" },
  { fg: "--text", bg: "--muted-surface", min: 4.5, why: "copy on muted/hover rows" },
  { fg: "--muted-text", bg: "--bg", min: 4.5, why: "secondary copy" },
  { fg: "--muted-text", bg: "--surface", min: 4.5, why: "secondary copy on cards" },
  { fg: "--dim", bg: "--bg", min: 4.5, why: "tertiary copy (.dim)" },
  { fg: "--dim", bg: "--muted-surface", min: 4.5, why: "tertiary copy on muted" },
  { fg: "--primary-fg", bg: "--primary", min: 4.5, why: ".btn-primary / avatar label" },
  { fg: "--primary", bg: "--bg", min: 4.5, why: "links" },
  { fg: "--primary", bg: "--surface", min: 4.5, why: "links on cards" },
  { fg: "--ok", bg: "--surface", min: 4.5, why: "success text (.plan-rec, .new-eyebrow.ok)" },
  { fg: "--ok", bg: "--ok-soft", over: "--surface", min: 4.5, why: ".runway-sub trial chip" },
  { fg: "--danger", bg: "--surface", min: 4.5, why: "error text (.deploy-fail, .wh-del-err)" },
  { fg: "--danger", bg: "--danger-soft", over: "--surface", min: 4.5, why: ".dep-failed pill text" },
  { fg: "--warn-strong", bg: "--warn-soft", over: "--surface", min: 4.5, why: ".dep-building pill text" },
  { fg: "--text", bg: "--ok-soft", over: "--surface", min: 4.5, why: ".notice-ok copy" },
  { fg: "--text", bg: "--warn-soft", over: "--surface", min: 4.5, why: ".notice-warn copy" },
  { fg: "--text", bg: "--danger-soft", over: "--surface", min: 4.5, why: ".notice-error copy" },
  { fg: "--console-fg", bg: "--console-bg", min: 4.5, why: "console lines" },
  { fg: "--console-dim", bg: "--console-bg", min: 4.5, why: "console timestamps" },
  { fg: "--ok", bg: "--muted-surface", min: 3, why: "ok status dot on badge" },
  { fg: "--warn", bg: "--muted-surface", min: 3, why: "warn status dot on badge" },
  { fg: "--danger", bg: "--muted-surface", min: 3, why: "danger status dot" },
  { fg: "--info", bg: "--surface", min: 3, why: "active-step ring / probe dot" },
  { fg: "--accent", bg: "--surface", min: 3, why: "branch-preview accent border" },
  { fg: "--ring", bg: "--bg", min: 3, why: "focus-ring visibility" },
  { fg: "--primary-fg", bg: "--ok", min: 4.5, why: ".badge-current text / toast-success glyph / done step-dot" },
  { fg: "--primary-fg", bg: "--danger", min: 4.5, why: ".btn-danger label / toast-error glyph / failed step-dot" },
  { fg: "--primary-fg", bg: "--muted-text", min: 3, why: "toast-info icon glyph" },
];

// ── Read the tree ────────────────────────────────────────────────────────────

const cssRaw = read("app.css");
const jsRaw = read("app.js");
const htmlRaw = read("index.html");
const styleguideRaw = read("styleguide.html"); // the living spec — required (decision 27)

const stripCssComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
const css = stripCssComments(cssRaw);

const lineOf = (src, index) => src.slice(0, index).split("\n").length;

// ── app.css: defined tokens, consumed tokens, defined classes ───────────────

const definedTokens = new Set();
for (const m of css.matchAll(/(?:^|[{;\s])(--[A-Za-z0-9_-]+)\s*:/g)) definedTokens.add(m[1]);

/** var(--x) consumption sites across all three files. */
function consumedTokens(src, file) {
  const out = [];
  for (const m of src.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)/g)) {
    out.push({ token: m[1], file, line: lineOf(src, m.index) });
  }
  return out;
}
// styleguide.html may DEFINE page-local --sg-* tokens in its own <style> block
// (checked below); everything else it consumes must come from app.css.
const sgLocalTokens = new Set();
for (const m of styleguideRaw.matchAll(/(?:^|[{;\s])(--[A-Za-z0-9_-]+)\s*:/g)) sgLocalTokens.add(m[1]);

const consumed = [
  ...consumedTokens(css, "app.css"),
  ...consumedTokens(jsRaw, "app.js"),
  ...consumedTokens(htmlRaw, "index.html"),
  ...consumedTokens(styleguideRaw, "styleguide.html").filter((c) => !sgLocalTokens.has(c.token)),
];

// Selector text = whatever precedes a "{" (declaration bodies are cleared at
// ";" and "}", so property values never leak in). Handles @media nesting.
const cssClasses = new Set();
{
  let buf = "";
  for (const c of css) {
    if (c === "{") {
      for (const m of buf.matchAll(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/g)) cssClasses.add(m[1]);
      buf = "";
    } else if (c === "}" || c === ";") buf = "";
    else buf += c;
  }
}

// ── index.html + app.js: emitted classes ────────────────────────────────────

const CLASS_TOKEN = /^-?[A-Za-z_][A-Za-z0-9_-]*$/;
const emitted = []; // { cls, file, line }
const dynamicSites = []; // { head, file, line }
const allowlistedHits = [];
const badTokens = []; // { tok, file, line } — statically unparseable (E4)

function emitToken(t, file, line) {
  if (!t) return;
  if (CLASS_TOKEN.test(t)) emitted.push({ cls: t, file, line });
  else badTokens.push({ tok: t, file, line });
}

/** Static class="..." attributes (HTML source — no dynamic parts). */
for (const m of htmlRaw.matchAll(/class="([^"]*)"/g)) {
  const line = lineOf(htmlRaw, m.index);
  for (const t of m[1].split(/\s+/).filter(Boolean)) {
    emitToken(t, "index.html", line);
  }
}

/**
 * A class value from a `.className = "..."` assignment or a classList call.
 * A trailing single quote marks a concat boundary (dynamic tail): complete
 * tokens in the head are checked, the trailing partial token (if the head
 * does not end in whitespace) is the dynamic prefix, and the whole head must
 * be an ALLOW_PREFIXES entry. (class="..." attributes in app.js go through
 * walkClassAttr below, which additionally extracts tail fragments.)
 */
function handleClassValue(value, file, line) {
  const q = value.indexOf("'");
  if (q === -1) {
    for (const t of value.split(/\s+/).filter(Boolean)) {
      emitToken(t, file, line);
    }
    return;
  }
  const head = value.slice(0, q);
  const parts = head.split(/\s+/).filter(Boolean);
  const endsComplete = /\s$/.test(head) || head === "";
  const complete = endsComplete ? parts : parts.slice(0, -1);
  for (const t of complete) {
    emitToken(t, file, line);
  }
  if (ALLOW_PREFIXES.includes(head)) {
    allowlistedHits.push({ head, file, line });
  } else {
    dynamicSites.push({ head, file, line });
  }
}

/**
 * Walk one class="..." attribute in app.js source starting right after the
 * opening quote. The SPA builds HTML in single-quoted concatenated strings, so
 * within the attribute region the source alternates:
 *   attr text  ─'→  JS code  ─'→  attr text …   (a ' toggles string/code)
 * and double-quoted strings inside the code segments (ternary arms like
 * " is-revoked") are fragments concatenated into the attribute. Returns the
 * verbatim static head, every tail fragment tagged with whether its trailing
 * token is complete, and the walk end index. Backslash escapes are honoured.
 */
function walkClassAttr(src, start) {
  const cap = Math.min(src.length, start + 2000);
  let state = "attr"; // attr | code | dq
  let head = null;
  let dynamic = false;
  let buf = "";
  const frags = []; // { text, trailingComplete }
  let i = start;
  for (; i < cap; i++) {
    const c = src[i];
    if (state === "attr") {
      if (c === "\\") { buf += src[++i] ?? ""; continue; }
      if (c === '"') break; // attribute closed — trailing token is complete
      if (c === "'") {
        if (head === null) head = buf;
        else frags.push({ text: buf, trailingComplete: false }); // dynamic follows
        buf = "";
        dynamic = true;
        state = "code";
      } else buf += c;
    } else if (state === "code") {
      if (c === "'") { state = "attr"; buf = ""; }
      else if (c === '"') { state = "dq"; buf = ""; }
    } else { // dq — a string literal inside the code segment
      if (c === "\\") { buf += src[++i] ?? ""; continue; }
      if (c === '"') { frags.push({ text: buf, trailingComplete: true }); buf = ""; state = "code"; }
      else buf += c;
    }
  }
  if (state === "attr") {
    if (head === null) head = buf;
    else if (buf) frags.push({ text: buf, trailingComplete: true });
  }
  return { head: head ?? buf, dynamic, frags, end: i };
}

{
  let idx = 0;
  for (;;) {
    const at = jsRaw.indexOf('class="', idx);
    if (at === -1) break;
    const valueStart = at + 'class="'.length;
    const line = lineOf(jsRaw, at);
    const walk = walkClassAttr(jsRaw, valueStart);
    const dynamic = walk.dynamic; // a ' concat boundary was crossed
    // Static head — same rules as handleClassValue.
    const parts = walk.head.split(/\s+/).filter(Boolean);
    const headEndsComplete = !dynamic || /\s$/.test(walk.head) || walk.head === "";
    for (const t of headEndsComplete ? parts : parts.slice(0, -1)) {
      emitToken(t, "app.js", line);
    }
    if (dynamic) {
      if (ALLOW_PREFIXES.includes(walk.head)) allowlistedHits.push({ head: walk.head, file: "app.js", line });
      else dynamicSites.push({ head: walk.head, file: "app.js", line });
      // Tail fragments: a fragment must start with whitespace for its first
      // token to be a complete class (otherwise it suffixes the dynamic part);
      // the trailing token is complete unless more dynamic content follows.
      for (const f of walk.frags) {
        let toks = f.text.split(/\s+/);
        if (!/^\s/.test(f.text)) toks = toks.slice(1);
        if (!f.trailingComplete && !/\s$/.test(f.text)) toks = toks.slice(0, -1);
        for (const t of toks.filter(Boolean)) emitToken(t, "app.js", line);
      }
    }
    idx = Math.max(walk.end, valueStart) + 1;
  }
}

// className = "..." (+ optional concat → dynamic) and classList.add/remove/toggle("x").
for (const m of jsRaw.matchAll(/\.className\s*=\s*"([^"]*)"(\s*\+)?/g)) {
  const line = lineOf(jsRaw, m.index);
  if (m[2]) handleClassValue(m[1] + "'", "app.js", line); // mark trailing dynamic boundary
  else handleClassValue(m[1], "app.js", line);
}
for (const m of jsRaw.matchAll(/classList\.(?:add|remove|toggle)\(\s*"([^"]+)"/g)) {
  handleClassValue(m[1], "app.js", lineOf(jsRaw, m.index));
}

// ── Contrast engine (E5) ─────────────────────────────────────────────────────
// Resolve the token maps per theme: the FIRST top-level `:root { … }` block is
// light; `[data-theme="dark"] { … }` overrides it for dark. (The reduced-motion
// `:root` re-declaration sits inside @media, later in the file — the first
// match wins here by construction.) Token blocks contain no nested braces.

function parseTokenBlock(re) {
  const m = css.match(re);
  if (!m) return {};
  const map = {};
  for (const d of m[1].matchAll(/(--[A-Za-z0-9_-]+)\s*:\s*([^;]+);/g)) map[d[1]] = d[2].trim();
  return map;
}
const lightTokens = parseTokenBlock(/:root\s*\{([\s\S]*?)\}/);
const darkOverrides = parseTokenBlock(/\[data-theme="dark"\]\s*\{([\s\S]*?)\}/);
const darkTokens = { ...lightTokens, ...darkOverrides };

/** Substitute var(--x) references until the value is literal. */
function resolveValue(name, map, seen = new Set()) {
  if (seen.has(name)) throw new Error(`token cycle at ${name}`);
  seen.add(name);
  let v = map[name];
  if (v === undefined) return undefined;
  for (let i = 0; i < 10 && /var\(/.test(v); i++) {
    v = v.replace(/var\(\s*(--[A-Za-z0-9_-]+)\s*\)/g, (_, t) => {
      const r = resolveValue(t, map, new Set(seen));
      return r === undefined ? "UNRESOLVED" : r;
    });
  }
  return v;
}

/** Parse a literal CSS color → {r,g,b,a} in 0..1, or null if not a color. */
function parseColor(v) {
  if (!v) return null;
  v = v.trim();
  let m = v.match(/^hsla?\(\s*([\d.]+)(?:deg)?[ ,]+([\d.]+)%[ ,]+([\d.]+)%\s*(?:[/,]\s*([\d.]+%?)\s*)?\)$/);
  if (m) {
    const [h, s, l] = [+m[1], +m[2] / 100, +m[3] / 100];
    const a = m[4] === undefined ? 1 : m[4].endsWith("%") ? +m[4].slice(0, -1) / 100 : +m[4];
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    const mm = l - c / 2;
    const [r, g, b] =
      h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
      : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return { r: r + mm, g: g + mm, b: b + mm, a };
  }
  m = v.match(/^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$/);
  if (m) {
    const n = parseInt(m[1], 16);
    return {
      r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255,
      a: m[2] ? parseInt(m[2], 16) / 255 : 1,
    };
  }
  m = v.match(/^#([0-9a-fA-F]{3})$/);
  if (m) {
    const [r, g, b] = m[1].split("").map((c) => parseInt(c + c, 16) / 255);
    return { r, g, b, a: 1 };
  }
  m = v.match(/^rgba?\(\s*([\d.]+)[ ,]+([\d.]+)[ ,]+([\d.]+)\s*(?:[/,]\s*([\d.]+)\s*)?\)$/);
  if (m) return { r: +m[1] / 255, g: +m[2] / 255, b: +m[3] / 255, a: m[4] === undefined ? 1 : +m[4] };
  return null;
}

const compositeOver = (fg, bg) => ({
  r: fg.a * fg.r + (1 - fg.a) * bg.r,
  g: fg.a * fg.g + (1 - fg.a) * bg.g,
  b: fg.a * fg.b + (1 - fg.a) * bg.b,
  a: 1,
});
const linear = (v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
const luminance = (c) => 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
function contrastRatio(fg, bg) {
  const [hi, lo] = [luminance(fg), luminance(bg)].sort((a, b) => b - a);
  return (hi + 0.05) / (lo + 0.05);
}

function resolveColor(token, map, theme, errs) {
  const raw = resolveValue(token, map);
  const col = raw === undefined ? null : parseColor(raw);
  if (!col) errs.push(`E5 app.css  ${token} (${theme}) does not resolve to a parseable color (got ${JSON.stringify(raw)})`);
  return col;
}

const contrastResults = []; // { theme, fg, bg, ratio, min, why }
function runContrast(errs) {
  for (const [theme, map] of [["light", lightTokens], ["dark", darkTokens]]) {
    for (const p of CONTRAST_PAIRS) {
      const fg = resolveColor(p.fg, map, theme, errs);
      let bg = resolveColor(p.bg, map, theme, errs);
      if (!fg || !bg) continue;
      if (p.over) {
        const over = resolveColor(p.over, map, theme, errs);
        if (!over) continue;
        bg = compositeOver(bg, over);
      } else if (bg.a < 1) {
        errs.push(`E5 app.css  pair ${p.fg}/${p.bg} (${theme}) has a translucent bg but no "over" surface declared`);
        continue;
      }
      const ratio = contrastRatio(compositeOver(fg, bg), bg);
      contrastResults.push({ theme, ...p, ratio });
      if (ratio < p.min) {
        errs.push(
          `E5 app.css  ${theme}: ${p.fg} on ${p.bg}${p.over ? ` over ${p.over}` : ""} = ${ratio.toFixed(2)}:1, ` +
            `needs ${p.min}:1 (${p.why})`,
        );
      }
    }
  }
}

// ── External-host lint (E7) ──────────────────────────────────────────────────
// Resource LOADS only — <a href> navigation is allowed. Covers load-bearing
// HTML elements, CSS url(...) and @import in all three surfaces.

function externalHostFindings(src, file, isHtml) {
  const out = [];
  if (isHtml) {
    for (const m of src.matchAll(/<(link|script|img|iframe|source|video|audio|embed|object)\b[^>]*/gi)) {
      const url = m[0].match(/\b(?:href|src|data)\s*=\s*["']((?:https?:)?\/\/[^"']+)["']/i);
      if (url) out.push({ file, line: lineOf(src, m.index), what: `<${m[1].toLowerCase()}> loads ${url[1]}` });
    }
  }
  for (const m of src.matchAll(/url\(\s*["']?\s*(?:https?:)?\/\//gi)) {
    out.push({ file, line: lineOf(src, m.index), what: "url() references an external host" });
  }
  for (const m of src.matchAll(/@import\b[^;\n]*?(?:https?:)?\/\//gi)) {
    out.push({ file, line: lineOf(src, m.index), what: "@import references an external host" });
  }
  return out;
}

// ── Evaluate ─────────────────────────────────────────────────────────────────

const errors = [];

for (const c of consumed) {
  if (!definedTokens.has(c.token)) {
    errors.push(`E1 ${c.file}:${c.line}  var(${c.token}) consumed but ${c.token} is not defined in app.css`);
  }
}

const hookHits = [];
const seenMissing = new Set();
for (const e of emitted) {
  if (cssClasses.has(e.cls)) continue;
  if (ALLOW_HOOK_CLASSES.includes(e.cls)) {
    hookHits.push(e);
    continue;
  }
  const key = `${e.cls}@${e.file}:${e.line}`;
  if (seenMissing.has(key)) continue;
  seenMissing.add(key);
  errors.push(`E2 ${e.file}:${e.line}  class "${e.cls}" is emitted but has no rule in app.css`);
}

for (const d of dynamicSites) {
  errors.push(`E3 ${d.file}:${d.line}  dynamic class composition with head "${d.head}" is not in ALLOW_PREFIXES`);
}

for (const b of badTokens) {
  errors.push(
    `E4 ${b.file}:${b.line}  class token ${JSON.stringify(b.tok)} cannot be statically parsed — ` +
      `rewrite the site in the single-quoted concat style (with an ALLOW_PREFIXES entry if dynamic)`,
  );
}

// E5 — the contrast manifest, both themes.
runContrast(errors);

// E8 — scoped-theme alias integrity. var() inside a custom property substitutes
// where the property is DECLARED, so a :root-only alias whose value references
// a token the dark block re-themes freezes the LIGHT value for any subtree that
// scopes [data-theme="dark"] onto a non-root element — which the styleguide's
// side-by-side panes do. Any such alias must be re-declared in the dark block.
// (Caught live: --destructive rendered the light danger inside the dark panes.)
for (const [name, value] of Object.entries(lightTokens)) {
  if (name in darkOverrides) continue;
  const themedRefs = [...value.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)\s*\)/g)]
    .map((m) => m[1])
    .filter((t) => t in darkOverrides);
  if (themedRefs.length) {
    errors.push(
      `E8 app.css  ${name} is declared only in :root but references dark-re-themed ` +
        `${themedRefs.join(", ")} — re-declare ${name} in the [data-theme="dark"] block ` +
        `or scoped-dark subtrees (styleguide panes) freeze the light value`,
    );
  }
}

// E6/R4 scan: raw color literals + raw px font-sizes outside the token blocks.
// Track whether each line sits inside the :root / [data-theme="dark"] token
// blocks (both are top-level).
const rawLiterals = [];
const pxFontSizes = []; // R4
{
  const lines = css.split("\n");
  let inTokenBlock = false;
  let depth = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Anchored: `[data-theme="dark"] .foo {` is a scoped RULE, not a token
    // block — only the bare block selectors mark token territory.
    if (depth === 0 && /^\s*(?::root|\[data-theme="dark"\])\s*\{\s*$/.test(line)) inTokenBlock = true;
    for (const ch of line) {
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) inTokenBlock = false;
      }
    }
    if (inTokenBlock) continue;
    // A color function whose first argument is var(--x) is consuming a token —
    // that IS the contract, not a raw literal (e.g. hsl(var(--warn-hsl) / 0.3)).
    const hits = line.match(/#[0-9a-fA-F]{3,8}\b|\b(?:hsla?|rgba?|oklch|color-mix)\((?!\s*(?:in\s+\w+\s*,\s*)?var\()/g);
    if (hits) rawLiterals.push({ line: i + 1, text: line.trim(), n: hits.length });
    // R4: px font sizes (font-size + the `font:` shorthand) not yet on the scale.
    if (/font-size:\s*[\d.]+px/.test(line) || /\bfont:\s*[^;]*\b[\d.]+px/.test(line)) {
      pxFontSizes.push({ line: i + 1, text: line.trim() });
    }
  }
}

// E6 — every raw-literal line must be a conscious ALLOW_RAW_COLORS entry.
const rawAllowed = [];
const staleRawAllows = new Set(ALLOW_RAW_COLORS.map((a) => a.line));
for (const r of rawLiterals) {
  const hit = ALLOW_RAW_COLORS.find((a) => a.line === r.text);
  if (hit) {
    rawAllowed.push({ ...r, why: hit.why });
    staleRawAllows.delete(hit.line);
  } else {
    errors.push(`E6 app.css:${r.line}  raw color literal outside the token blocks: ${r.text}`);
  }
}

// E7 — no external resource loads in the offline surfaces.
for (const f of [
  ...externalHostFindings(htmlRaw, "index.html", true),
  ...externalHostFindings(styleguideRaw, "styleguide.html", true),
  ...externalHostFindings(css, "app.css", false),
]) {
  errors.push(`E7 ${f.file}:${f.line}  ${f.what} — the console must render fully offline`);
}

// R2: defined-but-unconsumed tokens.
const consumedSet = new Set(consumed.map((c) => c.token));
const unconsumed = [...definedTokens].filter((t) => !consumedSet.has(t)).sort();

// ── Print ────────────────────────────────────────────────────────────────────

const uniqEmitted = new Set(emitted.map((e) => e.cls));
const uniqConsumed = new Set(consumed.map((c) => c.token));

for (const h of allowlistedHits) {
  console.log(`allow  ${h.file}:${h.line}  dynamic class head "${h.head}" (ALLOW_PREFIXES)`);
}
for (const h of hookHits) {
  console.log(`allow  ${h.file}:${h.line}  hook class "${h.cls}" (ALLOW_HOOK_CLASSES — no style rule by design)`);
}
for (const r of rawAllowed) {
  console.log(`allow  app.css:${r.line}  raw color (ALLOW_RAW_COLORS: ${r.why})`);
}
for (const s of staleRawAllows) {
  console.log(`stale  ALLOW_RAW_COLORS entry no longer matches any line — prune it: ${s}`);
}

// E5 summary: worst pair per theme, so drift toward the threshold is visible.
for (const theme of ["light", "dark"]) {
  const rows = contrastResults.filter((r) => r.theme === theme);
  if (!rows.length) continue;
  const worst = rows.reduce((a, b) => (a.ratio / a.min < b.ratio / b.min ? a : b));
  console.log(
    `\nE5 ${theme}: ${rows.length} contrast pairs checked; tightest = ${worst.fg} on ${worst.bg}` +
      `${worst.over ? ` over ${worst.over}` : ""} at ${worst.ratio.toFixed(2)}:1 (needs ${worst.min}:1 — ${worst.why})`,
  );
}
if (process.env.CSS_CHECK_VERBOSE) {
  for (const r of contrastResults) {
    console.log(
      `      ${r.theme.padEnd(5)} ${(r.ratio >= r.min ? "ok  " : "FAIL")} ${r.ratio.toFixed(2).padStart(6)}:1 ` +
        `(≥${r.min})  ${r.fg} on ${r.bg}${r.over ? ` over ${r.over}` : ""} — ${r.why}`,
    );
  }
}

if (unconsumed.length) {
  console.log(`\nR2  defined but not yet consumed: ${unconsumed.join(", ")}`);
}
if (REPORT_ONLY.length) {
  console.log(`\nR3  REPORT-ONLY (fix requires app.js — owned by another slice):`);
  for (const r of REPORT_ONLY) console.log(`      ${r}`);
}
if (pxFontSizes.length) {
  console.log(
    `\nR4  ${pxFontSizes.length} raw px font-size line(s) outside the token blocks ` +
      `(decision-24 sweep backlog; report-only). Set CSS_CHECK_VERBOSE=1 to list them.`,
  );
  if (process.env.CSS_CHECK_VERBOSE) {
    for (const p of pxFontSizes) console.log(`      app.css:${p.line}  ${p.text}`);
  }
}

console.log(
  `\n__css_check: ${uniqEmitted.size} classes checked, ${uniqConsumed.size} tokens checked, ` +
    `${contrastResults.length} contrast pairs, ${allowlistedHits.length + hookHits.length + rawAllowed.length} allowlisted, ` +
    `${errors.length} error(s)`,
);

if (errors.length) {
  console.error("");
  for (const e of errors) console.error("FAIL  " + e);
  process.exit(1);
}
