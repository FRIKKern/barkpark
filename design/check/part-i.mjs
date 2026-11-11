// design/check/part-i.mjs — Part I of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { attribute, lostLines, regionDigest } from "../emit.mjs";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part I: the write fence's own predicates, proven able to fail ────────────
// Part A above is the fence's REPORTING half; `run()` in emit.mjs is its
// BLOCKING half. Both rest on exactly two predicates — attribute() and
// lostLines() — and every proof of them so far has been a manual mutation an
// author ran once and reverted. That is the failure mode this whole epic is
// about: an instrument nobody can regress noisily. Neutering attribute() to
// return "attributed" (or lostLines() to return []) would leave every other
// gate in this repo green while the fence quietly stopped fencing.
//
// These are synthetic fixtures, NOT a read of the tree, so they cost nothing
// and cannot flake on real content. They do not cover run()'s all-or-nothing
// pre-flight — that needs a process-level test and a doc-gates.yml entry, and
// is filed as cch-w1-emit-fence-regression-test.
{
  const failedBeforeI = failed;
  console.log("design/check.mjs — Part I: write-fence predicates");
  const region = "a\nb\n";
  const unit = (cur) => ({ path: "fixture/x", currentRegion: cur, expectedRegion: region });
  const digest = regionDigest(region);

  // The three attribution outcomes. If any collapses into "attributed", the
  // fence stops refusing and hand-written content becomes deletable again.
  const cases = [
    ["byte-identical region is attributed", unit(region), { "fixture/x": digest }, "attributed"],
    ["a hand-edited region is UNattributed", unit("a\nb\nhand-written\n"), { "fixture/x": digest }, "unattributed"],
    ["a region with no ledger entry is unknown", unit(region), {}, "unknown"],
    ["an errored/unreadable region is unknown", { path: "fixture/x", error: "boom" }, { "fixture/x": digest }, "unknown"],
  ];
  for (const [what, u, regions, want] of cases) {
    const got = attribute(u, regions);
    if (got !== want) fail(`  Part I FAIL: ${what} — attribute() returned ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
  }

  // lostLines() is what turns a refusal into a USEFUL one: it names the bytes
  // that would die. Returning [] would keep the fence blocking but make it mute,
  // and a mute refusal is the one a developer clears with --force.
  const lost = lostLines("a\nkeep-me\nb\n", region);
  if (lost.length !== 1 || lost[0] !== "keep-me")
    fail(`  Part I FAIL: lostLines() must name the one dropped line, got ${JSON.stringify(lost)}`);
  // A pure token edit drops only the line it truly replaces — not the block.
  const swap = lostLines("--x: #aaa;\n--y: 1;\n", "--x: #bbb;\n--y: 1;\n");
  if (swap.length !== 1 || swap[0] !== "--x: #aaa;")
    fail(`  Part I FAIL: lostLines() over-reported a token edit, got ${JSON.stringify(swap)}`);
  // Blank lines are noise, never "lost work" — reporting them would train
  // readers to skim the list the fence needs them to read.
  if (lostLines("a\n\n\nb\n", region).length !== 0)
    fail(`  Part I FAIL: lostLines() must ignore blank lines, got ${JSON.stringify(lostLines("a\n\n\nb\n", region))}`);

  if (FAULT.has("I")) fail("  Part I FAIL: injected fault (--selftest)");
  if (failed === failedBeforeI)
    console.log(`  ok   ${cases.length} attribution outcomes + 3 lostLines properties`);
}
