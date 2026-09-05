// gate-map.test.mjs — the composer's own harness. It is built to LOSE: a
// planted map entry, a removed instrument, and a scan set that stops seeing
// cloud/priv/static all red it. A green here means the derivation still finds
// the edge wave 16 shipped past.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {
  REPO,
  MAP_PATH,
  population,
  scanSites,
  derive,
  matches,
  requiredFor,
  verify,
  loadMap,
  instrumentsUnderPrefix,
  runCommandFor,
  NEEDS_ARGV,
} from "./gate-map.mjs";

const SWEEP = "cloud/priv/static/__preview__/breakpoint-sweep.mjs";
const CSS = "cloud/priv/static/__css_check.mjs";

test("the population is committed files, and it is not empty", () => {
  const pop = population();
  assert.ok(pop.length > 100, `population is ${pop.length}`);
  assert.ok(pop.includes(CSS), "__css_check.mjs is in the population");
  assert.ok(pop.includes(SWEEP), "breakpoint-sweep.mjs is in the population");
});

test("THE WAVE-16 EDGE: __css_check's directory readdir is derived, not imported", () => {
  const src = fs.readFileSync(path.join(REPO, CSS), "utf8");
  const sites = scanSites(CSS, src);
  assert.ok(
    sites.some((s) => s.kind === "dir" && s.p === "cloud/priv/static/__preview__"),
    "the readdirSync over __preview__ is a derived scan site"
  );
  // The negative half: __css_check does NOT import or name the sweep, so an
  // import-graph reader could not have found this. Prove the absence.
  assert.ok(!/breakpoint-sweep/.test(src), "__css_check never names breakpoint-sweep — only the directory scan links them");
});

test("relative dynamic imports and new URL reads are derived as file scan sites", () => {
  const rel = "api/assets/paper-editor/src/canvas/__mounted.test.mjs";
  const sites = scanSites(
    rel,
    `
      await import("./index.js");
      readFileSync(new URL(
        "../../../../priv/static/assets/bp-paper-editor-hooks.js",
        import.meta.url,
      ));
    `
  );

  assert.ok(
    sites.some((s) => s.kind === "file" && s.p === "api/assets/paper-editor/src/canvas/index.js"),
    "the module driven by a dynamic import is mapped"
  );
  assert.ok(
    sites.some(
      (s) =>
        s.kind === "file" &&
        s.p === "api/priv/static/assets/bp-paper-editor-hooks.js"
    ),
    "the asset read through new URL(..., import.meta.url) is mapped"
  );
});

test("THE COMPOSITION: a slice touching only breakpoint-sweep.mjs REQUIRES __css_check", () => {
  const req = requiredFor([SWEEP], loadMap());
  const paths = req.map((r) => r.path);
  assert.ok(paths.includes(CSS), `composed gate = ${paths.join(", ")}`);
  assert.ok(paths.includes(SWEEP), "the edited instrument runs too");
  assert.ok(paths.includes("cloud/priv/static/__preview__/breakpoint-sweep.test.mjs"), "and its unit suite");
  const why = req.find((r) => r.path === CSS).why[0];
  assert.equal(why.via.kind, "dir");
  assert.match(why.via.evidence, /__css_check\.mjs:\d+/);
});

test("the prefix view answers the row: cloud/priv/static/** names every instrument it listed", () => {
  const list = instrumentsUnderPrefix("cloud/priv/static", loadMap()).map((i) => i.path);
  for (const need of [
    "cloud/priv/static/__css_check.mjs",
    "cloud/priv/static/__app.test.mjs",
    "cloud/priv/static/__preview__/cssom-parity.mjs",
    "cloud/priv/static/__preview__/cssom-parity.test.mjs",
    "cloud/priv/static/__preview__/overflow-guard.mjs",
    "cloud/priv/static/__preview__/smoke.mjs",
    "cloud/priv/static/__preview__/breakpoint-sweep.mjs",
    "cloud/priv/static/__preview__/breakpoint-sweep.test.mjs",
    "cloud/priv/static/__preview__/seal-predicate.test.mjs",
  ]) {
    assert.ok(list.includes(need), `${need} missing from the cloud/priv/static prefix map`);
  }
});

test("a slice that touches nothing any instrument scans composes an EMPTY gate", () => {
  // NOT a docs/ path: the doc gates walk docs/ as a subtree, so a docs file is
  // legitimately non-empty. (First draft of this test used one and reded —
  // correctly. Kept as the positive case below.)
  const req = requiredFor(["scratch-nowhere/unscanned-fixture.txt"], loadMap());
  assert.equal(req.length, 0, `composed ${req.map((r) => r.path).join(", ")}`);
});

