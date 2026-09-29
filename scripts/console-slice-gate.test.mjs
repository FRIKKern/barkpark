// console-slice-gate.test.mjs — the selftest for the composed console slice
// gate. Built to LOSE: every positive arm has a mutation beside it that must
// red, so a green here is evidence rather than a tally.
//
// The arms, and what each one can fail on:
//   1. THE WAVE-17 EDGE, on the REAL tree — app.css requires breakpoint-sweep.mjs.
//      Reds if breakpoint-sweep.mjs stops declaring the stylesheet it parses,
//      which is exactly how the edge was missing on origin/main a917280fb.
//   2. ITS CONTROL — the same map with that scan site removed must REFUSE, by
//      row name. Without this, arm 1 could be passing on an unfalsifiable map.
//   3. THE REFUSAL — the literal cch-w16-s6 gate (css_check + cssom-parity +
//      app.test + smoke + a grep) is refused, naming Leg A.
//   4. ITS CONTROL — a gate that names every required instrument is accepted.
//   5. THE HOP — breakpoint-sweep.test.mjs, which drives the sweep, is required.
//   6. ITS CONTROL — with the harness fence mutated to match nothing, it is not,
//      so arm 5 measures the hop and not gate-map's one-hop map.
//   7. THE HOP'S FENCE — the fenced hop is strictly smaller than the unfenced
//      one, so "the fence is documented" is not the only evidence it exists.
//   8. cchi-w37 — a slice editing a cloud/priv/static/*.mjs census must run
//      __css_check (E11 reads the DIRECTORY), and a gate naming only the census
//      is refused.
//   9. THE CLI — main() exits 1 on an axis-blind gate and 0 on a covering one,
//      so the exit vocabulary is measured and not just the library.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { verifyDerivation, requiredFor as gateMapRequiredFor } from "../tooling/gate-map/gate-map.mjs";
import {
  TEST_HARNESS,
  verifyEdges,
  transitiveHop,
  requiredGate,
  gateCoverage,
  main,
} from "./console-slice-gate.mjs";

const APP_CSS = "cloud/priv/static/app.css";
const SWEEP = "cloud/priv/static/__preview__/breakpoint-sweep.mjs";
const SWEEP_TESTS = "cloud/priv/static/__preview__/breakpoint-sweep.test.mjs";
const CSS_CHECK = "cloud/priv/static/__css_check.mjs";
const BINDING = "cloud/priv/static/__binding_census.mjs";

const v = verifyDerivation();
assert.equal(v.ok, true, `gate-map's derivation must be sound for this suite to mean anything: ${JSON.stringify(v.problems)}`);
const MAP = v.map;

const clone = (m) => JSON.parse(JSON.stringify(m));
const paths = (req) => req.map((r) => r.path);

function mapWithoutScan(instrumentPath, scannedPath) {
  const m = clone(MAP);
  const inst = m.instruments.find((i) => i.path === instrumentPath);
  assert.ok(inst, `${instrumentPath} is not in the derived map — the mutation has no subject`);
  const before = inst.scans.length;
  inst.scans = inst.scans.filter((s) => s.p !== scannedPath);
  assert.notEqual(inst.scans.length, before, `${instrumentPath} had no scan site for ${scannedPath} — the mutation changed nothing, so its control proves nothing`);
  return m;
}

test("1. the wave-17 edge holds on the real tree: an app.css slice must run Leg A", () => {
  const req = requiredGate([APP_CSS], MAP);
  assert.ok(
    paths(req).includes(SWEEP),
    `a slice touching ${APP_CSS} must run ${SWEEP} — Leg A derives the width axis from app.css's own @media preludes. Got: ${paths(req).join(", ")}`,
  );
});

