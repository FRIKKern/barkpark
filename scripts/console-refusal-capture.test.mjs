// console-refusal-capture.test.mjs — the capture's own controls.
//
// Run:  node --test scripts/console-refusal-capture.test.mjs
//
// THREE THINGS ARE PROVEN HERE, and the third is the one that matters:
//
//   1. POSITIVE — every prefix a console instrument actually publishes is caught,
//      including overflow-guard's `die()` prefix, which carries NO `(exit 2)`
//      marker and is the reason a marker-keyed capture silently loses a whole
//      family of refusals.
//   2. NEGATIVE — seven near-miss lines, each copied from a real emitter in this
//      tree, are REJECTED. Control #1 is the one that matters: bringup-retry
//      prints `!! bring-up <label>: attempt N/M REFUSED — …` on runs that then
//      go GREEN, and a capture that quotes it turns a passing run into a
//      published refusal.
//   3. DERIVED — the fence is ENUMERATED FROM SOURCE. Every file under
//      cloud/priv/static/ and cloud/priv/static/__preview__/ with an exit-2 path
//      must be accounted for as normalised, already-conforming, or explicitly
//      excluded with a written reason. An EIGHTH emitter added later reds this
//      test by arriving; it does not need anyone to notice it.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  REFUSAL_RE,
  UNMARKED_PREFIXES,
  NORMALISED,
  CONFORMING,
  EXCLUDED,
  FENCE_GLOBS,
  captureRefusal,
  isRefusalLine,
  refusalInstrument,
} from "./console-refusal-capture.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");

// ═══════════════════════════════════════════════════════════════════════════
// (1) THE SEVEN NEGATIVE CONTROLS
// ═══════════════════════════════════════════════════════════════════════════
//
// Every one is a line this tree really prints. A synthetic near-miss proves the
// regex is picky; these prove it is picky about the RIGHT things.
const NEGATIVE_CONTROLS = [
  {
    why: "bringup-retry.mjs:167 — printed on runs that then go GREEN. THE control.",
    line: "!! bring-up   preview: attempt 2/3 REFUSED — Chrome never wrote DevToolsActivePort",
  },
  {
    why: "breakpoint-sweep.mjs:1835 / overflow-guard.mjs:763 — a teardown warning, not a refusal.",
    line: "!! TEARDOWN SHOUT: pid 4711 SURVIVED SIGKILL. Reap it by hand: kill -9 4711",
  },
  {
    why: "serve.mjs:194 — the spawned sidecar; its parent publishes the refusal.",
    line: "!! serve.mjs: self-probe of /app.js failed (ECONNREFUSED) — refusing to claim readiness.",
  },
  {
    why: "console-tdz-order-check.mjs:1132 — a banner on a deliberately crippled demo build.",
    line: "!! DEMO VARIANT — a deliberately crippled build, NOT the shipped guard.",
  },
  {
    why: "overflow-guard.mjs:9117 — exit 1, a MEASURED DEFECT. Never a refusal.",
    line: "OVERFLOW GUARD FAIL — 3 finding(s) in: W20-phone-band-billing-chip",
  },
  {
    why: "overflow-guard.mjs:9120 — the GREEN line. A capture that quotes it is worse than silence.",
    line: "OVERFLOW GUARD PASS — W20-phone-band-billing-chip measured fixed in a real browser",
  },
  {
    why: "exit-vocabulary.mjs defect() — `!! <NAME> (exit 1): MEASURED DEFECT`. Same prefix, wrong code.",
    line: "!! ORACLE (exit 1): MEASURED DEFECT — the account modal overflows at 320px",
  },
];

test("cch-w63-bl: the seven negative controls are all REJECTED", () => {
  assert.equal(NEGATIVE_CONTROLS.length, 7, "the row named seven; a shorter list is a weaker test");
  for (const c of NEGATIVE_CONTROLS) {
    assert.equal(isRefusalLine(c.line), false, `WRONGLY CAPTURED (${c.why}):\n  ${c.line}`);
    assert.equal(captureRefusal(c.line + "\n"), null, `captureRefusal took it: ${c.line}`);
  }
});

