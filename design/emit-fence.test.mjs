// design/emit-fence.test.mjs — the standing regression test for the `--write`
// ATTRIBUTION FENCE in design/emit.mjs (charter cloud-console-hardening D21/D41).
// Zero-dep (node:test + node:assert). Run: node design/emit-fence.test.mjs
//
// WHY THIS FILE EXISTS. emit.mjs' `--write` refuses to replace a generated region
// whose SHA-256 does not match design/emit-manifest.json — the fence that stops a
// regeneration silently deleting hand-written CSS placed inside a marker (commit
// 1d928b3bf deleted 33 `.bp-lc-*` rules that way). The fence's HELPER functions
// (attribute/lostLines) are unit-tested in design/check.mjs, but the run() PRE-
// FLIGHT that actually REFUSES the write — the `process.exit(1)` at the point of
// loss — had NO test: deleting that block from run() reds nothing (the reflexive
// D40 gap this slice closes). This suite drives the REAL emit.mjs CLI against a
// throwaway copy of the tree it reads, so run()'s refusal itself is now able to
// fail.
//
// PROVEN ABLE TO FAIL BY MUTATION (charter D41 — a boundary must be machine-
// checked, a comment is not a tripwire): delete the `if (mode === "write") { const
// blocked = … process.exit(1) … }` pre-flight block from emit.mjs run() and
// tests (a)/(b) below go RED (the write proceeds, the sentinel is deleted, exit 0);
// restore it and they go GREEN. The "does not over-fire" test (d) stays GREEN in
// both directions, so it pins the opposite failure: a fence tight enough to refuse
// a legitimate token edit.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync, mkdirSync, cpSync, copyFileSync, readFileSync, writeFileSync, realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ARTIFACTS, AUDIT_ACTIONS_PATH } from "./emit.mjs";
import { SURFACE_PATH, BUNDLE_PATH } from "./paper-editor-mirror.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..");

// A CSS custom-property line that emit.mjs will NEVER regenerate — so it reads as
// UNATTRIBUTED hand-written content the moment it lands inside a marker, and
// lostLines() reports it verbatim (it is non-empty, the property that clears the
// blank-line filter). This stands in for the 33 `.bp-lc-*` rules of 1d928b3bf.
const CSS_SENTINEL = "  --bp-hand-authored-sentinel-DO-NOT-DELETE: 1;";
// A whole-file (Go) artifact's region IS the entire file, so any hand-written line
// makes its digest miss the ledger. A trailing comment is enough and never compiles.
const GO_SENTINEL = "// bp-hand-authored-sentinel-DO-NOT-DELETE";

// Build a throwaway copy of EXACTLY the tree emit.mjs reads: all of design/ (its
// own source + tokens.json + themes + derive + the mirror module + the manifest)
// plus every ARTIFACTS path and the paper-editor mirror's two files. emit.mjs
// derives repoRoot from its OWN location, so running the COPY makes the temp dir
// the repo root — no env override needed, and the real tree is never touched.
function makeTree() {
  // realpath the temp root: on macOS $TMPDIR lives under a /var → /private/var
  // symlink, and emit.mjs' CLI self-detection compares process.argv[1] against
  // fileURLToPath(import.meta.url) (which node realpaths). A raw /var path would
  // silently skip run() — the subprocess would exit 0 having done nothing.
  const root = realpathSync(mkdtempSync(join(tmpdir(), "emit-fence-")));
  tempRoots.push(root);
  cpSync(join(repoRoot, "design"), join(root, "design"), { recursive: true });
  const files = new Set([...ARTIFACTS.map((a) => a.path), SURFACE_PATH, BUNDLE_PATH, AUDIT_ACTIONS_PATH]);
  for (const rel of files) {
    const dst = join(root, rel);
    mkdirSync(dirname(dst), { recursive: true });
    copyFileSync(join(repoRoot, rel), dst);
  }
  return root;
}

// Every makeTree() root is removed when the process exits. Without this the
// suite leaked ~10 MB per test case into $TMPDIR, which macOS never cleans:
// one evening of CI/wave runs minted 3,746 emit-fence-* dirs (37 GB) and
// filled the machine's boot disk. The exit hook (not per-test teardown)
// keeps the trees inspectable while the run is alive and costs one rm each.
const tempRoots = [];
process.on("exit", () => {
  for (const root of tempRoots) {
    try {
      rmSync(root, { recursive: true, force: true });
    } catch {
      // exit handler: nothing sane to do, and the leak signature in noo-noo
      // sweeps stragglers.
    }
  }
});