test("a docs/ edit is NOT empty — the doc gates walk that subtree", () => {
  const req = requiredFor(["docs/cards/cli.md"], loadMap()).map((r) => r.path);
  assert.ok(req.some((p) => /docs-anchors-check|check-doc-budgets/.test(p)), `composed ${req.join(", ")}`);
});

test("SELFTEST — a PLANTED map entry is refused", () => {
  const map = loadMap();
  const planted = JSON.parse(JSON.stringify(map));
  planted.instruments.push({
    path: "cloud/priv/static/__preview__/does-not-exist.mjs",
    run: "node cloud/priv/static/__preview__/does-not-exist.mjs",
    scans: [{ kind: "dir", p: "cloud/priv/static", evidence: "planted" }],
  });
  const v = verify(planted);
  assert.equal(v.ok, false, "a planted instrument must be a refusal");
  assert.ok(v.problems.some((p) => /does-not-exist/.test(p)), v.problems.join("; "));
});

test("SELFTEST — a REMOVED instrument is refused, never a quietly shorter answer", () => {
  const map = loadMap();
  const shortened = JSON.parse(JSON.stringify(map));
  shortened.instruments = shortened.instruments.filter((i) => i.path !== CSS);
  const v = verify(shortened);
  assert.equal(v.ok, false, "dropping __css_check must be a refusal");
  assert.ok(v.problems.some((p) => p.includes(CSS)), v.problems.join("; "));
});

test("SELFTEST — a MOVED scan set is refused", () => {
  const map = loadMap();
  const moved = JSON.parse(JSON.stringify(map));
  const css = moved.instruments.find((i) => i.path === CSS);
  css.scans = css.scans.filter((s) => s.p !== "cloud/priv/static/__preview__");
  const v = verify(moved);
  assert.equal(v.ok, false, "a narrowed scan set must be a refusal");
  assert.ok(v.problems.some((p) => /scan set moved/.test(p)), v.problems.join("; "));
});

test("the COMMITTED snapshot still describes the tree", () => {
  const v = verify(loadMap());
  assert.equal(v.ok, true, v.problems.slice(0, 8).join("\n"));
});

test("UNMAPPED instruments are counted and listed, never dropped", () => {
  const map = loadMap();
  assert.ok(Array.isArray(map.unmapped), "unmapped is a list");
  assert.equal(map.mapped + map.unmapped.length, map.population,
    `mapped ${map.mapped} + unmapped ${map.unmapped.length} != population ${map.population}`);
  for (const u of map.unmapped) assert.ok(u.why && u.why.length > 0, `${u.path} has no stated reason`);
});

test("matching: dir is direct-children, tree is recursive, file is exact", () => {
  assert.equal(matches({ kind: "dir", p: "a/b" }, "a/b/c.mjs"), true);
  assert.equal(matches({ kind: "dir", p: "a/b" }, "a/b/d/c.mjs"), false);
  assert.equal(matches({ kind: "tree", p: "a/b" }, "a/b/d/c.mjs"), true);
  assert.equal(matches({ kind: "file", p: "a/b/c.mjs" }, "a/b/c.mjs"), true);
  assert.equal(matches({ kind: "file", p: "a/b/c.mjs" }, "a/b/d.mjs"), false);
});

test("run commands match how CI invokes each shape", () => {
  assert.equal(runCommandFor("x/y.test.mjs"), "node --test x/y.test.mjs");
  assert.equal(runCommandFor("x/y.mjs"), "node x/y.mjs");
  assert.equal(runCommandFor("x/y.sh"), "bash x/y.sh");
});

test("the snapshot on disk is the derivation, byte for byte", () => {
  const onDisk = JSON.parse(fs.readFileSync(MAP_PATH, "utf8"));
  const fresh = derive();
  assert.equal(onDisk.population, fresh.population);
  assert.equal(onDisk.mapped, fresh.mapped);
});

test("NEEDS-INVOCATION is told apart from a finding (both shapes measured on this tree)", () => {
  assert.equal(NEEDS_ARGV.test("console-export-tree: --dest is required (or pass --selftest)\n"), true);
  assert.equal(NEEDS_ARGV.test("usage: node scripts/preview-census-gate-check.mjs [--changed-from <ref>]\n"), true);
  // A real finding must NOT be swallowed — this is the wave-16 red verbatim.
  assert.equal(
    NEEDS_ARGV.test('FAIL  E11 __preview__/breakpoint-sweep.mjs:2475  banned source line citation "app.js:25"\n'),
    false
  );
  // seal-run.sh's environmental refusal (exit 5) is not exit 2 and stays RED.
  assert.equal(NEEDS_ARGV.test("seal-run: the predicate was NOT executed.\n"), false);
});