test("cch-w63-bl: bringup-retry's advisory REFUSED does not survive a whole GREEN transcript", () => {
  // The shape a green run really has: two bring-up refusals, then a PASS.
  const green =
    ">> bring-up   preview: attempt 1/3\n" +
    "!! bring-up   preview: attempt 1/3 REFUSED — Chrome never wrote DevToolsActivePort\n" +
    "!! bring-up   preview: attempt 2/3 REFUSED — spawn EAGAIN\n" +
    ">> bring-up   This run's measurement comes from attempt 3.\n" +
    "OVERFLOW GUARD PASS — W20 measured fixed in a real browser\n";
  assert.equal(captureRefusal(green), null, "a GREEN run must publish NO refusal line");
});

// ═══════════════════════════════════════════════════════════════════════════
// (2) A POSITIVE CONTROL PER PREFIX
// ═══════════════════════════════════════════════════════════════════════════

const POSITIVE_CONTROLS = [
  ["GUARD", "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome."],
  ["BREAKPOINT SWEEP", "\n!! BREAKPOINT SWEEP (exit 2): the height axis was ASKED for [800] and MEASURED []."],
  ["MEMBER AUTHORITY SWEEP", "\n!! MEMBER AUTHORITY SWEEP (exit 2): unhandled — Error: boom"],
  ["ORACLE", "\n!! ORACLE (exit 2): REFUSED TO MEASURE — STALE SERVER on :4199."],
  ["ROSTER GUARD", "!! ROSTER GUARD (exit 2) — refusing to boot Chrome:"],
  // The crash arm: a lowercase word between the name and the marker, and the
  // marker itself carries prose.
  ["OVERFLOW GUARD", "!! OVERFLOW GUARD crashed (exit 2 — nothing was measured): Error: socket hang up"],
  // THE UNMARKED PREFIX — no `(exit 2)` anywhere on the line. This is criterion 3.
  ["OVERFLOW GUARD", "\n!! OVERFLOW GUARD: STALE SERVER on :4199. /app.js served 10 B, disk has 20 B."],
];

test("cch-w63-bl: every published prefix is CAUGHT, including the un-marked one", () => {
  for (const [name, line] of POSITIVE_CONTROLS) {
    const got = captureRefusal(line + "\n");
    assert.notEqual(got, null, `MISSED: ${JSON.stringify(line)}`);
    assert.equal(refusalInstrument(got), name, `wrong instrument for ${JSON.stringify(line)}`);
  }
});

test("cch-w63-bl: the un-marked prefix is a WRITTEN exception, not an accident", () => {
  assert.equal(UNMARKED_PREFIXES.length, 1);
  const u = UNMARKED_PREFIXES[0];
  assert.equal(u.prefix, "!! OVERFLOW GUARD: ");
  assert.ok(u.why.length > 80, "an exception without a written reason is a hole");
  // And it is genuinely un-marked: the marker-keyed regex alone LOSES it.
  assert.equal(REFUSAL_RE.test("!! OVERFLOW GUARD: STALE SERVER on :4199."), false,
    "if this ever passes, the emitter grew a marker and the exception should be retired");
});

test("cch-w63-bl: captureRefusal returns the FIRST refusal line out of real mixed output", () => {
  const mixed =
    ">> preview  http://127.0.0.1:4199\n" +
    "!! bring-up   preview: attempt 1/2 REFUSED — spawn EAGAIN\n" +
    "\n!! OVERFLOW GUARD: STALE SERVER on :4199.\n" +
    "   Find it: lsof -nP -iTCP:4199 -sTCP:LISTEN\n" +
    "!! TEARDOWN SHOUT: pid 4711 SURVIVED SIGKILL\n";
  assert.equal(captureRefusal(mixed), "!! OVERFLOW GUARD: STALE SERVER on :4199.");
});

// ═══════════════════════════════════════════════════════════════════════════
// (3) THE DERIVED POPULATION — an eighth emitter reds by ARRIVING
// ═══════════════════════════════════════════════════════════════════════════