function emit(root, args) {
  const r = spawnSync(process.execPath, [join(root, "design", "emit.mjs"), ...args], {
    encoding: "utf8",
  });
  return { code: r.status, out: r.stdout ?? "", err: r.stderr ?? "" };
}

const readIn = (root, rel) => readFileSync(join(root, rel), "utf8");
const writeIn = (root, rel, text) => writeFileSync(join(root, rel), text);

// Splice a sentinel line into the FIRST line inside a css artifact's tokens marker,
// simulating a developer hand-editing rules inside the generated block.
function injectInsideMarker(root, rel) {
  const before = readIn(root, rel);
  const after = before.replace(
    /(BEGIN GENERATED: tokens[^\n]*\n)/,
    `$1${CSS_SENTINEL}\n`,
  );
  assert.notEqual(after, before, `could not find the tokens marker in ${rel} to inject into`);
  writeIn(root, rel, after);
}

const MARKER_CSS = "cloud/priv/static/app.css";       // css: tokens-marker surface
const WHOLE_FILE = "internal/taskboard/tokens_gen.go"; // go: whole-file artifact

// ── harness sanity: a faithful copy passes --check clean ─────────────────────
// If this fails the temp tree is not a faithful mirror and every fence assertion
// below is meaningless. Deleting run()'s write-fence does NOT affect --check, so
// this stays green under the mutation — it is the control, not the tripwire.
test("harness: a fresh copy of the tree passes `emit --check` (exit 0)", () => {
  const root = makeTree();
  const r = emit(root, ["--check"]);
  assert.equal(r.code, 0, `--check should be clean on a faithful copy\n${r.out}\n${r.err}`);
});

// ── (a) REFUSE an unattributed MARKER-SPAN write ─────────────────────────────
test("fence REFUSES an unattributed marker-span write: non-zero exit, sentinel SURVIVES", () => {
  const root = makeTree();
  injectInsideMarker(root, MARKER_CSS);
  const r = emit(root, ["--write"]);
  assert.notEqual(r.code, 0, `--write must exit non-zero on unattributed content\n${r.out}\n${r.err}`);
  assert.match(r.err, /REFUSED/, "the refusal must announce itself (REFUSED)");
  // The whole point: nothing was written, so the hand-written line is still there.
  assert.ok(
    readIn(root, MARKER_CSS).includes(CSS_SENTINEL),
    "the sentinel inside the marker was DELETED — the fence did not hold",
  );
  // and the fence must NAME the line it would have dropped (lostLines reporting).
  assert.ok(r.err.includes(CSS_SENTINEL.trim()), "the refusal must name the line it would delete");
});

// ── (a) REFUSE an unattributed WHOLE-FILE write ──────────────────────────────
test("fence REFUSES an unattributed whole-file write: non-zero exit, sentinel SURVIVES", () => {
  const root = makeTree();
  const before = readIn(root, WHOLE_FILE);
  writeIn(root, WHOLE_FILE, `${before}\n${GO_SENTINEL}\n`);
  const r = emit(root, ["--write"]);
  assert.notEqual(r.code, 0, `--write must exit non-zero on an unattributed whole file\n${r.out}\n${r.err}`);
  assert.match(r.err, /REFUSED/, "the refusal must announce itself (REFUSED)");
  assert.ok(
    readIn(root, WHOLE_FILE).includes(GO_SENTINEL),
    "the sentinel appended to the whole-file artifact was DELETED — the fence did not hold",
  );
});

// ── (a) --write --force performs the deletion AND names the lines ────────────
test("`--write --force` OVERRIDES the fence: sentinel is deleted, and the line is NAMED", () => {
  const root = makeTree();
  injectInsideMarker(root, MARKER_CSS);
  const r = emit(root, ["--write", "--force"]);
  assert.equal(r.code, 0, `--write --force should complete the regeneration (exit 0)\n${r.out}\n${r.err}`);
  assert.ok(
    !readIn(root, MARKER_CSS).includes(CSS_SENTINEL),
    "--force must actually delete the unattributed line",
  );
  // "while naming the lines" — DELETING banner + the exact bytes it removed.
  assert.match(r.err, /DELETING/, "--force must announce the override (DELETING)");
  assert.ok(r.err.includes(CSS_SENTINEL.trim()), "--force must name the line it deleted");
});

