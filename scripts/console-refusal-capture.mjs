#!/usr/bin/env node
//
// console-refusal-capture.mjs — READ THE REFUSING INSTRUMENT'S OWN SUMMARY LINE.
//
// WHY THIS FILE EXISTS (cch-w63-bl)
// ---------------------------------
// The console gate runs nine instruments that can exit 2 — "I REFUSED TO
// MEASURE" — and a wrapper that wants to quote the refusal has to find the one
// line the instrument published about it. Before this file, a capture anchored
// on the `!!` prefixes covered THREE of the nine. The other six spoke a private
// vocabulary no `!!`-anchored reader could see:
//
//   __reason_arm_census.mjs             "  EXIT 2 — THE CENSUS REFUSED TO MEASURE…"  (leading spaces, no !!)
//   __agent_event_vocabulary_census.mjs "  EXIT 2 — THE CENSUS REFUSED TO MEASURE…"  (leading spaces, no !!)
//   __binding_census.mjs                bare console.error lines, no prefix at all
//   __refusal_copy_census.mjs           bare `FAIL(2):` lines, no prefix at all
//   __unknown_census.mjs                bare `FAIL(2):` lines, no prefix at all
//   __css_check.mjs                     "REFUSED (2): …"                            (no !!)
//   __me_envelope_census.mjs            "REFUSED (2): …" on **STDOUT**              (invisible to a stderr-only capture)
//
// Shipping a capture over that population would replace a WRONG sentence with
// NO sentence for most of the gate, in the wave about silence. So the emitters
// were normalised first (see each file's "THE ONE REFUSAL VOCABULARY" block),
// and this is the reader.
//
// THE SHAPE
// ---------
//     !! <INSTRUMENT NAME> (exit 2): <reason>
//
// which is the shape `__preview__/exit-vocabulary.mjs` already emits for the
// browser instruments, so one reader covers the whole fence.
//
// THE ONE WRITTEN EXCEPTION
// -------------------------
// `overflow-guard.mjs`'s `die()` writes `!! OVERFLOW GUARD: <msg>` with NO
// `(exit 2)` marker, and that prefix carries the port squat, the font pin, and
// all thirteen fixture-integrity refusals. It is NOT normalised — deliberately:
// a capture keyed on the literal `(exit 2)` silently missing a whole prefix is
// the exact defect this file was filed against, so the miss is kept alive as a
// PROVEN case rather than papered over by editing the emitter. `UNMARKED_PREFIXES`
// below is that exception, written down, with a positive control in the test.
//
// WHAT IT IS NOT
// --------------
// It does NOT decide whether a run refused — the EXIT CODE does that. This only
// finds the sentence to quote once something already exited 2. A run that exits
// 0 or 1 must never be passed through here as if it had refused: `bringup-retry`
// prints `!! bring-up <label>: attempt N/M REFUSED — …` on runs that then go
// GREEN, and that line is negative control #1.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ── THE CAPTURE ──────────────────────────────────────────────────────────────
//
// `!!`, then an ALL-CAPS instrument name (a lowercase word is a per-run label,
// never an instrument — that is what keeps `!! bring-up …` and `!! serve.mjs: …`
// out), then the `(exit 2…)` marker, then a separator. The name is captured so a
// caller can say WHICH instrument refused.
export const REFUSAL_RE =
  /^\s*!! ([A-Z][A-Z0-9 /&'’-]*?)(?: crashed)? \(exit 2[^)]*\)\s*(?::|—|-)/;

// The written exception, above. Kept as an explicit list rather than folded into
// the regex so that "which prefixes are trusted without a marker" is one
// greppable line and not a subtlety inside an alternation.
export const UNMARKED_PREFIXES = [
  {
    prefix: "!! OVERFLOW GUARD: ",
    name: "OVERFLOW GUARD",
    why:
      "overflow-guard.mjs die() publishes no (exit 2) marker; it is the prefix for the " +
      "port squat, the font pin and the fixture-integrity refusals. Left unmarked ON PURPOSE " +
      "so the capture is proven against a real un-marked emitter (cch-w63-bl criterion 3).",
  },
];

const unmarkedHit = (line) =>
  UNMARKED_PREFIXES.find((u) => line.replace(/^\s+/, "").startsWith(u.prefix)) || null;

/** True when ONE line is an instrument's exit-2 summary line. */
export function isRefusalLine(line) {
  if (typeof line !== "string") return false;
  return REFUSAL_RE.test(line) || Boolean(unmarkedHit(line));
}

/** The instrument name a refusal line names, or null. */
export function refusalInstrument(line) {
  if (typeof line !== "string") return null;
  const m = REFUSAL_RE.exec(line);
  if (m) return m[1].trim();
  const u = unmarkedHit(line);
  return u ? u.name : null;
}

/**
 * The FIRST refusal summary line in a block of captured output, or null.
 * First, not last: an instrument publishes its refusal and then may print
 * teardown noise, and the first line is the one that says why.
 */
export function captureRefusal(text) {
  if (typeof text !== "string") return null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, "");
    if (isRefusalLine(line)) return line.replace(/^\s+/, "");
  }
  return null;
}