// LINE comments are stripped so a file that only MENTIONS an exit-2 path in
// prose (exit-vocabulary.mjs does, at its line 50) is not counted as an emitter.
// Block comments are deliberately NOT stripped: a naive /* … */ strip eats
// regex literals and template strings — measured, it removed most of
// __css_check.mjs — and a wrong denominator is worse than a slightly wide one.
const stripComments = (src) =>
  src
    .split("\n")
    .filter((l) => !/^\s*\/\//.test(l))
    .join("\n");

const EXIT2 = /process\.exit\(2\)|process\.exitCode\s*=\s*2/;

function fenceEmitters() {
  const out = [];
  for (const dir of FENCE_GLOBS) {
    for (const f of fs.readdirSync(path.join(ROOT, dir)).sort()) {
      if (!f.endsWith(".mjs")) continue;
      const rel = `${dir}/${f}`;
      if (fs.statSync(path.join(ROOT, rel)).isDirectory()) continue;
      if (EXIT2.test(stripComments(read(rel)))) out.push(rel);
    }
  }
  return out;
}

test("cch-w63-bl (DERIVED): every exit-2 emitter in the fence is accounted for", () => {
  const found = fenceEmitters();
  // A floor, so an enumeration that silently went empty cannot pass.
  assert.ok(found.length >= 13, `the fence enumeration collapsed to ${found.length} files:\n${found.join("\n")}`);

  const known = new Set([
    ...NORMALISED.map((e) => e.file),
    ...CONFORMING.map((e) => e.file),
    ...EXCLUDED.map((e) => e.file),
  ]);
  const orphans = found.filter((f) => !known.has(f));
  assert.deepEqual(orphans, [],
    "an exit-2 emitter nobody taught scripts/console-refusal-capture.mjs about.\n" +
    "Add it to NORMALISED (after giving it a `refuse2` helper), to CONFORMING, or to\n" +
    "EXCLUDED with a written reason:\n  " + orphans.join("\n  "));

  // And every NORMALISED/CONFORMING entry must still exist — a manifest that
  // outlives its file is a capture aimed at nothing.
  for (const e of [...NORMALISED, ...CONFORMING]) {
    assert.ok(fs.existsSync(path.join(ROOT, e.file)), `manifest names a missing file: ${e.file}`);
  }
});

test("cch-w63-bl (DERIVED): each normalised emitter declares its name and has ONE exit-2 path", () => {
  for (const e of NORMALISED) {
    const src = stripComments(read(e.file));
    assert.match(src, new RegExp(`const REFUSAL_NAME = "${e.name}";`),
      `${e.file} does not declare REFUSAL_NAME = "${e.name}" — the capture is aimed at a name the file no longer publishes`);
    assert.match(src, /const refuse2 = \(reason\) => \{/, `${e.file} lost its refuse2 helper`);
    const exits = (src.match(/process\.exit\(2\)/g) || []).length;
    assert.equal(exits, 1,
      `${e.file} has ${exits} exit-2 paths; exactly one is allowed and it lives inside refuse2. ` +
      `A second one publishes no capturable line.`);
    // The helper's WRITE, read from source: a line the test typed itself would
    // stay green with the `!!` deleted from the emitter (measured by the lead,
    // 2026-09-09 — that mutation survived the manifest-only form).
    const write = "process.stderr.write(`!! ${REFUSAL_NAME} (exit 2): REFUSED TO MEASURE — ${reason}\\n`)";
    assert.ok(src.includes(write),
      `${e.file}'s refuse2 no longer writes the captured shape to stderr verbatim: ${write}`);
    // The line the helper builds from that template, matched against the shipped regex.
    const line = `!! ${e.name} (exit 2): REFUSED TO MEASURE — could not read its input`;
    assert.equal(captureRefusal(line + "\n"), line, `the capture cannot read ${e.file}'s own shape`);
    assert.equal(refusalInstrument(line), e.name);
  }
});

test("cch-w63-bl (DERIVED): each conforming emitter still carries its literal prefix", () => {
  for (const e of CONFORMING) {
    const src = read(e.file);
    const marker = e.file.endsWith("exit-vocabulary.mjs")
      ? "!! ${instrument} (exit 2): "     // the module that DEFINES the shape
      : `!! ${e.name}`;
    assert.ok(src.includes(marker),
      `${e.file} no longer writes ${JSON.stringify(marker)} — either it was renamed (update this manifest) ` +
      `or the capture now points at a prefix nothing publishes`);
    assert.equal(captureRefusal(e.sample + "\n"), e.sample, `MISSED ${e.file}'s own sample`);
  }
});

test("cch-w63-bl: every exclusion carries a written reason", () => {
  assert.ok(EXCLUDED.length > 0);
  for (const e of EXCLUDED) {
    assert.ok(fs.existsSync(path.join(ROOT, e.file)), `excluded file is gone: ${e.file}`);
    assert.ok(e.why && e.why.length > 80, `${e.file} is excluded with no real reason`);
  }
});
