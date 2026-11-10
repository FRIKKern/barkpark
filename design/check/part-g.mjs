// design/check/part-g.mjs — Part G of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { ARTIFACTS } from "../emit.mjs";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fail, failed, FAULT } from "./state.mjs";
import { here } from "./part-e.mjs";

// ── Part G: theme-identity attribute blocks + tone-pair nesting (D23–D26) ─────
// The Wave-4 CSS attribute axis: every attribute surface carries an explicit
// [data-bp-theme=<name>] block layered over its bare/evergreen fallback, theme
// identity is ORTHOGONAL to light/dark mode, and NO positional-passthrough var
// (the ones Parts B/D count) ever leaks into a theme scope (D25). The tone-pair
// nesting proof (D26): a theme re-declares its FULL var set at BOTH mode scopes,
// so a dark block nested in a light page re-resolves the opposite tone instead of
// inheriting the light page's active tone.
console.log("\ndesign/check.mjs — Part G: [data-bp-theme] identity blocks + tone-pair nesting");
const failedBeforeG = failed;

// Every attribute surface must carry an evergreen theme block (identity reached
// it). ENROLMENT IS DERIVED, NEVER LISTED. This was a five-entry literal list of
// path suffixes while TEN artifacts emitted [data-bp-theme] blocks, so five live
// surfaces (/papers reader, /sheets reader, status page, and both search-starter
// template globals) were outside the gate — a reader surface rebuilt with its
// theme blocks dropped, and the tree re-emitted so Part A was in sync, left Part G
// printing its PASS line over a surface with zero theme identity (proven 2026-09-16).
//
// The roster is now read off the EMITTER: a CSS/HTML surface acquires theme
// identity by calling themeBlocks() in its builder, so the set of builders that
// call it IS the set of themed surfaces. Scan the emitter for those call sites,
// resolve each to its enclosing function name, and match against `a.build.name`.
// A surface that starts calling themeBlocks enrols itself; one that STOPS calling
// it drops out of the derived roster and is caught by the floor below.
// The emitter's code lives in the design/emit/*.mjs modules emit.mjs imports;
// they are read in its import order (the order the code had in one file), then
// emit.mjs itself.
const emitEntry = readFileSync(join(here, "emit.mjs"), "utf8");
const emitModules = [...new Set([...emitEntry.matchAll(/from "\.\/(emit\/[a-z0-9-]+\.mjs)"/g)].map((m) => m[1]))];
const emitSource = [...emitModules.map((m) => readFileSync(join(here, m), "utf8")), emitEntry].join("\n");
const THEMED_BUILDERS = new Set();
{
  let fn = null;
  for (const line of emitSource.split("\n")) {
    const m = line.match(/^\s*(?:export\s+)?function\s+([A-Za-z0-9_$]+)\s*\(/);
    if (m) fn = m[1];
    if (fn && fn !== "themeBlocks" && /\bthemeBlocks\s*\(/.test(line)) THEMED_BUILDERS.add(fn);
  }
}
const ATTR_SURFACES = ARTIFACTS.filter(
  (a) => (a.kind === "css" || a.kind === "html") && THEMED_BUILDERS.has(a.build.name),
);
// Shrink-only floor. The derived roster answers "who is enrolled TODAY"; it cannot
// answer "did a surface silently stop being themed", because a builder that drops
// themeBlocks() drops out of its own roster. This number is the recorded count and
// may only be RAISED, in the same diff that adds the surface.
const ATTR_SURFACE_FLOOR = 10;
if (ATTR_SURFACES.length < ATTR_SURFACE_FLOOR)
  fail(
    `  Part G FAIL: only ${ATTR_SURFACES.length} artifact builder(s) call themeBlocks(), floor is ${ATTR_SURFACE_FLOOR} — ` +
    `a surface STOPPED emitting [data-bp-theme] blocks and silently left the theme-identity gate. ` +
    `Enrolled: ${ATTR_SURFACES.map((a) => a.name).join(", ") || "∅"}`,
  );
for (const a of ATTR_SURFACES) {
  const text = a.build();
  if (!/\[data-bp-theme="evergreen"\]/.test(text))
    fail(`  Part G FAIL: ${a.name} (${a.path}) has no [data-bp-theme="evergreen"] block — theme identity did not reach this surface`);
}
// The emitter-derived roster and the OUTPUT-derived roster must agree: an artifact
// whose emitted bytes carry a [data-bp-theme] block but whose builder is not in
// THEMED_BUILDERS means the scan above missed a call site (a hand-rolled theme
// block, or themeBlocks reached through an alias) — i.e. the derivation itself
// silently under-enrolled, which is the exact failure the literal list had.
{
  const byOutput = ARTIFACTS.filter(
    (a) => (a.kind === "css" || a.kind === "html") && /\[data-bp-theme=/.test(a.build()),
  );
  const enrolled = new Set(ATTR_SURFACES.map((a) => a.name));
  const orphans = byOutput.filter((a) => !enrolled.has(a.name));
  if (orphans.length)
    fail(
      `  Part G FAIL: ${orphans.length} artifact(s) EMIT a [data-bp-theme] block but are not in the themeBlocks()-derived roster ` +
      `(the enrolment scan under-counts): ${orphans.map((a) => `${a.name} (${a.path})`).join(", ")}`,
    );
  else
    console.log(`  ok   theme-identity roster DERIVED from emit.mjs themeBlocks() call sites: ${ATTR_SURFACES.length} surface(s) (floor ${ATTR_SURFACE_FLOOR}), output-derived roster agrees (${byOutput.length})`);
}

// D25: no positional-passthrough var/class may appear inside a [data-bp-theme]
// scope on ANY CSS surface (Parts B/D accumulate [light,dark] pairs positionally
// — a third occurrence reds them). Scan each theme block body.
const D25_BANNED = /--life-[\w-]+|--provider-[\w-]+|--cc-[\w-]+|\.bp-lg--|\.bp-inst--/;
let d25Clean = true;
for (const a of ARTIFACTS) {
  if (a.kind !== "css") continue;
  for (const m of a.build().matchAll(/\[data-bp-theme="[\w-]+"\][^{]*\{([^}]*)\}/g)) {
    if (D25_BANNED.test(m[1])) {
      fail(`  Part G FAIL: ${a.name} re-declares a positional-passthrough var/class (--life-*/--provider-*/--cc-*/.bp-lg--/.bp-inst--) inside a [data-bp-theme] block (D25)`);
      d25Clean = false;
    }
  }
}
if (FAULT.has("G")) fail("  Part G FAIL: injected fault (--selftest)");
if (d25Clean && failed === failedBeforeG)
  console.log("  ok   no --life-*/--provider-*/--cc-*/.bp-lg--/.bp-inst-- leaked into any [data-bp-theme] scope");

// Tone-pair nesting (D26), proven on cloud: the theme's light scope and its dark
// scope declare the SAME var set — the active/opposite pair is complete at every
// mode scope, so a nested dark island fully re-resolves.
{
  const t = ARTIFACTS.find((a) => a.path.endsWith("static/app.css")).build();
  const lm = t.match(/html\[data-bp-theme="evergreen"\] \{([^}]*)\}/);
  const dm = t.match(/html\[data-bp-theme="evergreen"\]\[data-theme="dark"\] \{([^}]*)\}/);
  if (!lm || !dm) {
    fail("  Part G FAIL: cloud evergreen light+dark theme scopes not both present — cannot prove tone-pair nesting");
  } else {
    const names = (body) => [...body.matchAll(/(--[\w-]+):/g)].map((x) => x[1]).sort();
    const ln = names(lm[1]), dn = names(dm[1]);
    if (ln.length === 0)
      fail("  Part G FAIL: cloud evergreen light theme scope declares zero vars");
    else if (ln.join(",") !== dn.join(","))
      fail(
        `  Part G FAIL: cloud tone-pair INCOMPLETE — light-scope vars ≠ dark-scope vars ` +
        `(a nested dark block would inherit the light page's active tone). ` +
        `light-only: ${ln.filter((x) => !dn.includes(x)).join(",") || "∅"}; ` +
        `dark-only: ${dn.filter((x) => !ln.includes(x)).join(",") || "∅"}`,
      );
    else
      console.log(`  ok   tone-pair: cloud re-declares all ${ln.length} theme vars at BOTH the light and dark mode scope (nested dark-in-light resolves the opposite pair)`);
  }
}

if (failed === failedBeforeG)
  console.log("  ok   Part G PASS — every attribute surface carries a [data-bp-theme] block; identity ⟂ mode; no passthrough leak.");