// ── THE POPULATION, SO AN EIGHTH EMITTER REDS ────────────────────────────────
//
// The unit test enumerates cloud/priv/static/*.mjs and
// cloud/priv/static/__preview__/*.mjs for exit-2 paths and demands every file it
// finds be accounted for HERE. A new refusing instrument that nobody taught this
// reader about fails the test by ARRIVING, not by being noticed.
// A PREDICATE, NOT A LIST (see the `match` regexes): each entry is a directory
// plus the rule for which of its files are in this capture's fence, so a file
// ARRIVING is enough to be scanned. `scripts` is fenced to `console-*` because
// the rest of scripts/ emits for gates that never route through this capture
// (studio-desk-*, false-open-sweep, font-zero-advance, boundary-build-cache-
// tripwire all exit 2 under other lanes' readers); the arm is still scanned on
// every run, and the test asserts it reached files, so "0 emitters" here is a
// MEASURED zero and not an enumeration that quietly went empty.
export const FENCE_GLOBS = [
  { dir: "cloud/priv/static", match: /\.mjs$/ },
  { dir: "cloud/priv/static/__preview__", match: /\.mjs$/ },
  { dir: "scripts", match: /^console-.*\.mjs$/ },
];

// Emitters normalised by cch-w63-bl: exactly one exit-2 path each, inside their
// own `refuse2` helper, publishing the shape above on STDERR.
export const NORMALISED = [
  { file: "cloud/priv/static/__css_check.mjs", name: "CSS CHECK" },
  { file: "cloud/priv/static/__binding_census.mjs", name: "BINDING CENSUS" },
  { file: "cloud/priv/static/__refusal_copy_census.mjs", name: "REFUSAL COPY CENSUS" },
  { file: "cloud/priv/static/__reason_arm_census.mjs", name: "REASON ARM CENSUS" },
  { file: "cloud/priv/static/__me_envelope_census.mjs", name: "ME ENVELOPE CENSUS" },
  { file: "cloud/priv/static/__envelope_census.mjs", name: "ENVELOPE CENSUS" },
  { file: "cloud/priv/static/__init_wiring_census.mjs", name: "INIT WIRING CENSUS" },
  { file: "cloud/priv/static/__agent_event_vocabulary_census.mjs", name: "AGENT EVENT VOCABULARY CENSUS" },
  { file: "cloud/priv/static/__unknown_census.mjs", name: "UNKNOWN CENSUS" },
];

