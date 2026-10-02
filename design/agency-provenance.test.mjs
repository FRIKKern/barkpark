// agency-provenance.test.mjs — the design engagement's EXIT drift gate.
//
// The closeout work order (task-d95c3e66b9177c8f, criterion "tokens mapped into
// canonical design/tokens.json with the agency") turned an outside agency's
// package into in-house canon: five accent ramps and the console shell
// vocabulary — including the fg4 legibility fix, light #76818f — were carried
// from the archived handover into design/themes/*.json and
// design/tokens.json color.cloudChrome.
//
// Everything downstream of tokens.json is already gated. design/check.mjs
// Part F byte-compares derive(theme) against tokens.json; design/validate.mjs
// SHAPE-gates cloudChrome (every role is an #rrggbb pair, line-rgb is an
// "R,G,B" triplet). Nothing compared a single canonical BYTE against the
// agency source it was copied from. The engagement is over: the agency cannot
// re-send the file, and the only remaining record of what was paid for is
// design/handover/ui-review-9/design/tokens.json sitting in the tree, read by
// no gate at all. A retint that walks evergreen's accent or drops fg4 back to
// the pre-fix value is, today, a green PR — validate.mjs sees a well-formed
// hex, check.mjs sees a self-consistent derivation, and the provenance the
// exit package exists to preserve is gone with nothing having gone red.
//
// This file closes that. It is the ONE thing in the repo that reads the
// archived handover.
//
// ENROLMENT IS A PREDICATE, NOT A LIST. The theme roster comes from
// readdirSync(design/themes) and the shell roster from the canonical
// cloudChrome object's own keys, so theme six and role fifteen are covered the
// day they land. Both directions are asserted where they are meaningful: every
// shipped theme must have an agency ramp AND every agency ramp must have a
// shipped theme (the accent family is closed — the agency delivered exactly
// the five that were adopted), while cloudChrome is canonical-to-agency only,
// because GR29/GR37 deliberately RETIRED eleven zero-consumer roles that still
// exist upstream. A retired role is a decision; an untraceable role is drift.
//
// Every arm is paired with a control that drives the SAME comparator over a
// perturbed copy and asserts it reports the drift, because a comparator that
// silently reads undefined on both sides would otherwise print a perfect green
// over a file it never opened.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { hslToHex } from "./derive.mjs";

const DESIGN = dirname(fileURLToPath(import.meta.url));
const AGENCY_REL = "design/handover/ui-review-9/design/tokens.json";

const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

const agency = readJson(join(DESIGN, "handover/ui-review-9/design/tokens.json"));
const tokens = readJson(join(DESIGN, "tokens.json"));

const themeNames = readdirSync(join(DESIGN, "themes"))
  .filter((f) => f.endsWith(".json"))
  .map((f) => f.replace(/\.json$/, ""))
  .sort();

const MODES = ["light", "dark"];

// --- the comparators. Pure, so the controls can drive them over planted input.

/** Every shipped theme's accent, as the hex the emitters will paint. */
export function accentDrift(themes, accents) {
  const out = [];
  const shipped = Object.keys(themes).sort();
  const delivered = Object.keys(accents).sort();
  for (const name of shipped) {
    if (!delivered.includes(name)) {
      out.push(`${name}: shipped theme has no agency ramp in ${AGENCY_REL}`);
      continue;
    }
    for (const mode of MODES) {
      const channels = themes[name]?.modes?.[mode]?.accent;
      if (typeof channels !== "string") {
        out.push(`${name}.${mode}: modes.${mode}.accent is missing from the theme file`);
        continue;
      }
      const got = hslToHex(channels);
      const want = accents[name]?.[mode]?.primary;
      if (typeof want !== "string") {
        out.push(`${name}.${mode}: agency ramp has no .primary`);
      } else if (got.toLowerCase() !== want.toLowerCase()) {
        out.push(`${name}.${mode}: canonical accent ${channels} = ${got}, agency delivered ${want}`);
      }
    }
  }
  for (const name of delivered) {
    if (!shipped.includes(name)) {
      out.push(`${name}: agency delivered a ramp with no design/themes/${name}.json`);
    }
  }
  return out;
}

/** Every canonical console-shell role, against the agency theme block. */
export function shellDrift(cloudChrome, themes) {
  const out = [];
  for (const [role, pair] of Object.entries(cloudChrome)) {
    if (role.startsWith("_")) continue;
    for (const mode of MODES) {
      const got = pair?.[mode];
      const want = themes?.[mode]?.[role];
      if (want === undefined) {
        out.push(`cloudChrome.${role}.${mode}: no such role in ${AGENCY_REL} themes.${mode} — untraceable to the handover`);
      } else if (got !== want) {
        out.push(`cloudChrome.${role}.${mode}: canonical ${got}, agency delivered ${want}`);
      }
    }
  }
  return out;
}

// --- arm 1: the five accent ramps.

