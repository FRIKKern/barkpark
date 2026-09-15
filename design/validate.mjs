#!/usr/bin/env node
// design/validate.mjs — proves design/tokens.json is well-formed and complete.
// Dependency-free (Node built-ins only). Exits non-zero with a clear message on
// any failure. This is the W1.1 completeness gate; W1.2 emitters trust it.
//
//   node design/validate.mjs
//
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const errors = [];
const ok = (cond, msg) => { if (!cond) errors.push(msg); };

// --- parse -----------------------------------------------------------------
const path = join(here, "tokens.json");
let raw, tokens;
try {
  raw = readFileSync(path, "utf8");
} catch (e) {
  console.error(`FAIL: cannot read ${path}: ${e.message}`);
  process.exit(1);
}
try {
  tokens = JSON.parse(raw);
} catch (e) {
  console.error(`FAIL: tokens.json is not valid JSON: ${e.message}`);
  process.exit(1);
}

const HSL = /^[0-9.]+ [0-9.]+% [0-9.]+%$/;
const HEX = /^#[0-9a-fA-F]{6}$/;
const CP = /^U\+[0-9A-F]{4,6}$/;
const hslPair = (o, where) => {
  ok(o && typeof o === "object", `${where}: missing`);
  if (!o) return;
  ok(HSL.test(o.light || ""), `${where}.light must be HSL channels 'H S% L%', got ${JSON.stringify(o.light)}`);
  ok(HSL.test(o.dark || ""), `${where}.dark must be HSL channels 'H S% L%', got ${JSON.stringify(o.dark)}`);
};

// --- top-level presence ----------------------------------------------------
for (const key of ["version", "meta", "color", "font", "type", "space", "radius", "elevation", "motion", "zIndex", "lifecycle"]) {
  ok(tokens[key] != null, `top-level key '${key}' is required`);
}
ok(/^\d+\.\d+\.\d+$/.test(tokens.version || ""), `version must be semver, got ${JSON.stringify(tokens.version)}`);
ok(tokens.meta && typeof tokens.meta.note === "string" && tokens.meta.note.length > 0, "meta.note (source-of-truth statement) is required");

// --- color roles -----------------------------------------------------------
const color = tokens.color || {};
for (const role of ["primary", "primary-hover", "primary-fg", "bg", "surface", "muted-surface", "text", "muted-text", "border", "ring", "accent", "reading-accent"]) {
  hslPair(color[role], `color.${role}`);
}

// --- status roles: ok/warn/danger/info, each light+dark --------------------
const status = color.status || {};
for (const role of ["ok", "warn", "danger", "info"]) {
  ok(status[role] != null, `color.status.${role} is required (the four semantic roles are wired in W1.3)`);
  hslPair(status[role], `color.status.${role}`);
}

// --- on-status foregrounds: ok-fg/warn-fg/danger-fg/info-fg (Studio-only) ----
const onStatus = color.onStatus || {};
for (const role of ["ok-fg", "warn-fg", "danger-fg", "info-fg"]) {
  ok(onStatus[role] != null, `color.onStatus.${role} is required (on-fill white foregrounds, Studio-only)`);
  hslPair(onStatus[role], `color.onStatus.${role}`);
}

// --- Studio zinc/chrome ladder: HSL channels OR a var(--role) reference -------
const HSL_OR_VAR = /^([0-9.]+ [0-9.]+% [0-9.]+%|var\(--[a-z-]+\))$/;
const chrome = color.studioChrome || {};
for (const role of ["bg-accent", "border-muted", "fg-dim", "fg-accent"]) {
  const o = chrome[role];
  ok(o && typeof o === "object", `color.studioChrome.${role} is required (Studio zinc alias)`);
  if (o) {
    ok(HSL_OR_VAR.test(o.light || ""), `color.studioChrome.${role}.light must be HSL channels or var(--role), got ${JSON.stringify(o.light)}`);
    ok(HSL_OR_VAR.test(o.dark || ""), `color.studioChrome.${role}.dark must be HSL channels or var(--role), got ${JSON.stringify(o.dark)}`);
  }
}

