// design/check/part-a.mjs — Part A of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { attribute, evaluateAll, lostLines, MANIFEST_PATH, readManifest, repoRoot } from "../emit.mjs";
import { evaluateMirror } from "../paper-editor-mirror.mjs";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part A: per-artifact byte-compare against committed ──────────────────────
function firstDiff(a, b) {
  const la = a.split("\n"), lb = b.split("\n");
  const n = Math.max(la.length, lb.length);
  for (let i = 0; i < n; i++) {
    if (la[i] !== lb[i]) {
      return `    line ${i + 1}:\n      - committed:  ${JSON.stringify(la[i])}\n      + regenerated: ${JSON.stringify(lb[i])}`;
    }
  }
  return "    (files differ in length only)";
}

// Part A also carries the emitter's MEMORY. Without it this gate is a tautology
// on the far side of a write: `expected` is build() and `current` is whatever
// build() last wrote, so once emit --write has run, current === expected BY
// CONSTRUCTION and the gate prints a clean PASS over content the write destroyed.
// design/emit-manifest.json breaks the tautology — it records what the emitter
// last emitted, so a region holding bytes the emitter never produced is named as
// UNATTRIBUTED whether or not it also drifts. Crucially the remedy printed for
// that case is NOT "run --write" (which is the very command that deletes it).
let manifestRegions = {};
let manifestErr = null;
try { manifestRegions = readManifest() ?? {}; }
catch (e) { manifestErr = e.message; }
if (manifestErr) fail(`  FAIL ${MANIFEST_PATH}: ${manifestErr}`);

let unattributedSeen = false;
function reportUnattributed(r) {
  unattributedSeen = true;
  const lost = lostLines(r.currentRegion, r.expectedRegion);
  fail(`  UNATTRIBUTED ${r.name} (${r.path}) — the generated region holds bytes design/emit.mjs never wrote`);
  if (lost.length) {
    console.error(`    ${lost.length} line(s) present on disk and absent from the regenerated output:`);
    for (const l of lost.slice(0, 8)) console.error(`      - ${l}`);
    if (lost.length > 8) console.error(`      … and ${lost.length - 8} more`);
  }
  console.error(`    Do NOT "fix" this with --write: that DELETES the lines above (see commit 1d928b3bf).`);
  console.error(`    Hand-written? move it outside the BEGIN/END GENERATED marker. Genuinely generated? node design/emit.mjs --adopt`);
}

console.log("design/check.mjs — Part A: per-surface byte parity + generated-region attribution");
for (const r of evaluateAll()) {
  if (r.error) { fail(`  FAIL ${r.name}: ${r.error}`); continue; }
  if (r.current == null) { fail(`  FAIL ${r.name}: committed file ${r.path} is missing`); continue; }
  const attributed = !manifestErr && attribute(r, manifestRegions) === "attributed";
  if (!attributed) {
    reportUnattributed(r);
  } else if (r.current !== r.expected) {
    fail(`  DRIFT ${r.name} (${r.path}) — committed output is STALE vs design/tokens.json`);
    console.error(firstDiff(r.current, r.expected));
  } else {
    console.log(`  ok   ${r.name} (${r.path})`);
  }
}

// Paper-editor token mirror: a second generation hop (paper-surface.css → the
// styles.css bundle's marked region). Same shared transform emit.mjs drives, so
// a stale committed mirror trips HERE the same way a stale surface trips above.
{
  const mr = evaluateMirror(repoRoot);
  const mu = mr.error ? mr : { ...mr, currentRegion: mr.currentBlock, expectedRegion: mr.generatedBlock };
  if (mr.error) fail(`  FAIL ${mr.name}: ${mr.error}`);
  else if (mr.current == null) fail(`  FAIL ${mr.name}: committed file ${mr.path} is missing`);
  else if (manifestErr || attribute(mu, manifestRegions) !== "attributed") reportUnattributed(mu);
  else if (mr.current !== mr.expected) {
    fail(`  DRIFT ${mr.name} (${mr.path}) — the paper-editor mirror is STALE vs the assembled package surface`);
    console.error(firstDiff(mr.current, mr.expected));
  } else {
    console.log(`  ok   ${mr.name} (${mr.path})`);
  }
}
if (FAULT.has("A")) fail("  Part A FAIL: injected fault (--selftest; Part A prints per-item ok lines and gates no part-summary)");
// The blanket "Fix: --write" is safe ONLY where nothing is unattributed; where a
// region holds hand-written bytes, --write is the destructive act, not the fix.
if (failed && !unattributedSeen) console.error("\n  Fix: node design/emit.mjs --write\n");
else if (unattributedSeen) console.error("\n  Fix: relocate hand-written content outside the marker (--write would DELETE it), or --adopt if it is genuinely generated.\n");

export { unattributedSeen };