test("every shipped accent ramp is byte-identical to the one the agency delivered", () => {
  assert.equal(themeNames.length, 5,
    `control: the engagement delivered five ramps; design/themes holds ${themeNames.length} (${themeNames.join(", ")})`);

  const themes = Object.fromEntries(
    themeNames.map((n) => [n, readJson(join(DESIGN, "themes", `${n}.json`))]),
  );
  assert.deepEqual(themeNames, Object.keys(agency.accents).sort(),
    "the shipped theme roster and the agency ramp roster must name the same five identities");

  assert.deepEqual(accentDrift(themes, agency.accents), []);
});

test("control: the accent comparator fires on a one-nibble retint and on a dropped ramp", () => {
  const themes = Object.fromEntries(
    themeNames.map((n) => [n, readJson(join(DESIGN, "themes", `${n}.json`))]),
  );

  // A retint of the flagship: evergreen light 151.96 -> 140 is still a
  // well-formed HSL triplet, so validate.mjs and check.mjs both stay green.
  const retinted = structuredClone(themes);
  retinted.evergreen.modes.light.accent = "140 71.81% 29.22%";
  const hits = accentDrift(retinted, agency.accents);
  assert.equal(hits.length, 1, `expected exactly one drift, got ${JSON.stringify(hits)}`);
  assert.match(hits[0], /^evergreen\.light: canonical accent 140 /);
  assert.match(hits[0], /agency delivered #15804e$/);

  // A ramp deleted from the source of truth.
  const trimmed = structuredClone(agency.accents);
  delete trimmed.fjord;
  assert.deepEqual(accentDrift(themes, trimmed), [
    "fjord: shipped theme has no agency ramp in design/handover/ui-review-9/design/tokens.json",
  ]);

  // A theme shipped without a ramp behind it.
  assert.deepEqual(accentDrift({}, { ochre: { light: {}, dark: {} } }), [
    "ochre: agency delivered a ramp with no design/themes/ochre.json",
  ]);
});

// --- arm 2: the console shell vocabulary, fg4 included.

test("every canonical cloudChrome role traces byte-for-byte to the agency handover", () => {
  const cc = tokens.color.cloudChrome;
  const roles = Object.keys(cc).filter((r) => !r.startsWith("_"));
  assert.ok(roles.length >= 14,
    `control: GR29/GR37 left 14 shell roles; found ${roles.length} (${roles.join(", ")})`);

  assert.deepEqual(shellDrift(cc, agency.themes), []);
});

test("the fg4 legibility fix is the byte the agency shipped, on both grounds", () => {
  // Named on its own because it is the byte the closeout criterion cites, and
  // because a generic role sweep would not say which role went dark.
  assert.equal(tokens.color.cloudChrome.fg4.light, "#76818f");
  assert.equal(tokens.color.cloudChrome.fg4.dark, "#626c7c");
  assert.equal(agency.themes.light.fg4, tokens.color.cloudChrome.fg4.light);
  assert.equal(agency.themes.dark.fg4, tokens.color.cloudChrome.fg4.dark);
});

test("control: the shell comparator fires on a reverted byte and on an untraceable role", () => {
  const cc = structuredClone(tokens.color.cloudChrome);

  // fg4 light walked one step dimmer — a plausible "tidy the ladder" edit that
  // every existing gate accepts.
  cc.fg4.light = "#8d96a5";
  assert.deepEqual(shellDrift(cc, agency.themes), [
    "cloudChrome.fg4.light: canonical #8d96a5, agency delivered #76818f",
  ]);

  // A role invented in-house and passed off as shell vocabulary.
  assert.deepEqual(
    shellDrift({ "fg9": { light: "#000000", dark: "#ffffff" } }, agency.themes),
    [
      `cloudChrome.fg9.light: no such role in ${AGENCY_REL} themes.light — untraceable to the handover`,
      `cloudChrome.fg9.dark: no such role in ${AGENCY_REL} themes.dark — untraceable to the handover`,
    ],
  );

  // And it does NOT over-fire on the roles GR29/GR37 retired. That set is
  // DERIVED, not listed: every role the agency's theme block carries that the
  // canonical object does not. tokens.json's own note names eleven, but four of
  // those (azure, cloudflare, github, hetzner) were never shell roles at all —
  // they live in the handover's `identity` block — so a hand-copied list would
  // have asserted a falsehood about the source. Absence from the canonical side
  // is a decision; the comparator only walks what canon still ships.
  const agencyShellRoles = new Set([
    ...Object.keys(agency.themes.light),
    ...Object.keys(agency.themes.dark),
  ]);
  const retired = [...agencyShellRoles]
    .filter((r) => tokens.color.cloudChrome[r] === undefined)
    .sort();
  assert.ok(retired.length > 0,
    "control: GR29/GR37 retired shell roles; if none are missing this arm proves nothing");
  for (const r of retired) {
    assert.equal(tokens.color.cloudChrome[r], undefined,
      `${r} was retired from the shell vocabulary and must not return to cloudChrome`);
  }
  assert.deepEqual(shellDrift(tokens.color.cloudChrome, agency.themes), []);
});
