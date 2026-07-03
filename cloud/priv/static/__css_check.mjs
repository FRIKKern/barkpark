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
  "deploy-console",    // + (open ? "" : " is-collapsed")
  "tier",              // + " tier-current" / " tier-free" conditionals
  "auth-tab",          // /new auth tabs: + (mode ? " is-active" : "")
  "new-console",       // + (collapsed ? " is-collapsed" : "")
  "new-step ",         // + cls (done | active | failed)
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

/** Static class="..." attributes (HTML source — no dynamic parts). */
for (const m of htmlRaw.matchAll(/class="([^"]*)"/g)) {
  const line = lineOf(htmlRaw, m.index);
  for (const t of m[1].split(/\s+/).filter(Boolean)) {
    if (CLASS_TOKEN.test(t)) emitted.push({ cls: t, file: "index.html", line });
  }
}

/**
 * class="..." inside app.js string literals. The SPA builds HTML in
 * single-quoted concatenated strings, so a dynamic segment shows up as a
 * single-quote boundary inside the captured attribute value:
 *   class="dep-pill dep-' + esc(st) + '"   →  head "dep-pill dep-"
 * Complete tokens in the head are checked; the trailing partial token (if the
 * head does not end in whitespace) is the dynamic prefix, and the whole head
 * must be an ALLOW_PREFIXES entry.
 */
function handleClassValue(value, file, line) {
  const q = value.indexOf("'");
  if (q === -1) {
    for (const t of value.split(/\s+/).filter(Boolean)) {
      if (CLASS_TOKEN.test(t)) emitted.push({ cls: t, file, line });
    }
    return;
  }
  const head = value.slice(0, q);
  const parts = head.split(/\s+/).filter(Boolean);
  const endsComplete = /\s$/.test(head) || head === "";
  const complete = endsComplete ? parts : parts.slice(0, -1);
  for (const t of complete) {
    if (CLASS_TOKEN.test(t)) emitted.push({ cls: t, file, line });
  }
  if (ALLOW_PREFIXES.includes(head)) {
    allowlistedHits.push({ head, file, line });
  } else {
    dynamicSites.push({ head, file, line });
  }
}

for (const m of jsRaw.matchAll(/class="([^"]*)"/g)) {
  handleClassValue(m[1], "app.js", lineOf(jsRaw, m.index));
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
    if (depth === 0 && /^\s*(:root|\[data-theme="dark"\])\s*\{?/.test(line)) inTokenBlock = true;
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