test("2. CONTROL: with that scan site gone, the edge ratchet REFUSES by row name", () => {
  const mutated = mapWithoutScan(SWEEP, APP_CSS);
  const before = verifyEdges(MAP);
  assert.equal(before.ok, true, `the unmutated tree must satisfy the ratchet: ${before.problems.join(" | ")}`);
  const after = verifyEdges(mutated);
  assert.equal(after.ok, false, "removing the sweep's app.css scan site must REFUSE — a ratchet that cannot lose is a decoration");
  assert.match(after.problems.join(" "), /cch-w17-bl-css-slice-gate-must-include-leg-a/);
  assert.match(after.problems.join(" "), new RegExp(SWEEP.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("3. the literal cch-w16-s6 gate is REFUSED, and Leg A is among the names", () => {
  // Verbatim from the row: __css_check + cssom-parity + __app.test + smoke + a
  // baseline grep. Fully green on the builder's bytes; Leg A exited 2 on the
  // same bytes with "UNCOVERED breakpoint 830px".
  const w16s6 = [
    "node cloud/priv/static/__css_check.mjs",
    "node cloud/priv/static/__preview__/cssom-parity.mjs",
    "node --test cloud/priv/static/__app.test.mjs",
    "node cloud/priv/static/__preview__/smoke.mjs",
    'grep -n "max-width" cloud/priv/static/app.css',
  ].join("\n");
  const req = requiredGate([APP_CSS], MAP);
  const cov = gateCoverage(w16s6, req);
  assert.equal(cov.ok, false, "the gate that shipped the wave-17 red must not be accepted");
  assert.ok(paths(cov.missing).includes(SWEEP), `the refusal must name ${SWEEP}; it named ${paths(cov.missing).join(", ")}`);
  assert.ok(paths(cov.missing).includes(SWEEP_TESTS), `and the suite that reds off the same derivation: ${paths(cov.missing).join(", ")}`);
});

test("4. CONTROL: a gate naming every required instrument is accepted", () => {
  const req = requiredGate([APP_CSS], MAP);
  const composed = req.map((r) => r.run).join("\n");
  const cov = gateCoverage(composed, req);
  assert.equal(cov.ok, true, `the composed gate must satisfy itself; missing: ${paths(cov.missing).join(", ")}`);
});

test("5. the hop adds the suite that DRIVES the instrument whose axis moved", () => {
  const req = requiredGate([APP_CSS], MAP);
  assert.ok(paths(req).includes(SWEEP_TESTS), `${SWEEP_TESTS} re-counts the derived axis and reded 5 tests in wave 17`);
});

test("6. CONTROL: with the harness fence matching nothing, the hop adds nothing", () => {
  const base = gateMapRequiredFor([APP_CSS], MAP);
  assert.equal(
    paths(base).includes(SWEEP_TESTS),
    false,
    "gate-map's own one-hop map must NOT already contain the suite, or arm 5 is measuring gate-map and not the hop",
  );
  const nothing = transitiveHop(base, MAP, /$^/);
  assert.deepEqual(paths(nothing).sort(), paths(base).sort(), "a fence that matches nothing must add nothing");
});

test("7. the hop's fence is load-bearing: fenced is strictly smaller than unfenced", () => {
  const base = gateMapRequiredFor([APP_CSS], MAP);
  const fenced = transitiveHop(base, MAP);
  const unfenced = transitiveHop(base, MAP, /.*/);
  assert.ok(
    fenced.length < unfenced.length,
    `the fence must exclude something real (fenced ${fenced.length}, unfenced ${unfenced.length}) — measured on this tree the unfenced hop roughly doubles the gate`,
  );
  assert.ok(fenced.length > base.length, "…and must still add the suites it exists for");
  assert.ok(TEST_HARNESS.test(SWEEP_TESTS) && !TEST_HARNESS.test(SWEEP), "the fence must tell a harness from its subject");
});

test("8. cchi-w37: a cloud/priv/static/*.mjs slice must run __css_check, and a gate omitting it is refused", () => {
  const req = requiredGate([BINDING], MAP);
  assert.ok(
    paths(req).includes(CSS_CHECK),
    `__css_check reads the DIRECTORY (E11: banned source-line citations), so editing ${BINDING} requires it. Got: ${paths(req).join(", ")}`,
  );
  const shipped = `node ${BINDING}`;
  const cov = gateCoverage(shipped, req);
  assert.equal(cov.ok, false, "the cchi-w37 gate — the edited census and nothing else — must be refused");
  assert.ok(paths(cov.missing).includes(CSS_CHECK));
});

test("9. the CLI exit vocabulary: 1 for an axis-blind gate, 0 for a covering one", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "console-slice-gate-"));
  const blind = path.join(dir, "blind.txt");
  fs.writeFileSync(blind, "node cloud/priv/static/__css_check.mjs\n");
  const covering = path.join(dir, "covering.txt");
  fs.writeFileSync(covering, requiredGate([APP_CSS], MAP).map((r) => r.run).join("\n") + "\n");
  try {
    assert.equal(main([APP_CSS, "--gate", blind]), 1);
    assert.equal(main([APP_CSS, "--gate", covering]), 0);
    assert.equal(main([]), 2, "no files is a bad invocation (2), never a green");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
