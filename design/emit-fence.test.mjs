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
import { ARTIFACTS } from "./emit.mjs";
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
  const files = new Set([...ARTIFACTS.map((a) => a.path), SURFACE_PATH, BUNDLE_PATH]);
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