// --- code-block tones (color.code): mint fg/bg hex pairs, direct ------------
const code = color.code || {};
for (const sub of ["fg", "bg"]) {
  const o = code[sub];
  ok(o && typeof o === "object", `color.code.${sub} is required (paper code-block tone)`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.code.${sub}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.code.${sub}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}

// --- verdict accents (color.verdict): 2 semantic roles, each ink + soft ------
// The pair must ship COMPLETE — an ink with no soft ground is a callout with a
// rail and no wash, and a soft with no ink is a wash with nothing on it. Both
// halves of both roles, both modes, hex.
const verdict = color.verdict || {};
for (const role of ["loss", "loss-soft", "peace", "peace-soft"]) {
  const o = verdict[role];
  ok(o && typeof o === "object", `color.verdict.${role} is required (the verdict pair ships ink + soft, both roles)`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.verdict.${role}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.verdict.${role}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}

// --- neutral callout tone (color.cliCalloutNeutral): pdrender-only hex pair ---
const calloutNeutral = color.cliCalloutNeutral || {};
ok(HEX.test(calloutNeutral.light || ""), `color.cliCalloutNeutral.light must be #rrggbb, got ${JSON.stringify(calloutNeutral.light)}`);
ok(HEX.test(calloutNeutral.dark || ""), `color.cliCalloutNeutral.dark must be #rrggbb, got ${JSON.stringify(calloutNeutral.dark)}`);

// --- CLI/TUI chrome roles (color.cliChrome): 9 NEW hex pairs + 5 var refs -----
const cliChrome = color.cliChrome || {};
const CLI_NEW = ["chrome-accent", "chrome-dim", "chrome-ink", "chrome-text-secondary",
  "chrome-selection-bg", "chrome-selection-fg", "chrome-field-border", "chrome-toolbar-bg", "chrome-cursor-bg"];
const CLI_REUSE = { "chrome-border": "var(--border)", "chrome-border-active": "var(--info)",
  "chrome-label": "var(--muted-text)", "chrome-primary-cta": "var(--primary)", "chrome-on-primary": "var(--primary-fg)" };
for (const role of CLI_NEW) {
  const o = cliChrome[role];
  ok(o && typeof o === "object", `color.cliChrome.${role} is required (new CLI chrome hex role)`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.cliChrome.${role}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.cliChrome.${role}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}
for (const [role, ref] of Object.entries(CLI_REUSE)) {
  ok(cliChrome[role] === ref, `color.cliChrome.${role} must be the reuse reference ${ref} (reuse-not-mint), got ${JSON.stringify(cliChrome[role])}`);
}

// --- categorical palettes: presence + sheet CF (hex value lists) -------------
const hexList = (arr, where, len) => {
  ok(Array.isArray(arr) && arr.length === len, `${where} must be a ${len}-hex array, got ${JSON.stringify(arr)}`);
  if (Array.isArray(arr)) arr.forEach((h, i) => ok(HEX.test(h), `${where}[${i}] must be #rrggbb, got ${JSON.stringify(h)}`));
};
hexList((color.presence || {}).palette, "color.presence.palette", 8);
hexList((color.sheetCf || {}).background, "color.sheetCf.background", 6);
hexList((color.sheetCf || {}).tab, "color.sheetCf.tab", 6);

// --- categorical spectrum: match-quality (7 ordered HSL-channel stops) --------
// A decorative data-viz gradient (fuzzy→exact), stored as HSL channels (feeds a
// CSS linear-gradient, never compared for equality — unlike the hex palettes).
const hslList = (arr, where, len) => {
  ok(Array.isArray(arr) && arr.length === len, `${where} must be a ${len}-entry HSL-channel array, got ${JSON.stringify(arr)}`);
  if (Array.isArray(arr)) arr.forEach((h, i) => ok(HSL.test(h), `${where}[${i}] must be HSL channels 'H S% L%', got ${JSON.stringify(h)}`));
};
hslList((color.matchQuality || {}).spectrum, "color.matchQuality.spectrum", 7);

// --- paper reading-surface skin (color.paper): hex OR rgba() values ---------
// surface = {light,dark} per role; reader.light / reader.dark = flat theme maps
// (the reader diverges on --paper-rule + re-skins ink-faint/chrome-* on dark).
const HEX_OR_RGBA = /^(#[0-9a-fA-F]{6}|rgba?\([0-9]{1,3},\s*[0-9]{1,3},\s*[0-9]{1,3}(,\s*[0-9.]+)?\))$/;
const paper = color.paper || {};
const psurf = paper.surface || {};
for (const role of ["bg", "bg-deep", "ink", "ink-soft", "ink-faint", "rule", "edit-hover", "accent", "accent-soft", "chrome-bg", "chrome-border"]) {
  const o = psurf[role];
  ok(o && typeof o === "object", `color.paper.surface.${role} is required`);
  if (o) {
    ok(HEX_OR_RGBA.test(o.light || ""), `color.paper.surface.${role}.light must be #rrggbb or rgba(), got ${JSON.stringify(o.light)}`);
    ok(HEX_OR_RGBA.test(o.dark || ""), `color.paper.surface.${role}.dark must be #rrggbb or rgba(), got ${JSON.stringify(o.dark)}`);
  }
}
const preadLight = (paper.reader || {}).light || {};
ok((paper.reader || {}).light && typeof (paper.reader || {}).light === "object", "color.paper.reader.light is required");
for (const role of ["bg", "bg-deep", "ink", "ink-soft", "rule", "accent", "accent-soft"]) {
  ok(HEX_OR_RGBA.test(preadLight[role] || ""), `color.paper.reader.light.${role} must be #rrggbb or rgba(), got ${JSON.stringify(preadLight[role])}`);
}
const preadDark = (paper.reader || {}).dark || {};
ok((paper.reader || {}).dark && typeof (paper.reader || {}).dark === "object", "color.paper.reader.dark is required");
for (const role of ["bg", "bg-deep", "ink", "ink-soft", "rule", "accent", "accent-soft", "ink-faint", "chrome-bg", "chrome-border"]) {
  ok(HEX_OR_RGBA.test(preadDark[role] || ""), `color.paper.reader.dark.${role} must be #rrggbb or rgba(), got ${JSON.stringify(preadDark[role])}`);
}

// --- mail-client popup chrome (color.mailChrome): 6 hex pairs ----------------
const mailChrome = color.mailChrome || {};
for (const role of ["paper", "bar", "rule", "ink", "soft", "accent"]) {
  const o = mailChrome[role];
  ok(o && typeof o === "object", `color.mailChrome.${role} is required`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.mailChrome.${role}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.mailChrome.${role}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}

// --- paper email skin (color.paperEmail): 8 single light-only hex ------------
// The email surface has no dark mode — one hex per role, not a {light,dark} pair.
const paperEmail = color.paperEmail || {};
for (const role of ["brand", "brand-text", "rule", "page-bg", "paper", "text", "muted", "code-bg"]) {
  ok(HEX.test(paperEmail[role] || ""), `color.paperEmail.${role} must be #rrggbb, got ${JSON.stringify(paperEmail[role])}`);
}

// --- paper callout tones (color.paperCallout): light+dark, 5 {bg,fg} hex pairs -
const paperCallout = color.paperCallout || {};
for (const theme of ["light", "dark"]) {
  const tset = paperCallout[theme] || {};
  ok(paperCallout[theme] && typeof paperCallout[theme] === "object", `color.paperCallout.${theme} is required`);
  for (const tone of ["success", "warning", "danger", "info", "neutral"]) {
    const o = tset[tone];
    ok(o && typeof o === "object", `color.paperCallout.${theme}.${tone} is required`);
    if (o) {
      ok(HEX.test(o.bg || ""), `color.paperCallout.${theme}.${tone}.bg must be #rrggbb, got ${JSON.stringify(o.bg)}`);
      ok(HEX.test(o.fg || ""), `color.paperCallout.${theme}.${tone}.fg must be #rrggbb, got ${JSON.stringify(o.fg)}`);
    }
  }
}

// --- provider identity marks (color.provider): hex pairs --------------------
const provider = color.provider || {};
for (const role of ["hetzner", "azure"]) {
  const o = provider[role];
  ok(o && typeof o === "object", `color.provider.${role} is required`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.provider.${role}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.provider.${role}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}

// --- cloudChrome shell vocabulary (color.cloudChrome): identity-INVARIANT ----
// passthrough (GR2). Most roles are {light,dark} HEX; line-rgb is an "R,G,B"
// border triplet. A new family is otherwise validated by NOTHING, so this gates
// its shape. GR29/GR37 (gr-p4-hygiene): 13 HEX roles — the 11 zero-consumer roles
// (azure/backdrop/blue-hover/cloudflare/fg5/github/hetzner/on-red/spark-dim/
// toast/toast-fg) are retired here IN LOCKSTEP with tokens.json + emit.mjs
// CC_ROLES (this list is the gate that gr-p3 lacked, which reverted the retire).
const cloudChrome = color.cloudChrome || {};
const CC_HEX_ROLES = [
  "bg", "bg-side", "card", "card2", "modal",
  "fg", "fg2", "fg3", "fg4",
  "red", "red-strong", "blue", "amber",
];
for (const role of CC_HEX_ROLES) {
  const o = cloudChrome[role];
  ok(o && typeof o === "object", `color.cloudChrome.${role} is required`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.cloudChrome.${role}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.cloudChrome.${role}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}
const RGB_TRIPLET = /^\d{1,3},\d{1,3},\d{1,3}$/;
for (const theme of ["light", "dark"]) {
  ok(RGB_TRIPLET.test((cloudChrome["line-rgb"] || {})[theme] || ""), `color.cloudChrome.line-rgb.${theme} must be an "R,G,B" triplet, got ${JSON.stringify((cloudChrome["line-rgb"] || {})[theme])}`);
}

// --- auth button fills (color.authButton): HSL channels OR var(--role) -------
const authButton = color.authButton || {};
for (const role of ["bg", "fg", "bgHover"]) {
  const o = authButton[role];
  ok(o && typeof o === "object", `color.authButton.${role} is required`);
  if (o) {
    ok(HSL_OR_VAR.test(o.light || ""), `color.authButton.${role}.light must be HSL channels or var(--role), got ${JSON.stringify(o.light)}`);
    ok(HSL_OR_VAR.test(o.dark || ""), `color.authButton.${role}.dark must be HSL channels or var(--role), got ${JSON.stringify(o.dark)}`);
  }
}

// --- status page chrome (color.statusChrome): 5 hex pairs -------------------
const statusChrome = color.statusChrome || {};
for (const role of ["bg", "fg", "muted", "card", "line"]) {
  const o = statusChrome[role];
  ok(o && typeof o === "object", `color.statusChrome.${role} is required`);
  if (o) {
    ok(HEX.test(o.light || ""), `color.statusChrome.${role}.light must be #rrggbb, got ${JSON.stringify(o.light)}`);
    ok(HEX.test(o.dark || ""), `color.statusChrome.${role}.dark must be #rrggbb, got ${JSON.stringify(o.dark)}`);
  }
}

// --- status page health tones (color.statusHealth): 5 single hex ------------
const statusHealth = color.statusHealth || {};
for (const role of ["operational", "degraded", "partial_outage", "major_outage", "unknown"]) {
  ok(HEX.test(statusHealth[role] || ""), `color.statusHealth.${role} must be #rrggbb, got ${JSON.stringify(statusHealth[role])}`);
}

// --- fleet listener-status tones (color.fleetStatus): 5 single hex ----------
const fleetStatus = color.fleetStatus || {};
for (const role of ["working", "idle", "blocked", "provisioning", "offline"]) {
  ok(HEX.test(fleetStatus[role] || ""), `color.fleetStatus.${role} must be #rrggbb, got ${JSON.stringify(fleetStatus[role])}`);
}

// --- error page palette (color.errorPage): 3 single fixed-dark hex ----------
// Intentionally NON-theme-aware (a stark always-dark error card) — one hex each.
const errorPage = color.errorPage || {};
for (const role of ["bg", "fg", "muted"]) {
  ok(HEX.test(errorPage[role] || ""), `color.errorPage.${role} must be #rrggbb, got ${JSON.stringify(errorPage[role])}`);
}

// --- sheets reader info-blue (color.readerInfo): single hex pair ------------
const readerInfo = color.readerInfo || {};
ok(HEX.test(readerInfo.light || ""), `color.readerInfo.light must be #rrggbb, got ${JSON.stringify(readerInfo.light)}`);
ok(HEX.test(readerInfo.dark || ""), `color.readerInfo.dark must be #rrggbb, got ${JSON.stringify(readerInfo.dark)}`);

// --- font ------------------------------------------------------------------
const font = tokens.font || {};
ok(font.chrome && font.chrome.selfHosted === true, "font.chrome.selfHosted must be true (Inter is self-hosted)");
ok(font.chrome && typeof font.chrome.woff2 === "string" && font.chrome.woff2.endsWith(".woff2"), "font.chrome.woff2 path is required");
ok(font.chrome && Array.isArray(font.chrome.weightRange) && font.chrome.weightRange.length === 2, "font.chrome.weightRange must be [min,max]");
for (const f of ["chrome", "mono", "reading"]) {
  ok(font[f] && typeof font[f].stack === "string" && font[f].stack.length > 0, `font.${f}.stack is required`);
}

// --- type scales -----------------------------------------------------------
const type = tokens.type || {};
// Every chrome step carries size + lineHeight + WEIGHT. The weight is required
// (not optional like type.reading's per-step override): the chrome ladder is a
// UI voice ladder, and a step whose size is emitted while its weight is not is
// exactly the hole that let web/components/styleguide.tsx hand-keep a parallel
// 700/700/600/400/400/400 column beside this file (au-r4-web-type-ladder).
const CHROME_WEIGHT_RANGE = (tokens.font && tokens.font.chrome && tokens.font.chrome.weightRange) || [100, 900];
// CHROME_ORDER is DERIVED from tokens.type.chrome, ASCENDING BY SIZE — it used to be
//
//     const CHROME_ORDER = ["3xs","2xs","xs","sm","base","lg","xl","2xl"];
//
// a hand copy of the very object the two loops below validate. A gate that walks a
// hand copy and looks each of ITS OWN entries up in the source can only fail in one
// direction: a rung added to tokens.json and not to the literal was NEVER VALIDATED —
// no {size,lineHeight}, no weight, no place in the monotonicity chain — and this file
// still exited 0 without ever naming it. PR #18275 fixed the SAME shape one file over
// (emit.mjs TYPE_STEPS, now typeLadderFrom) and did not reach here; this is that fix's
// other half, and adjudication (1) in the CROSS-FILE LADDER CENSUS at the bottom of
// this file explains why the two derivations are deliberately not shared.
//
// DIRECTION. emit.mjs derives the same ladder DESCENDING (display order, largest →
// smallest); this file needs ASCENDING, because the monotonic-weight chain below reads
// "as the ladder gets LARGER it must not get LIGHTER". Same fact, opposite traversal —
// so neither list can be pasted into the other and no third copy is created either.
//
// AND IT REFUSES RATHER THAN GOING BLIND. A derivation that hands back [] would leave
// both loops iterating nothing and this whole section would pass vacuously — the exact
// defect being removed, re-entered through the fix. Every way of seeing nothing (a
// missing family, a non-object family, zero rungs, or two rungs of the same size, which
// does not name ONE order) records a REFUSING TO MEASURE error, so the exit is non-zero
// and the reason is named.
const LADDER_REFUSE = "REFUSING TO MEASURE";
function chromeLadderAscending(block) {
  if (!block || typeof block !== "object")
    return { err: `${LADDER_REFUSE} — type.chrome is missing or is not an object; the chrome ladder below would be validated against nothing` };
  // A rung is an entry carrying a finite positive `size`; `_note` prose is not one.
  const steps = Object.entries(block)
    .filter(([k]) => !k.startsWith("_"))
    .map(([k, v]) => [k, v && v.size])
    .filter(([, size]) => typeof size === "number" && Number.isFinite(size) && size > 0);
  if (steps.length === 0)
    return { err: `${LADDER_REFUSE} — derived ZERO rungs from type.chrome; every chrome ladder assertion below would pass vacuously` };
  if (new Set(steps.map(([, size]) => size)).size !== steps.length)
    return { err: `${LADDER_REFUSE} — type.chrome has two rungs of the same size, so "smallest → largest" does not name one order` };
  return { order: steps.slice().sort((a, b) => a[1] - b[1]).map(([k]) => k) };
}
const chromeLadder = chromeLadderAscending(type.chrome);
ok(!chromeLadder.err, chromeLadder.err);
const CHROME_ORDER = chromeLadder.order || [];
for (const step of CHROME_ORDER) {
  const s = (type.chrome || {})[step];
  ok(s && typeof s.size === "number" && typeof s.lineHeight === "number", `type.chrome.${step} needs {size,lineHeight}`);
  ok(
    s && Number.isInteger(s.weight) && s.weight >= CHROME_WEIGHT_RANGE[0] && s.weight <= CHROME_WEIGHT_RANGE[1],
    `type.chrome.${step}.weight must be an integer inside font.chrome.weightRange [${CHROME_WEIGHT_RANGE.join(", ")}]`,
  );
}
// The chrome ladder must never get LIGHTER as it gets larger. A 26px step set
// below the 14px body weight is not a scale, it is a typo — and because the
// styleguide renders straight off these numbers, the typo would ship as the spec.
for (let i = 1; i < CHROME_ORDER.length; i++) {
  const prev = (type.chrome || {})[CHROME_ORDER[i - 1]] || {};
  const cur = (type.chrome || {})[CHROME_ORDER[i]] || {};
  ok(
    cur.weight >= prev.weight,
    `type.chrome.${CHROME_ORDER[i]}.weight (${cur.weight}) is lighter than the smaller step ${CHROME_ORDER[i - 1]} (${prev.weight}); the chrome ladder is monotonic in weight`,
  );
}
for (const step of ["body", "h1", "h2", "h3"]) {
  const s = (type.reading || {})[step];
  ok(s && typeof s.size === "number" && typeof s.lineHeight === "number", `type.reading.${step} needs {size,lineHeight}`);
}
ok(type.reading && type.reading.headingWeight === 600, "type.reading.headingWeight must be 600");
// The EDITORIAL SCALE floor. A reading scale whose display size barely clears
// its prose reads as a memo, not a paper — the reader shipped h1 32 over body
// 18 (1.78) until pe-w1-reader-editorial-typography. Floor the ratio here so the
// scale cannot drift flat again without someone deciding to.
if (type.reading && type.reading.h1 && type.reading.body) {
  const ratio = type.reading.h1.size / type.reading.body.size;
  ok(ratio >= 2.0, `type.reading h1/body is ${ratio.toFixed(2)}; the editorial scale floor is 2.0`);
}
// Tracking is optional per step, but when present it is an em number — the
// emitter appends the unit, so a string here would emit `-0.02emem`.
for (const step of ["body", "h1", "h2", "h3"]) {
  const ls = ((type.reading || {})[step] || {}).letterSpacing;
  ok(ls === undefined || typeof ls === "number", `type.reading.${step}.letterSpacing must be a number (em)`);
}
// A per-step weight is optional too (device 3, charter D29) — the SHARED
// headingWeight above stays pinned at 600 and never moves; a step that wants its
// own voice declares `weight` and the emitter hands it out as
// --tok-reading-<step>-weight. An integer on the CSS 100–900 ladder: the
// reading stack is static system serifs, so anything off the ladder would snap
// to a face the author did not pick.
for (const step of ["body", "h1", "h2", "h3"]) {
  const w = ((type.reading || {})[step] || {}).weight;
  ok(
    w === undefined || (Number.isInteger(w) && w >= 100 && w <= 900),
    `type.reading.${step}.weight must be an integer 100–900 (CSS font-weight ladder) when present`,
  );
}

// --- scalar ladders --------------------------------------------------------
for (const k of ["1", "2", "3", "4", "5", "6", "7", "8"]) {
  ok(typeof (tokens.space || {})[k] === "number", `space.${k} is required (px)`);
}
// space.air — the reader's EVIDENCE beat scale, stored as ratios of `beat`.
// Two floors, both of which encode the law rather than the numbers:
//   1. every step is a real OPENING — >= 1.0x the artifact's air unit. A step below 1
//      would make an evidence block sit TIGHTER than two paragraphs, which is the
//      exact defect this scale exists to fix (the reader's table opened at 0px).
//   2. the ladder is MONOTONIC in the documented order, so the heavier a block is
//      the more room it takes. Flattening it is a decision, not a typo.
const AIR_LADDER = ["code", "table", "asciicast", "callout", "stats", "figure"];
const air = (tokens.space || {}).air || {};
ok(typeof air.beat === "number" && air.beat > 0, "space.air.beat is required (px, the ARTIFACT's air unit the scale is a ratio of \u2014 not the reader's prose beat, which is --bp-para-margin-top; ruled 2026-09-02)");
let prevAir = 0;
for (const k of AIR_LADDER) {
  const v = air[k];
  ok(typeof v === "number", `space.air.${k} is required (a ratio of space.air.beat)`);
  if (typeof v !== "number") continue;
  ok(v >= 1.0, `space.air.${k} is ${v}; an evidence block must open at or above the artifact's air unit (1.0x)`);
  ok(v >= prevAir, `space.air ladder is not monotonic: ${k} (${v}) opens tighter than the step before it (${prevAir})`);
  prevAir = v;
}
for (const k of Object.keys(air)) {
  if (k === "_note" || k === "beat") continue;
  ok(AIR_LADDER.includes(k), `space.air.${k} is not on the emitted ladder — a token with no consumer is the drift this gate exists to catch; add it to AIR_STEPS in design/emit.mjs and to AIR_LADDER here, or delete it`);
}

// space.section — the boundary between two sections of a paper: the air that ends
// one (a ratio of the same `space.air.beat` the evidence ladder hangs off) and the
// rule + gap that open the next. Three floors, each the LAW rather than the number:
//   1. `beat` clears the heaviest evidence step. A section boundary that opened
//      tighter than a figure would rank a picture above a whole argument — and it
//      is the failure this token was added to fix (h2 opened at 1.9em = 51.3px,
//      BELOW figure's 1.82x = 40px only because the h2 is bigger than a paragraph;
//      measured against the same beat it was barely twice a paragraph's air).
//   2. `rule >= 1` — a zero-width rule leaves the token emitted, consumed and
//      INVISIBLE: the shape that looks single-sourced until you photograph it.
//   3. `gap >= rule` — the words must sit further from the rule than the rule is
//      thick, or the head reads as underlined text rather than a ruled opening.
const SECTION_KEYS = ["beat", "rule", "gap"];
const sec = (tokens.space || {}).section || {};
for (const k of SECTION_KEYS) {
  ok(typeof sec[k] === "number" && sec[k] > 0, `space.section.${k} is required (a positive number)`);
}
for (const k of Object.keys(sec)) {
  if (k === "_note") continue;
  ok(SECTION_KEYS.includes(k), `space.section.${k} is not emitted — a token with no consumer is the drift this gate exists to catch; add it to SECTION_KEYS in design/emit.mjs + check.mjs Part L, or delete it`);
}
if (SECTION_KEYS.every((k) => typeof sec[k] === "number")) {
  const heaviestAir = Math.max(...AIR_LADDER.map((k) => air[k] || 0));
  ok(
    sec.beat > heaviestAir,
    `space.section.beat is ${sec.beat}x but the heaviest evidence step opens at ${heaviestAir}x; a section boundary must out-air every block INSIDE a section, or the reader cannot tell an argument ended from a figure starting`,
  );
  ok(sec.rule >= 1, `space.section.rule is ${sec.rule}px; below 1 the rule is emitted, consumed and invisible — the air would be doing the whole job alone`);
  ok(sec.gap >= sec.rule, `space.section.gap is ${sec.gap}px against a ${sec.rule}px rule; the head's words must clear the rule by more than its own thickness or it reads as underlined text`);
}

// space.rule — the OTHER rung of the same ladder: the weight every horizontal
// line that is not a section boundary draws at. One floor, and it is the whole
// point of naming the weight at all: a hairline that grows to meet the
// structural rule does not make the page louder, it makes the SECTION BOUNDARY
// mean nothing, because weight stops distinguishing structure from chrome. The
// benchmark artifact keeps the gap at exactly 2:1 (2px sec-head over 1px
// everything); this floors the ORDER and leaves the ratio to taste.
const RULE_KEYS = ["hairline"];
const rul = (tokens.space || {}).rule || {};
for (const k of RULE_KEYS) {
  ok(typeof rul[k] === "number" && rul[k] > 0, `space.rule.${k} is required (a positive number of pixels)`);
}
for (const k of Object.keys(rul)) {
  if (k === "_note") continue;
  ok(RULE_KEYS.includes(k), `space.rule.${k} is not emitted — a token with no consumer is the drift this gate exists to catch; add it to RULE_KEYS in design/emit.mjs + check.mjs Part M, or delete it`);
}
if (typeof rul.hairline === "number" && typeof sec.rule === "number") {
  ok(
    sec.rule > rul.hairline,
    `space.rule.hairline is ${rul.hairline}px against a ${sec.rule}px space.section.rule; a chrome line that weighs as much as a section boundary does not make the page louder — it makes the boundary stop meaning anything, because weight is the only thing separating structure from chrome`,
  );
}

// space.evidence — the width a block that improves with width may claim when it
// steps OUT of the prose column. Four floors, each encoding the LAW rather than
// the number, so a band that has quietly stopped being a band reds here:
//   1. `bandMax > band` — the wide step must actually be wider. A flattened pair
//      leaves the growth clause emitted, consumed, and inert: the shape that
//      looks single-sourced and honoured until you measure at two widths.
//   2. `0 < fill < 1` — the band is a FRACTION of the available inline space. At
//      1 the evidence would eat the whole viewport and the gutters would be the
//      only thing left holding the page together.
//   3. `band / fill > band + 2 * gutter` — the viewport at which the band starts
//      GROWING must be wider than the one at which it first fits. Violate it and
//      the band overshoots its own base before ever sitting at it, so the
//      artifact-sourced `band` literal would never be observable on any screen.
//   4. `gutter >= 16` — the band must never reach the viewport edge, and the
//      gutter is also what keeps a classic scrollbar (~15px) out of the 100cqw
//      the width is computed from. Below 16 the page can scroll sideways.
const EVIDENCE_KEYS = ["band", "bandMax", "fill", "gutter", "caption"];
const ev = (tokens.space || {}).evidence || {};
for (const k of EVIDENCE_KEYS) {
  ok(typeof ev[k] === "number" && ev[k] > 0, `space.evidence.${k} is required (a positive number)`);
}
for (const k of Object.keys(ev)) {
  if (k === "_note") continue;
  ok(EVIDENCE_KEYS.includes(k), `space.evidence.${k} is not emitted — a token with no consumer is the drift this gate exists to catch; add it to design/emit.mjs + check.mjs Part K, or delete it`);
}
if (EVIDENCE_KEYS.every((k) => typeof ev[k] === "number")) {
  ok(ev.bandMax > ev.band, `space.evidence.bandMax (${ev.bandMax}) must exceed band (${ev.band}); an equal pair makes the wide step inert and the band stops growing with the screen`);
  ok(ev.fill > 0 && ev.fill < 1, `space.evidence.fill is ${ev.fill}; the band is a fraction of the available inline space and must sit strictly between 0 and 1`);
  ok(
    ev.band / ev.fill > ev.band + 2 * ev.gutter,
    `space.evidence: growth begins at ${Math.round(ev.band / ev.fill)}px (band/fill) but the band already fits at ${ev.band + 2 * ev.gutter}px (band + 2*gutter); the ${ev.band}px base would never be observable at any width`,
  );
  ok(ev.gutter >= 16, `space.evidence.gutter is ${ev.gutter}px; below 16 the band can reach the viewport edge and 100cqw's scrollbar allowance disappears — the page scrolls sideways`);
  ok(ev.caption >= 45 && ev.caption <= 85, `space.evidence.caption is ${ev.caption}ch; a caption inside a wide figure is prose and must stay inside the editorial measure band (45-85 characters)`);
}

for (const k of ["sm", "base", "lg", "pill"]) {
  ok(typeof (tokens.radius || {})[k] === "number", `radius.${k} is required`);
}
for (const k of ["0", "1", "2", "3"]) {
  ok(typeof (tokens.elevation || {})[k] === "string", `elevation.${k} is required`);
}
for (const k of ["dur-1", "dur-2", "dur-3", "ease"]) {
  ok((tokens.motion || {})[k] != null, `motion.${k} is required`);
}
for (const k of ["tabnav", "topbar", "menu", "modal", "toast"]) {
  ok(typeof (tokens.zIndex || {})[k] === "number", `zIndex.${k} is required`);
}

// --- lifecycle: every required state present, reconciled with Go source ----
const life = tokens.lifecycle || {};
// REQUIRED_LIFE is DERIVED from design/status-manifest.json .statuses — the same
// single source scripts/status-manifest-check.sh Part 5 reads — NOT a hardcoded
// literal. A hardcoded closed list silently SKIPS a state added to the manifest
// but never wired here (charter D10(a): "a closed list that silently skips new
// states today"); deriving it makes that omission red instead. Proved able to
// fail by mutation in design/validate-life-fence.test.mjs.
const manifestPath = join(here, "status-manifest.json");
let manifest;
try {
  manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
} catch (e) {
  console.error(`FAIL: cannot read/parse ${manifestPath}: ${e.message}`);
  process.exit(1);
}
const REQUIRED_LIFE = Object.keys((manifest && manifest.statuses) || {});
ok(REQUIRED_LIFE.length > 0,
  `status-manifest.json .statuses is empty or missing — the lifecycle half of this gate would check NOTHING (a vacuous pass); it is the single source for the required state set`);
// role reconciled 1:1 with internal/semrole/semrole.go taskLifecycleRoles.
// considering + researching are the pre-open thought states (task-lifecycle-
// visibility epic): both neutral-role ('') — the dotted circle (considering) and
// the violet bullseye (researching) are glyph/hue voices, NOT semantic status
// roles (there is no violet status token), exactly as ready/open/cancelled carry
// a bespoke hue at role ''.
const EXPECTED_ROLE = {
  in_progress: "info", blocked: "warn", done: "ok", closed: "ok",
  cancelled: "", ready: "", open: "", considering: "", researching: "",
};
// Two-directional wiring ratchet on EXPECTED_ROLE. Deriving the SET from the
// manifest is only half the fix: the semantic role of a state is a judgement the
// manifest does not carry (its `roles` vocabulary is glyph roles — "progress",
// "cancel" — not semrole's ok/info/warn/danger/''), so EXPECTED_ROLE stays a
// hand-written map. These two loops make an UNWIRED map an error rather than an
// undefined-comparison accident, in both directions.
for (const state of REQUIRED_LIFE) {
  ok(Object.prototype.hasOwnProperty.call(EXPECTED_ROLE, state),
    `lifecycle.${state} is in design/status-manifest.json .statuses but design/validate.mjs EXPECTED_ROLE does not map it — wire the new state's semrole role here (and add lifecycle.${state} to design/tokens.json + internal/semrole)`);
}
for (const state of Object.keys(EXPECTED_ROLE)) {
  ok(REQUIRED_LIFE.includes(state),
    `design/validate.mjs EXPECTED_ROLE maps lifecycle.${state}, which design/status-manifest.json .statuses no longer lists — a stale expectation for a retired state; drop it here or restore it in the manifest`);
}
for (const state of REQUIRED_LIFE) {
  const e = life[state];
  if (e == null) { errors.push(`lifecycle.${state} is required`); continue; }
  ok(typeof e.role === "string" && ["ok", "info", "warn", "danger", ""].includes(e.role), `lifecycle.${state}.role must be a semantic role or ''`);
  ok(e.role === EXPECTED_ROLE[state], `lifecycle.${state}.role must be '${EXPECTED_ROLE[state]}' to match internal/semrole (got ${JSON.stringify(e.role)})`);
  ok(typeof e.glyph === "string" && e.glyph.length > 0, `lifecycle.${state}.glyph is required`);
  ok(CP.test(e.codepoint || ""), `lifecycle.${state}.codepoint must be 'U+XXXX', got ${JSON.stringify(e.codepoint)}`);
  ok(typeof e.asciiGlyph === "string" && e.asciiGlyph.length > 0, `lifecycle.${state}.asciiGlyph is required`);
  ok(e.color && HEX.test(e.color.light || ""), `lifecycle.${state}.color.light must be #rrggbb, got ${JSON.stringify(e.color && e.color.light)}`);
  ok(e.color && HEX.test(e.color.dark || ""), `lifecycle.${state}.color.dark must be #rrggbb, got ${JSON.stringify(e.color && e.color.dark)}`);
}
// in_progress carries the 10 braille frames (spinner.go)
ok(Array.isArray(life.in_progress && life.in_progress.frames) && life.in_progress.frames.length === 10, "lifecycle.in_progress.frames must list the 10 braille codepoints");
if (Array.isArray(life.in_progress && life.in_progress.frames)) {
  life.in_progress.frames.forEach((f, i) => ok(CP.test(f), `lifecycle.in_progress.frames[${i}] must be a codepoint, got ${JSON.stringify(f)}`));
}
// done teal must stay the deliberate teal literals, NOT the status.ok green.
// (status.ok is HSL channels and done.color is hex, so a cross-format equality
// would be vacuously false and never fire — pin the known teal hex instead so a
// regression that overwrites done with the ok green is actually caught.)
ok(life.done && life.done.color && life.done.color.light === "#0d9488",
  `lifecycle.done.color.light must stay teal #0d9488 (distinct from status.ok green), got ${JSON.stringify(life.done && life.done.color && life.done.color.light)}`);
ok(life.done && life.done.color && life.done.color.dark === "#2dd4bf",
  `lifecycle.done.color.dark must stay teal #2dd4bf (distinct from status.ok green), got ${JSON.stringify(life.done && life.done.color && life.done.color.dark)}`);


// --- CROSS-FILE LADDER CENSUS ----------------------------------------------
// WHY THIS EXISTS. design/emit.mjs and this file each carry hand-kept lists of
// the same token vocabularies. PR #18275 derived ONE of them (emit.mjs
// TYPE_STEPS) and the derivation above closed its partner here — but that fixed
// two entries of a list nobody had enumerated. An enumeration is a snapshot; a
// predicate is a rule, so what follows DISCOVERS the pairs instead of listing
// them, and every pair it finds must carry a written verdict below.
//
// SHAPE-KEYED, NOT NAME-KEYED. A guard that compares LIKE-NAMED constants across
// the two files finds SECTION_KEYS/SECTION_KEYS, RULE_KEYS/RULE_KEYS and
// EVIDENCE_KEYS/EVIDENCE_KEYS and is blind BY CONSTRUCTION to every pair whose
// two halves were named differently — which is most of them:
//
//   AIR_LADDER          <-> AIR_STEPS            (this file / emit.mjs)
//   CC_HEX_ROLES        <-> CC_ROLES             (differs by one member, on purpose)
//   CLI_NEW             <-> CLI_CHROME_NEW       (and emit's half is [GoName, role] rows)
//   CLI_REUSE           <-> CLI_CHROME_REUSE     (and THIS half is an object's keys)
//
// so the census pairs by MEMBERSHIP (Jaccard >= 0.5 on the id sets), projects
// row-shaped literals column by column, and reads an object literal's keys as a
// vector too. Names are used only to report what it found.
//
// THE RATCHET RUNS BOTH WAYS. An undeclared pair reds ("adjudicate it"), and a
// declared pair that is no longer discoverable reds too ("this verdict is about
// something that is gone"). Without the second arm the table rots into a list of
// claims about code that has moved.
//
// AND IT REFUSES RATHER THAN GOING BLIND. A parser that stops matching would
// discover zero pairs and every assertion here would pass on an empty set, which
// is the exact failure this census exists to catch one level down. Floors on the
// literal counts and on the discovered-pair count make that a named refusal.

// Collect `const NAME = [...]` / `const NAME = {...}` literals from JS source,
// bracket-aware (so nested rows survive) and string/comment-aware.
function literalsIn(src) {
  const out = [];
  const head = /(?:^|\n)[ \t]*(?:export[ \t]+)?const[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*([[{])/g;
  for (const m of src.matchAll(head)) {
    const open = m.index + m[0].length - 1;
    const close = open === -1 ? -1 : matchBracket(src, open);
    if (close === -1) continue;
    out.push({ name: m[1], kind: m[2], body: src.slice(open + 1, close) });
  }
  return out;
}
function matchBracket(src, open) {
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") { i = skipString(src, i); if (i === -1) return -1; continue; }
    if (c === "/" && src[i + 1] === "/") { const nl = src.indexOf("\n", i); if (nl === -1) return -1; i = nl; continue; }
    if (c === "[" || c === "{") depth++;
    else if (c === "]" || c === "}") { depth--; if (depth === 0) return i; }
  }
  return -1;
}
function skipString(src, i) {
  const q = src[i];
  for (let j = i + 1; j < src.length; j++) {
    if (src[j] === "\\") { j++; continue; }
    if (src[j] === q) return j;
  }
  return -1;
}
// Split a literal body on TOP-LEVEL commas, stripping line comments.
function topLevelParts(body) {
  const parts = [];
  let depth = 0, start = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === '"' || c === "'" || c === "`") { const e = skipString(body, i); if (e === -1) break; i = e; continue; }
    if (c === "/" && body[i + 1] === "/") { const nl = body.indexOf("\n", i); i = nl === -1 ? body.length : nl; continue; }
    if (c === "[" || c === "{" || c === "(") depth++;
    else if (c === "]" || c === "}" || c === ")") depth--;
    else if (c === "," && depth === 0) { parts.push(body.slice(start, i)); start = i + 1; }
  }
  parts.push(body.slice(start));
  return parts.map((p) => p.replace(/\/\/[^\n]*/g, "").trim()).filter((p) => p !== "");
}
const asString = (p) => (/^"[^"]*"$/.test(p) ? p.slice(1, -1) : null);
// Turn one literal into zero or more comparable VECTORS of ids.
//   ["a","b"]                    -> one vector, ["a","b"]
//   [["A","a"],["B","b"]]        -> one vector per column: ["A","B"] and ["a","b"]
//   { "a": ..., "b": ... }       -> one vector of the keys
// Anything else (computed entries, spreads, template literals) yields none: a
// list the file does not spell out is not a hand copy.
function vectorsOf(lit) {
  const parts = topLevelParts(lit.body);
  if (parts.length === 0) return [];
  if (lit.kind === "{") {
    const keys = parts.map((p) => {
      const m = /^(?:"([^"]*)"|([A-Za-z_$][\w$-]*))[ \t]*:/.exec(p);
      return m ? (m[1] !== undefined ? m[1] : m[2]) : null;
    });
    return keys.every((k) => k !== null) ? [{ id: lit.name, items: keys }] : [];
  }
  if (parts.every((p) => asString(p) !== null)) return [{ id: lit.name, items: parts.map(asString) }];
  if (parts.every((p) => p.startsWith("["))) {
    const rows = parts.map((p) => topLevelParts(p.slice(1, p.lastIndexOf("]"))).map(asString));
    const width = rows[0].length;
    if (!rows.every((r) => r.length === width && r.every((x) => x !== null))) return [];
    return Array.from({ length: width }, (_, c) => ({ id: `${lit.name}[${c}]`, items: rows.map((r) => r[c]) }));
  }
  return [];
}

const emitPath = join(here, "emit.mjs");
let emitSrc = "";
try { emitSrc = readFileSync(emitPath, "utf8"); } catch (e) {
  ok(false, `${LADDER_REFUSE} — cannot read ${emitPath} (${e.message}); the cross-file ladder census would report a clean tree having compared nothing`);
}
const emitVecs = emitSrc ? literalsIn(emitSrc).flatMap(vectorsOf) : [];
const selfPath = join(here, "validate.mjs");
let selfSrc = "";
try { selfSrc = readFileSync(selfPath, "utf8"); } catch (e) {
  ok(false, `${LADDER_REFUSE} — cannot read ${selfPath} (${e.message}); the census cannot see its own half of the pairs`);
}
const selfVecs = literalsIn(selfSrc).flatMap(vectorsOf);
// POSITIVE CONTROLS on the reader itself. These floors are the difference between
// "no drift" and "read nothing"; both are well below today's counts (emit 20+,
// this file 7+) and only a broken parser can cross them.
ok(emitVecs.length >= 12, `${LADDER_REFUSE} — extracted only ${emitVecs.length} list literal(s) from design/emit.mjs; the census reader has gone blind and every pair below would be "clean" because nothing was compared`);
ok(selfVecs.length >= 5, `${LADDER_REFUSE} — extracted only ${selfVecs.length} list literal(s) from design/validate.mjs itself; the census reader has gone blind`);

// THE VERDICTS. One entry per discovered pair, keyed `<this file> <-> <emit.mjs>`.
// `relation` is what must hold; `why` is the adjudication a reader arrives at.
const LADDER_VERDICTS = {
  // (2) ONE FACT KEPT TWICE — and deliberately NOT derived from tokens.json.
  // The order IS the specification here, not an observation of it: the loop above
  // asserts space.air is MONOTONIC in this order, so deriving the order by sorting
  // the values would make that assertion prove itself and the ladder could flatten
  // or invert without a word. tokens.json holds the ratios; these two lists hold
  // the intended RANKING, and they are one fact because emit.mjs emits the vars in
  // this order and validate.mjs grades them in it. They would legitimately diverge
  // only if emission order stopped meaning ladder order — at which point emit.mjs'
  // own comment ("Emission order IS the ladder order design/validate.mjs asserts
  // monotonic") is the thing to change first.
  "AIR_LADDER <-> AIR_STEPS": { relation: "equal", why: "one fact: the intended air ranking, spelled in both files because tokens.json holds ratios, not an order" },
  // (3)(4)(5) ONE FACT KEPT TWICE, same name on both sides. Each is the CLOSED
  // vocabulary of a token family: emit.mjs walks it to emit `--tok-*`, this file
  // walks it to require every member AND to refuse a token that is not on it. The
  // membership closure already makes each list equal to its tokens.json key SET;
  // what nothing held until now is that the two FILES agree — a member added to
  // tokens.json + this file but not to emit.mjs is required, valid, and emitted
  // nowhere. No derivation is possible for the same reason as (2) for SECTION/AIR
  // (order carries meaning) and because for RULE/EVIDENCE the list is what tells
  // check.mjs Parts K/M what a consumer census is allowed to see.
  "SECTION_KEYS <-> SECTION_KEYS": { relation: "equal", why: "one fact: the closed space.section vocabulary, walked by the emitter and graded here" },
  "RULE_KEYS <-> RULE_KEYS": { relation: "equal", why: "one fact: the closed space.rule vocabulary" },
  "EVIDENCE_KEYS <-> EVIDENCE_KEYS": { relation: "equal", why: "one fact: the closed space.evidence vocabulary" },
  // (6) TWO FACTS THAT OVERLAP BY DESIGN, and the overlap is exactly measurable.
  // emit.mjs CC_ROLES is "every cloudChrome role emitted as --cc-*"; CC_HEX_ROLES
  // here is "the roles that are {light,dark} HEX PAIRS". `line-rgb` is emitted like
  // the rest but is an "R,G,B" triplet, so it cannot ride the HEX loop and is graded
  // by RGB_TRIPLET immediately below. They legitimately diverge the day another role
  // stops being a hex pair — and then this entry's `extra` gains that role and says
  // so. Until then the two retirements both files' comments promise happen "IN
  // LOCKSTEP" are held by something other than the promise.
  "CC_HEX_ROLES <-> CC_ROLES": { relation: "emit-minus", extra: ["line-rgb"], why: "two facts: every emitted --cc-* role vs the subset that is a hex pair; line-rgb is an R,G,B triplet and is graded separately here" },
  // (7)(8) ONE FACT KEPT TWICE in two SHAPES. emit.mjs keeps [GoFieldName, role]
  // rows because it generates Go field names; this file keeps the bare roles (and
  // for REUSE, an object mapping role -> the var() ref it must hold). The role
  // column is the same vocabulary and a role added to one side only is a token this
  // file requires and the emitter never writes, or vice versa. Not derivable from
  // tokens.json: the split between NEW (hex) and REUSE (a var ref) is a decision
  // about the CLI, not a property of the token file.
  "CLI_NEW <-> CLI_CHROME_NEW[1]": { relation: "equal", why: "one fact in two shapes: the NEW cliChrome hex roles; emit.mjs carries a Go field name beside each" },
  "CLI_REUSE <-> CLI_CHROME_REUSE[1]": { relation: "equal", why: "one fact in two shapes: the REUSE cliChrome roles; this file keys them to the var() ref they must resolve to" },
  // (9)(10)(11) THE SAME VOCABULARY, ONE FILE OVER: emit.mjs keeps each family as a
  // KEY LIST plus a UNITS MAP, and the census pairs this file's key list against
  // both halves. That is not noise — the units map is the half that decides whether
  // `fill` emits as a bare ratio or as `0.92px`, so a key present in one and absent
  // from the other is a real hole, and holding all three in step costs nothing.
  "SECTION_KEYS <-> SECTION_UNITS": { relation: "equal", why: "one fact: the space.section vocabulary, kept in emit.mjs as a key list AND a units map" },
  "RULE_KEYS <-> RULE_UNITS": { relation: "equal", why: "one fact: the space.rule vocabulary, key list + units map" },
  "EVIDENCE_KEYS <-> EVIDENCE_UNITS": { relation: "equal", why: "one fact: the space.evidence vocabulary, key list + units map" },
  // (12) ONE FACT — THE LIFECYCLE STATE SET — AND IT IS THE ONE THE CENSUS FOUND
  // THAT NOBODY WAS LOOKING FOR. EXPECTED_ROLE here is already closed BOTH ways
  // against design/status-manifest.json (a state in the manifest and not in the map
  // reds, and the reverse reds too; design/validate-life-fence.test.mjs proves it by
  // mutation). emit.mjs LIFE_ORDER is a HAND LIST of the same nine states that
  // nothing pins to the manifest — check.mjs Part 5 ITERATES it, so a state added to
  // the manifest, to tokens.json and to EXPECTED_ROLE but not to LIFE_ORDER is
  // emitted nowhere and checked by nothing. That is the blind direction PR #18275
  // removed from the type ladder, alive in a third place. Pinning membership here
  // ratchets LIFE_ORDER to the manifest transitively.
  // ORDER IS DELIBERATELY NOT PINNED: LIFE_ORDER's sequence is emit.mjs' own
  // emission order ("appended so the canonical emission order ... extends without
  // renumbering the shipped states") and this file's map has no order at all. They
  // legitimately diverge in order and must not in membership.
  "EXPECTED_ROLE <-> LIFE_ORDER": { relation: "same-set", why: "one fact (the lifecycle state set) in two shapes; LIFE_ORDER additionally carries an emission ORDER this file does not hold, so only membership is pinned" },
};
// NOTE ON THE PAIR THAT IS NOT HERE. emit.mjs TYPE_STEPS <-> this file's
// CHROME_ORDER was the sixth pair and the one that cost a row to find: same set,
// REVERSED, different name. It is absent from this table because it no longer
// exists — both sides are now derived from tokens.type.chrome (emit.mjs
// typeLadderFrom, descending; chromeLadderAscending above, ascending), so there is
// no second copy left to hold in step. Adjudication (1): ONE FACT KEPT TWICE,
// DERIVED. The two derivations are NOT shared on purpose — see the note at the
// foot of this file.

const setOf = (v) => new Set(v);
function jaccard(a, b) {
  const A = setOf(a), B = setOf(b);
  let inter = 0;
  for (const x of A) if (B.has(x)) inter++;
  const union = A.size + B.size - inter;
  return union === 0 ? 0 : inter / union;
}
const seen = new Set();
for (const sv of selfVecs) {
  for (const ev of emitVecs) {
    if (jaccard(sv.items, ev.items) < 0.5) continue;
    const key = `${sv.id} <-> ${ev.id}`;
    seen.add(key);
    const verdict = LADDER_VERDICTS[key];
    if (!verdict) {
      ok(false,
        `cross-file ladder census: design/validate.mjs ${sv.id} [${sv.items.join(", ")}] and design/emit.mjs ${ev.id} ` +
        `[${ev.items.join(", ")}] are the same vocabulary kept twice by hand, and no verdict in LADDER_VERDICTS says whether ` +
        `that is ONE FACT (make them one, or pin them here) or TWO FACTS that merely look alike (say what would make them ` +
        `legitimately diverge). Adjudicate it in design/validate.mjs' LADDER_VERDICTS — an unjudged pair is how the last one hid.`);
      continue;
    }
    let expected = ev.items;
    if (verdict.relation === "reversed") expected = ev.items.slice().reverse();
    else if (verdict.relation === "emit-minus") expected = ev.items.filter((x) => !verdict.extra.includes(x));
    // "same-set" pins MEMBERSHIP only, for a pair whose two orders mean different
    // things. Compare sorted copies so a reorder on one side is not a false red.
    const lhs = verdict.relation === "same-set" ? sv.items.slice().sort() : sv.items;
    if (verdict.relation === "same-set") expected = expected.slice().sort();
    ok(
      lhs.length === expected.length && lhs.every((x, i) => x === expected[i]),
      `cross-file ladder census: design/validate.mjs ${sv.id} [${sv.items.join(", ")}] has drifted from design/emit.mjs ${ev.id} ` +
      `[${ev.items.join(", ")}] under the declared relation "${verdict.relation}"${verdict.relation === "emit-minus" ? ` minus [${verdict.extra.join(", ")}]` : ""} ` +
      `(expected [${expected.join(", ")}]). The verdict on record is: ${verdict.why}. Fix the copy that moved, or change the verdict.`,
    );
  }
}
// The ratchet's OTHER direction: a verdict about a pair that is no longer there.
for (const key of Object.keys(LADDER_VERDICTS)) {
  ok(seen.has(key),
    `cross-file ladder census: LADDER_VERDICTS still carries a verdict for "${key}" but the census no longer finds that pair — ` +
    `one of the two lists was renamed, restructured or derived away. Delete the entry (and say so where the derivation landed) or restore the pair.`);
}
// SECOND WITNESS on the pairing itself, not just on the parse. Read what it can
// and cannot do before trusting it:
//
//   IT CANNOT FIRE ALONE. The stale-verdict loop immediately above asserts that
//   EVERY key in LADDER_VERDICTS is still in `seen`, so `seen.size` cannot fall
//   below the size of that table without those by-name reds firing first. The
//   by-name arm is the primary instrument; this one only converts a BULK collapse
//   — a pairing that stopped pairing, which loses every pair at once — from a
//   scatter of identical "pair is gone" lines into one sentence that names the
//   count and says what it means.
//
//   THE FLOOR IS DELIBERATELY BELOW TODAY'S COUNT, not near it. The census finds
//   ELEVEN pairs on this tree (the run prints the number; do not take it from this
//   comment — the comment is the thing that rots). A pair LEGITIMATELY retired by
//   deriving both halves from one source is a good change and must not red here:
//   TYPE_STEPS/CHROME_ORDER was exactly that and it is why there are eleven rather
//   than twelve. Six is a little over half of eleven — it absorbs five such
//   retirements and still reds on a collapse. A floor set AT the current count
//   would be a coverage ratchet wearing a control's clothes, and it would red the
//   next time someone does the right thing.
const LADDER_PAIR_FLOOR = 6;
ok(seen.size >= LADDER_PAIR_FLOOR,
  `${LADDER_REFUSE} — the cross-file ladder census discovered only ${seen.size} pair(s) between design/validate.mjs and design/emit.mjs, ` +
  `below the floor of ${LADDER_PAIR_FLOOR}. Pairs are retired one at a time by deriving both halves from one source; losing this many at once means the ` +
  `pairing has gone blind, and its silence is not evidence that the two files agree`);

// WHY THE TWO LADDER DERIVATIONS ARE NOT SHARED (adjudication (1), the cost side).
// There are now three implementations of "sort tokens.type.<family> by size and
// refuse rather than go blind": typeLadderFrom in design/emit.mjs, ladderFrom in
// web/__tests__/type-ladder-emitted.test.ts, and chromeLadderAscending above.
// Sharing one would mean importing it, and the importer cannot be this file: the
// header contract is "dependency-free (Node built-ins only) ... W1.2 emitters
// trust it", and design/emit.mjs CALLS typeLadderFrom at module scope, so a
// malformed tokens.json would throw INSIDE the import and this validator would
// die with a stack trace instead of printing the numbered problem report that is
// its entire job — the one input it exists to grade is the one input that would
// break it. The web test is across a tree boundary with its own path-escape
// declaration. So the duplication here is DELIBERATE and its cost is stated: if
// the refusal contract changes, it changes in three places, and the census above
// holds the LISTS in step while nothing holds the three SORTS in step.

// --- report ----------------------------------------------------------------
if (errors.length) {
  console.error(`FAIL: design/tokens.json has ${errors.length} problem(s):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log("OK: design/tokens.json is well-formed and complete.");
console.log("  color roles: 10 base + 4 status (ok/warn/danger/info), light+dark");
console.log(`  lifecycle states: ${REQUIRED_LIFE.length} reconciled 1:1 with internal/semrole + taskboard`);
console.log("  fonts: chrome (self-hosted Inter) / mono / reading; type: chrome + reading scales");
console.log("  paper/email/callout/mailChrome/provider/cloudChrome/authButton/statusChrome/statusHealth/fleetStatus/errorPage/readerInfo: shape-gated");
console.log(`  cross-file ladder census: ${seen.size} vocabulary pair(s) between this file and design/emit.mjs, each adjudicated in LADDER_VERDICTS (${emitVecs.length} emit literals x ${selfVecs.length} here)`);
process.exit(0);