// Emitters that ALREADY spoke the shape. Each `sample` is a line copied from the
// emitter's own source, so the test asserts against what the file writes rather
// than against a paraphrase of it.
export const CONFORMING = [
  {
    file: "cloud/priv/static/__preview__/breakpoint-sweep.mjs",
    name: "BREAKPOINT SWEEP",
    sample: "!! BREAKPOINT SWEEP (exit 2): the sweep has no coverage for what the artifact now declares.",
  },
  {
    file: "cloud/priv/static/__preview__/member-authority-sweep.mjs",
    name: "MEMBER AUTHORITY SWEEP",
    sample: "!! MEMBER AUTHORITY SWEEP (exit 2): unhandled — Error: boom",
  },
  {
    file: "cloud/priv/static/__preview__/overflow-guard.mjs",
    name: "OVERFLOW GUARD",
    sample: "!! OVERFLOW GUARD: STALE SERVER on :4199. /app.js served 10 B but this tree's disk has 20 B.",
  },
  {
    file: "cloud/priv/static/__preview__/modal-oracle.mjs",
    name: "ORACLE",
    sample: "!! ORACLE (exit 2): REFUSED TO MEASURE — STALE SERVER on :4199.",
  },
  {
    file: "cloud/priv/static/__preview__/cssom-parity.mjs",
    name: "GUARD",
    sample: "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.",
  },
  {
    file: "cloud/priv/static/__preview__/exit-vocabulary.mjs",
    name: "PROOF",
    sample: "!! PROOF (exit 2): REFUSED TO MEASURE — the browser never came up",
  },
  // hashchange-wiring.mjs is a `run:` step of the `modal-oracle` job
  // (console-harness.yml, `node cloud/priv/static/__preview__/hashchange-wiring.mjs`)
  // and it refuses under THREE names, from three different guards, before and
  // after Chrome exists. All three already spoke the shape; nothing named them
  // here, so the DERIVED fence test was red on origin/main.
  {
    file: "cloud/priv/static/__preview__/hashchange-wiring.mjs",
    name: "ROSTER GUARD",
    sample: "!! ROSTER GUARD (exit 2) — refusing to boot Chrome:",
  },
  {
    file: "cloud/priv/static/__preview__/hashchange-wiring.mjs",
    name: "GUARD",
    sample: "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.",
  },
  {
    file: "cloud/priv/static/__preview__/hashchange-wiring.mjs",
    name: "HASHCHANGE WIRING",
    sample: "!! HASHCHANGE WIRING (exit 2): REFUSED TO MEASURE",
  },
  // pin-race.mjs is a `run:` step of its own job and refuses through ONE funnel
  // (`const refuse = async (why)`), which sets `process.exitCode = 2` rather
  // than calling process.exit(2) — the reason a reader keyed on the call shape
  // alone would not have found it either.
  {
    file: "cloud/priv/static/__preview__/pin-race.mjs",
    name: "PIN RACE",
    sample: "!! PIN RACE (exit 2): REFUSED TO MEASURE — no Chrome/Chromium found.",
  },
];

// Files in the fence that exit 2 and publish NO capturable refusal, each with the
// reason it is out of scope. An exclusion is a decision, so it is written down.
export const EXCLUDED = [
  {
    file: "cloud/priv/static/__preview__/serve.mjs",
    why:
      "A SPAWNED SIDECAR, never a gate step. No `run:` line reaches it; the browser " +
      "instruments start it and translate its death into their OWN refusal " +
      "(`!! OVERFLOW GUARD: STALE SERVER…`, `!! ORACLE (exit 2): …`). Capturing serve's " +
      "line as well would quote the same event twice under a name no job ran.",
  },
  ...[
    "__future_act_dump", "__lifecycle_state_dump", "__plan_catalog_dump",
    "__plan_features_dump", "__terminal_verb_dump", "__tier_card_dump",
    "__trial_reminder_dump",
  ].map((n) => ({
    file: `cloud/priv/static/__preview__/${n}.mjs`,
    why:
      "A DUMP EXTRACTOR, not a gate. console-harness.yml states in its own comments that " +
      "no `run:` line anywhere reaches the seven `__*_dump.mjs` files; they are read by the " +
      "Elixir side, which surfaces its own failure. Nothing captures their stderr, so " +
      "normalising it would be a shape with no reader.",
  })),
];

// ── CLI ──────────────────────────────────────────────────────────────────────
// `node scripts/console-refusal-capture.mjs <file>` or `… -` (stdin).
// Prints the captured line and exits 0; exits 1 and prints nothing when the
// output carries no refusal summary line.
const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const arg = process.argv[2];
  if (!arg) {
    process.stderr.write("usage: console-refusal-capture.mjs <file|->\n");
    process.exit(64);
  }
  const text = arg === "-" ? fs.readFileSync(0, "utf8") : fs.readFileSync(arg, "utf8");
  const line = captureRefusal(text);
  if (line === null) process.exit(1);
  process.stdout.write(line + "\n");
}
