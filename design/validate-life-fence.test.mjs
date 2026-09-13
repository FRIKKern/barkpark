// design/validate-life-fence.test.mjs — the standing regression test proving
// design/validate.mjs' lifecycle gate DERIVES its required-state set from
// design/status-manifest.json instead of carrying a closed literal.
// Zero-dep (node:test + node:assert). Run: node design/validate-life-fence.test.mjs
//
// WHY THIS FILE EXISTS. validate.mjs used to hold
//   const REQUIRED_LIFE = ["in_progress", …, "researching"];
// — a hardcoded 9-element literal. A genuinely new lifecycle state added to
// design/status-manifest.json (and to every surface the Part-5 gate covers) but
// NOT added to that literal was SILENTLY SKIPPED: validate.mjs stayed green while
// design/tokens.json carried no lifecycle entry for it. That is the vacuous-guard
// shape — a gate whose subject set cannot grow. Nothing tested it, so reverting
// the derivation to a literal reds nothing.
//
// PROVEN ABLE TO FAIL BY MUTATION. Each test below drives the REAL validate.mjs
// CLI against a throwaway copy of design/ whose status-manifest.json has been
// mutated, and asserts the exit code + the message that names the state.
//
//   Revert `const REQUIRED_LIFE = Object.keys(manifest.statuses)` in
//   design/validate.mjs to the old 9-element literal and these four go RED
//   (measured: `# pass 1 / # fail 4`):
//     - "a state added to the manifest but absent from tokens.json reds validate"
//     - "a state added to the manifest but unmapped in EXPECTED_ROLE reds validate"
//     - "a state REMOVED from the manifest reds validate"
//     - "an empty .statuses reds validate instead of checking nothing"
//   With the literal every one of them exits 0: the added state is never looked
//   at, the removed one is still checked from the literal, and an emptied
//   manifest changes nothing the validator reads.
//
//   The "(control)" test stays GREEN in both directions, so it pins the opposite
//   failure — a derivation so eager it reds an untouched tree — and proves the
//   four reds above measure the mutation, not the copy step.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, cpSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

// Copy design/ into a throwaway dir and run the COPIED validate.mjs, which
// resolves tokens.json + status-manifest.json relative to its own location — so
// the mutation is applied to the copy and the real tree is never touched.
// `mutate` receives the parsed status-manifest.json and returns the object to
// write back (or mutates it in place).
function runWithManifest(mutate) {
  const dir = mkdtempSync(join(tmpdir(), "bp-validate-life-"));
  try {
    cpSync(here, dir, { recursive: true });
    const mp = join(dir, "status-manifest.json");
    const m = JSON.parse(readFileSync(mp, "utf8"));
    writeFileSync(mp, JSON.stringify(mutate(m) ?? m, null, 2) + "\n");
    const r = spawnSync(process.execPath, [join(dir, "validate.mjs")], { encoding: "utf8" });
    return { status: r.status, out: `${r.stdout}${r.stderr}` };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// (a) THE MUTATION. A synthetic state in the manifest that no surface wired.
test("a state added to the manifest but absent from tokens.json reds validate", () => {
  const { status, out } = runWithManifest((m) => {
    m.statuses.synthetic_state = "open";
  });
  assert.notEqual(status, 0, `expected a non-zero exit, got ${status}\n${out}`);
  assert.match(out, /lifecycle\.synthetic_state is required/,
    `the failure must NAME the unwired state\n${out}`);
});

// (b) The wiring ratchet's forward arm, isolated: even with a tokens.json entry
// present, an EXPECTED_ROLE that does not map the state is an error rather than
// an undefined-comparison accident.
test("a state added to the manifest but unmapped in EXPECTED_ROLE reds validate", () => {
  const dir = mkdtempSync(join(tmpdir(), "bp-validate-life-role-"));
  try {
    cpSync(here, dir, { recursive: true });
    const mp = join(dir, "status-manifest.json");
    const m = JSON.parse(readFileSync(mp, "utf8"));
    m.statuses.synthetic_state = "open";
    writeFileSync(mp, JSON.stringify(m, null, 2) + "\n");
    // Give tokens.json a fully-formed entry for the new state, cloned from a
    // shipped one, so `lifecycle.<state> is required` can NOT be what fires.
    const tp = join(dir, "tokens.json");
    const t = JSON.parse(readFileSync(tp, "utf8"));
    t.lifecycle.synthetic_state = JSON.parse(JSON.stringify(t.lifecycle.ready));
    writeFileSync(tp, JSON.stringify(t, null, 2) + "\n");
    const r = spawnSync(process.execPath, [join(dir, "validate.mjs")], { encoding: "utf8" });
    const out = `${r.stdout}${r.stderr}`;
    assert.notEqual(r.status, 0, `expected a non-zero exit, got ${r.status}\n${out}`);
    assert.match(out, /EXPECTED_ROLE does not map it/, out);
    assert.match(out, /synthetic_state/, out);
    assert.doesNotMatch(out, /lifecycle\.synthetic_state is required/,
      `the tokens.json entry was supposed to be present — this arm must isolate the EXPECTED_ROLE gap\n${out}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// (c) The ratchet's reverse arm: a state RETIRED from the manifest leaves a stale
// expectation behind. With the old literal this direction was invisible too.
test("a state REMOVED from the manifest reds validate", () => {
  const { status, out } = runWithManifest((m) => {
    delete m.statuses.researching;
  });
  assert.notEqual(status, 0, `expected a non-zero exit, got ${status}\n${out}`);
  assert.match(out, /EXPECTED_ROLE maps lifecycle\.researching/, out);
});

// (d) An empty .statuses must not pass vacuously — the derivation's own floor.
test("an empty .statuses reds validate instead of checking nothing", () => {
  const { status, out } = runWithManifest((m) => {
    m.statuses = {};
  });
  assert.notEqual(status, 0, `expected a non-zero exit, got ${status}\n${out}`);
  assert.match(out, /\.statuses is empty or missing/, out);
});

// (e) THE CONTROL. An unmutated copy passes — so (a)-(d) measure the mutation,
// not the copy step.
test("the unmutated tree passes (control)", () => {
  const { status, out } = runWithManifest((m) => m);
  assert.equal(status, 0, `expected exit 0 on an unmutated copy, got ${status}\n${out}`);
  assert.match(out, /lifecycle states: 9 reconciled 1:1/, out);
});
