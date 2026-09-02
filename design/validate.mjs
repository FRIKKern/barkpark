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
for (const step of ["xs", "sm", "base", "lg", "xl", "2xl"]) {
  const s = (type.chrome || {})[step];
  ok(s && typeof s.size === "number" && typeof s.lineHeight === "number", `type.chrome.${step} needs {size,lineHeight}`);
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
//   1. every step is a real OPENING — >= 1.0x the paragraph beat. A step below 1
//      would make an evidence block sit TIGHTER than two paragraphs, which is the
//      exact defect this scale exists to fix (the reader's table opened at 0px).
//   2. the ladder is MONOTONIC in the documented order, so the heavier a block is
//      the more room it takes. Flattening it is a decision, not a typo.
const AIR_LADDER = ["code", "table", "asciicast", "callout", "stats", "figure"];
const air = (tokens.space || {}).air || {};
ok(typeof air.beat === "number" && air.beat > 0, "space.air.beat is required (px, the paragraph beat the scale is a ratio of)");
let prevAir = 0;
for (const k of AIR_LADDER) {
  const v = air[k];
  ok(typeof v === "number", `space.air.${k} is required (a ratio of space.air.beat)`);
  if (typeof v !== "number") continue;
  ok(v >= 1.0, `space.air.${k} is ${v}; an evidence block must open at or above the paragraph beat (1.0x)`);
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
const REQUIRED_LIFE = ["in_progress", "blocked", "done", "closed", "cancelled", "ready", "open", "considering", "researching"];
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
process.exit(0);