// ── (b) does NOT over-fire: a legitimate tokens.json edit still regenerates ───
// This is the property that catches an OVER-TIGHT fence — one that refuses a write
// even where the on-disk region is attributable (drift, but the ledger matches).
// Editing type.reading.body.size drifts paper-surface.css legitimately; its region
// is still attributed, so `--write` must regenerate it and exit 0 with no refusal.
test("fence does NOT over-fire: a legitimate design/tokens.json edit regenerates, exit 0, no refusal", () => {
  const root = makeTree();
  const tok = JSON.parse(readIn(root, "design/tokens.json"));
  const oldSize = tok.type.reading.body.size;
  const newSize = oldSize + 1; // a real, attributed drift — NOT a color (seam guard is color-only)
  tok.type.reading.body.size = newSize;
  writeIn(root, "design/tokens.json", `${JSON.stringify(tok, null, 2)}\n`);

  const r = emit(root, ["--write"]);
  assert.equal(r.code, 0, `a legitimate token edit must write cleanly\n${r.out}\n${r.err}`);
  assert.doesNotMatch(r.err, /REFUSED/, "the fence over-fired on an attributed, legitimately-drifted region");
  assert.ok(
    readIn(root, SURFACE_PATH).includes(`--tok-reading-body-size: ${newSize}px;`),
    "the edited token did not reach the regenerated paper-surface.css",
  );
});

// ── (c) TWO generated regions in ONE file attribute INDEPENDENTLY ─────────────
// The ledger is keyed `<path>#<artifact name>`, not by path alone. A path-keyed
// ledger gives two regions in one file ONE slot: last write wins, the loser reads
// "unattributed" forever (design/check.mjs red permanently, `--write` refusing
// all-or-nothing). The registry comment invites a second markerBegin/markerEnd per
// file, so this is a shape the emitter must actually hold.
//
// PROVEN ABLE TO FAIL BY MUTATION (run 2026-08-17): revert regionKey() to
// `u.path`, re-bless with --adopt so the path-keyed world is self-consistent, and
// `node --test design/emit-fence.test.mjs` reports `# fail 2` — the two-slot test
// below and the "hand-edit the SECOND region" case go RED (--adopt writes ONE
// app.js slot; the loser is UNATTRIBUTED whatever anyone does to it). The
// "hand-edit the FIRST region" case stays green in both directions: under the
// path key the surviving slot belongs to the LAST artifact registered, so the
// first region reds for the wrong reason — it pins the mirror-image behaviour,
// not the collision. All three are green with the composite key.
//
// The second region is registered INSIDE THE TEMP COPY (never in the real
// ARTIFACTS): a probe marker appended to app.js plus an ARTIFACTS.push() spliced
// into the copied emit.mjs, so the real registry is never widened by a test.
const TWO_REGION_FILE = "cloud/priv/static/app.js"; // already owns two real regions
const PROBE_NAME = "second-region probe";
const PROBE_BEGIN = "/* BEGIN GENERATED: bp-probe */";
const PROBE_END = "/* END GENERATED: bp-probe */";
const PROBE_BODY = "    var BP_PROBE = 1;";

function addSecondRegion(root) {
  // 1. the file grows a SECOND marker block, byte-identical to what the probe emits.
  const js = readIn(root, TWO_REGION_FILE);
  writeIn(root, TWO_REGION_FILE, `${js}\n${PROBE_BEGIN}\n${PROBE_BODY}\n${PROBE_END}\n`);
  // 2. the COPIED emitter registers it — pushed before evaluateAll() is defined so
  //    the CLI at the bottom of the module sees the extra artifact.
  const src = readIn(root, "design/emit.mjs");
  const anchor = "export function evaluateAll()";
  assert.ok(src.includes(anchor), "could not find evaluateAll() to register the probe artifact before");
  const push = `ARTIFACTS.push({ name: ${JSON.stringify(PROBE_NAME)}, path: ${JSON.stringify(TWO_REGION_FILE)}, kind: "css",
  markerBegin: ${JSON.stringify(PROBE_BEGIN)}, markerEnd: ${JSON.stringify(PROBE_END)},
  build: () => ${JSON.stringify(PROBE_BODY)} });\n\n`;
  writeIn(root, "design/emit.mjs", src.replace(anchor, push + anchor));
}

const manifestKeys = (root) =>
  Object.keys(JSON.parse(readIn(root, "design/emit-manifest.json")).regions);

