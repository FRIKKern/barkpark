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
for (const role of ["primary", "primary-fg", "bg", "surface", "muted-surface", "text", "muted-text", "border", "ring", "accent"]) {
  hslPair(color[role], `color.${role}`);
}

// --- status roles: ok/warn/danger/info, each light+dark --------------------
const status = color.status || {};
for (const role of ["ok", "warn", "danger", "info"]) {
  ok(status[role] != null, `color.status.${role} is required (the four semantic roles are wired in W1.3)`);
  hslPair(status[role], `color.status.${role}`);
}

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

// --- scalar ladders --------------------------------------------------------
for (const k of ["1", "2", "3", "4", "5", "6", "7", "8"]) {
  ok(typeof (tokens.space || {})[k] === "number", `space.${k} is required (px)`);
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
const REQUIRED_LIFE = ["in_progress", "blocked", "done", "closed", "cancelled", "ready", "open"];
// role reconciled 1:1 with internal/semrole/semrole.go taskLifecycleRoles
const EXPECTED_ROLE = {
  in_progress: "info", blocked: "warn", done: "ok", closed: "ok",
  cancelled: "", ready: "", open: "",
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
process.exit(0);
