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
//
// REPORTS (printed, never exit-affecting — this wave polices by hand):
//   R1  raw color literals in app.css declarations outside the :root /
//       [data-theme="dark"] token blocks (candidates for tokenisation).
//   R2  tokens defined in app.css that nothing consumes yet.
//   R3  REPORT-ONLY: known violations whose fix would require editing app.js
//       (app.js is owned by another wave-1 slice — leave, don't touch).
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

// ── Read the tree ────────────────────────────────────────────────────────────

const cssRaw = read("app.css");
const jsRaw = read("app.js");
const htmlRaw = read("index.html");

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
const consumed = [
  ...consumedTokens(css, "app.css"),
  ...consumedTokens(jsRaw, "app.js"),
  ...consumedTokens(htmlRaw, "index.html"),
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

// ── Reports ──────────────────────────────────────────────────────────────────

// R1: raw color literals outside the token blocks. Track whether each line sits
// inside the :root / [data-theme="dark"] token blocks (both are top-level).
const rawLiterals = [];
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
  }
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

if (rawLiterals.length) {
  const total = rawLiterals.reduce((n, r) => n + r.n, 0);
  console.log(`\nR1  ${total} raw color literal(s) outside the token blocks (report-only this wave):`);
  for (const r of rawLiterals) console.log(`      app.css:${r.line}  ${r.text}`);
}
if (unconsumed.length) {
  console.log(`\nR2  defined but not yet consumed: ${unconsumed.join(", ")}`);
}
if (REPORT_ONLY.length) {
  console.log(`\nR3  REPORT-ONLY (fix requires app.js — owned by another slice):`);
  for (const r of REPORT_ONLY) console.log(`      ${r}`);
}

console.log(
  `\n__css_check: ${uniqEmitted.size} classes checked, ${uniqConsumed.size} tokens checked, ` +
    `${allowlistedHits.length + hookHits.length} allowlisted, ${errors.length} error(s)`,
);

if (errors.length) {
  console.error("");
  for (const e of errors) console.error("FAIL  " + e);
  process.exit(1);
}