test("two generated regions in ONE file each own a ledger slot and attribute independently", () => {
  const root = makeTree();
  addSecondRegion(root);

  // The probe is brand-new, so it is UNKNOWN until blessed — --adopt is the one
  // sanctioned way in, and it must not disturb the region already recorded there.
  const adopt = emit(root, ["--adopt"]);
  assert.equal(adopt.code, 0, `--adopt should succeed\n${adopt.out}\n${adopt.err}`);
  assert.match(adopt.out, /adopt second-region probe/, "--adopt did not bless the second region");

  // The expected slots are DERIVED from the registry, not quoted: app.js already
  // carries more than one real generated region (the bp-theme ids enum and the
  // audit action labels), and a quoted pair would red the day a third lands —
  // reporting a collision that is not there.
  const keys = manifestKeys(root).filter((k) => k.startsWith(`${TWO_REGION_FILE}#`));
  const realSlots = ARTIFACTS
    .filter((a) => a.path === TWO_REGION_FILE)
    .map((a) => `${TWO_REGION_FILE}#${a.name}`);
  assert.ok(realSlots.length >= 1, `${TWO_REGION_FILE} is no longer a registered artifact — re-point this test`);
  assert.deepEqual(
    keys.slice().sort(),
    [...realSlots, `${TWO_REGION_FILE}#${PROBE_NAME}`].sort(),
    `the ${realSlots.length + 1} regions of one file must hold ${realSlots.length + 1} distinct ledger slots (a path-keyed ledger holds one)`,
  );

  // Every region of the file attributed: --check is clean.
  const clean = emit(root, ["--check"]);
  assert.equal(clean.code, 0, `both regions must attribute after --adopt\n${clean.out}\n${clean.err}`);
  assert.doesNotMatch(clean.err, /UNATTRIBUTED/, "a region in the two-region file reads unattributed");
});

// Independence has a second half: a hand-edit of EITHER region must red on its OWN
// name and leave the other one attributed. Same predicate design/check.mjs Part A
// runs (attribute()), driven here through the emitter's own --check.
// Every region of the file is a case, the two REAL ones included: the audit action
// labels arm (cch-w65) is the standing form of that slice's hand-edit mutation
// proof — a label re-typed by hand inside the marker must red the gate on its own
// name, and it can only do so on the artifact-keyed ledger (charter D835).
const REGION_CASES = [
  ["the bp-theme ids", "cloud SPA theme ids", "BEGIN GENERATED: bp-theme ids"],
  ["the audit action labels", "cloud SPA audit action labels", "BEGIN GENERATED: audit action labels"],
  ["the probe", PROBE_NAME, PROBE_BEGIN],
];
for (const [which, edited, marker] of REGION_CASES) {
  test(`a hand-edit inside ${which} region of a multi-region file reds --check on that region ALONE`, () => {
    const root = makeTree();
    addSecondRegion(root);
    assert.equal(emit(root, ["--adopt"]).code, 0, "--adopt must bless every region first");

    const sentinel = "  var bpHandAuthoredSentinel = 1; // DO-NOT-DELETE";
    const before = readIn(root, TWO_REGION_FILE);
    const escaped = marker.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
    const after = before.replace(new RegExp(`(${escaped}[^\\n]*\\n)`), `$1${sentinel}\n`);
    assert.notEqual(after, before, `could not inject into ${which} region`);
    writeIn(root, TWO_REGION_FILE, after);

    const r = emit(root, ["--check"]);
    assert.notEqual(r.code, 0, `a hand-edit inside ${which} region must red --check\n${r.out}\n${r.err}`);
    assert.ok(
      r.err.includes(`UNATTRIBUTED ${edited}`) || r.err.includes(`DRIFT ${edited}`),
      `the report must name the edited region (${edited})\n${r.err}`,
    );
    for (const [, untouched] of REGION_CASES.filter(([, n]) => n !== edited)) {
      assert.ok(
        !r.err.includes(`UNATTRIBUTED ${untouched}`),
        `the UNTOUCHED region (${untouched}) was dragged down with its file-mate — the slots are not independent\n${r.err}`,
      );
    }
    // and the fence still refuses to write over the hand-edited bytes.
    const w = emit(root, ["--write"]);
    assert.notEqual(w.code, 0, "--write must refuse over a hand-edited region in a two-region file");
    assert.ok(readIn(root, TWO_REGION_FILE).includes(sentinel), "the sentinel was DELETED — the fence did not hold");
  });
}
