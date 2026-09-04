// design/mirror-fence.test.mjs — the standing regression test for the ATTRIBUTION
// FENCE on the OTHER two writers of the paper-editor mirror region
// (charter cloud-console-hardening D21/D41). Zero-dep (node:test + node:assert).
// Run: node design/mirror-fence.test.mjs
//
// WHY THIS FILE EXISTS. design/emit-fence.test.mjs proves `node design/emit.mjs
// --write` refuses to replace an unattributed generated region. But TWO other
// commands write the SAME region — `api/assets/paper-editor/src/styles.css`
// between the `BEGIN/END GENERATED: paper-surface` markers:
//
//   • node design/paper-editor-mirror.mjs --write
//   • scripts/paper-editor-mirror-check.sh --write   (delegates to the above)
//
// Until this slice they wrote it unconditionally, never consulting
// design/emit-manifest.json — a side door around the fence through which the exact
// loss of commit 1d928b3bf (33 hand-written `.bp-lc-*` rules deleted by a
// regeneration) could still happen through a supported command. design/check.mjs
// caught the RESULT after the fact; nothing PREVENTED it.
//
// PROVEN ABLE TO FAIL BY MUTATION (charter D41): delete the `if (blocked && !force)
// { … process.exit(1) }` pre-flight from the CLI block of
// design/paper-editor-mirror.mjs and tests (a) and (b) go RED (the write proceeds,
// the sentinel is deleted, exit 0); restore it and they go GREEN. Test (d) stays
// GREEN in both directions — it pins the opposite failure, a fence tight enough to
// refuse a LEGITIMATE regeneration, and test (e) pins the manifest write that
// keeps a later `emit --check` green without an --adopt.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync, mkdirSync, cpSync, copyFileSync, readFileSync, writeFileSync,
  realpathSync, rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ARTIFACTS, AUDIT_ACTIONS_PATH, MANIFEST_PATH, regionDigest } from "./emit.mjs";
import { SURFACE_PATH, BUNDLE_PATH, MIRROR_NAME } from "./paper-editor-mirror.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..");

// A CSS custom-property line the mirror transform will NEVER regenerate — so it
// reads as UNATTRIBUTED hand-written content the moment it lands inside the
// marker, and lostLines() reports it verbatim. Stands in for 1d928b3bf's 33 rules.
const CSS_SENTINEL = "  --bp-hand-authored-sentinel-DO-NOT-DELETE: 1;";

const MIRROR_KEY = `${BUNDLE_PATH}#${MIRROR_NAME}`;
const SHELL = "scripts/paper-editor-mirror-check.sh";
// The shell wrapper's part 1/2 also reads the Studio inline <style>.
const HEEX = "api/lib/barkpark_web/layouts/root.html.heex";
// The editor rules the mirror check reads moved out of root.html.heex (edit-on-the-link slice 2).
const SHELL_CSS = "api/priv/static/assets/bp-paper-editor-shell.css";

const tempRoots = [];
process.on("exit", () => {
  for (const root of tempRoots) {
    try { rmSync(root, { recursive: true, force: true }); } catch { /* exit hook */ }
  }
});

// A throwaway copy of exactly the tree these commands read. The CLIs derive
// repoRoot from their OWN location, so running the COPY makes the temp dir the
// repo root — no env override, and the real tree is never touched.
// realpath the temp root: on macOS $TMPDIR is a /var → /private/var symlink and
// the CLI self-detection compares process.argv[1] against a realpath'd
// import.meta.url; a raw /var path silently skips the CLI (exit 0, nothing done).
function makeTree() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "mirror-fence-")));
  tempRoots.push(root);
  cpSync(join(repoRoot, "design"), join(root, "design"), { recursive: true });
  const files = new Set([
    ...ARTIFACTS.map((a) => a.path), SURFACE_PATH, BUNDLE_PATH, AUDIT_ACTIONS_PATH,
    SHELL, HEEX, SHELL_CSS,
  ]);
  for (const rel of files) {
    const dst = join(root, rel);
    mkdirSync(dirname(dst), { recursive: true });
    copyFileSync(join(repoRoot, rel), dst);
  }
  return root;
}

const readIn = (root, rel) => readFileSync(join(root, rel), "utf8");
const writeIn = (root, rel, text) => writeFileSync(join(root, rel), text);

function mirror(root, args) {
  const r = spawnSync(process.execPath, [join(root, "design", "paper-editor-mirror.mjs"), ...args], { encoding: "utf8" });
  return { code: r.status, out: r.stdout ?? "", err: r.stderr ?? "" };
}
function shell(root, args) {
  const r = spawnSync("bash", [join(root, SHELL), ...args], { encoding: "utf8", cwd: root });
  return { code: r.status, out: r.stdout ?? "", err: r.stderr ?? "" };
}
function emit(root, args) {
  const r = spawnSync(process.execPath, [join(root, "design", "emit.mjs"), ...args], { encoding: "utf8" });
  return { code: r.status, out: r.stdout ?? "", err: r.stderr ?? "" };
}

// Splice a sentinel as the FIRST line inside the paper-surface marker, simulating
// a developer hand-editing rules inside the generated block. The assertion is the
// point: a mutation that did not apply is not a catch.
function injectInsideMarker(root) {
  const before = readIn(root, BUNDLE_PATH);
  const after = before.replace(/(BEGIN GENERATED: paper-surface[^\n]*\n)/, `$1${CSS_SENTINEL}\n`);
  assert.notEqual(after, before, `could not find the paper-surface marker in ${BUNDLE_PATH} to inject into`);
  writeIn(root, BUNDLE_PATH, after);
  assert.ok(readIn(root, BUNDLE_PATH).includes(CSS_SENTINEL), "the sentinel did not land");
}

const manifestOf = (root) => JSON.parse(readIn(root, MANIFEST_PATH)).regions;

// ── harness control: a faithful copy is clean under BOTH checkers ─────────────
// If this fails the temp tree is not a faithful mirror and every assertion below
// is meaningless. Removing the fence does not affect check mode, so this is the
// control, not the tripwire.
test("harness: a fresh copy passes the mirror check AND `emit --check` (exit 0)", () => {
  const root = makeTree();
  const m = mirror(root, []);
  assert.equal(m.code, 0, `mirror check should be clean on a faithful copy\n${m.out}\n${m.err}`);
  const s = shell(root, []);
  assert.equal(s.code, 0, `${SHELL} should be clean on a faithful copy\n${s.out}\n${s.err}`);
  const e = emit(root, ["--check"]);
  assert.equal(e.code, 0, `emit --check should be clean on a faithful copy\n${e.out}\n${e.err}`);
});

// ── (a) the Node CLI REFUSES an unattributed write ───────────────────────────
test("`paper-editor-mirror.mjs --write` REFUSES an unattributed region: non-zero exit, sentinel SURVIVES, line NAMED", () => {
  const root = makeTree();
  injectInsideMarker(root);
  const r = mirror(root, ["--write"]);
  assert.notEqual(r.code, 0, `--write must exit non-zero on unattributed content\n${r.out}\n${r.err}`);
  assert.match(r.err, /REFUSED/, "the refusal must announce itself (REFUSED)");
  assert.ok(
    readIn(root, BUNDLE_PATH).includes(CSS_SENTINEL),
    "the sentinel inside the marker was DELETED — the fence did not hold",
  );
  assert.ok(r.err.includes(CSS_SENTINEL.trim()), "the refusal must name the line it would delete");
});

// ── (b) the SHELL wrapper REFUSES too (the second door) ──────────────────────
test("`scripts/paper-editor-mirror-check.sh --write` REFUSES an unattributed region: sentinel SURVIVES", () => {
  const root = makeTree();
  injectInsideMarker(root);
  const r = shell(root, ["--write"]);
  assert.notEqual(r.code, 0, `${SHELL} --write must exit non-zero on unattributed content\n${r.out}\n${r.err}`);
  assert.match(r.err, /REFUSED/, "the refusal must announce itself (REFUSED)");
  assert.ok(
    readIn(root, BUNDLE_PATH).includes(CSS_SENTINEL),
    "the sentinel inside the marker was DELETED through the shell wrapper — the side door is still open",
  );
  assert.ok(r.err.includes(CSS_SENTINEL.trim()), "the refusal must name the line it would delete");
});

// ── (c) --write --force performs the deletion AND names the lines ────────────
test("`--write --force` OVERRIDES the fence: sentinel is deleted, and the line is NAMED", () => {
  const root = makeTree();
  injectInsideMarker(root);
  const r = mirror(root, ["--write", "--force"]);
  assert.equal(r.code, 0, `--write --force should complete the regeneration (exit 0)\n${r.out}\n${r.err}`);
  assert.ok(!readIn(root, BUNDLE_PATH).includes(CSS_SENTINEL), "--force must actually delete the unattributed line");
  assert.match(r.err, /DELETING/, "--force must announce the override (DELETING)");
  assert.ok(r.err.includes(CSS_SENTINEL.trim()), "--force must name the line it deleted");
});

// Make a LEGITIMATE mirror drift: change a design token, let emit.mjs regenerate
// everything (including paper-surface.css, the mirror's source), then put the
// BUNDLE and its manifest slot back the way they were. Result: the mirror region
// on disk is stale but ATTRIBUTED — precisely the state a mirror --write is for.
function stageLegitimateDrift(root) {
  const bundleBefore = readIn(root, BUNDLE_PATH);
  const mirrorDigestBefore = manifestOf(root)[MIRROR_KEY];
  assert.ok(mirrorDigestBefore, `${MANIFEST_PATH} must already carry ${MIRROR_KEY}`);
  const tok = JSON.parse(readIn(root, "design/tokens.json"));
  tok.type.reading.body.size = tok.type.reading.body.size + 1; // real, attributed drift
  writeIn(root, "design/tokens.json", `${JSON.stringify(tok, null, 2)}\n`);
  const w = emit(root, ["--write"]);
  assert.equal(w.code, 0, `emit --write should succeed on a legitimate token edit\n${w.out}\n${w.err}`);
  writeIn(root, BUNDLE_PATH, bundleBefore);
  const man = JSON.parse(readIn(root, MANIFEST_PATH));
  man.regions[MIRROR_KEY] = mirrorDigestBefore;
  writeIn(root, MANIFEST_PATH, `${JSON.stringify(man, null, 2)}\n`);
  const pre = mirror(root, []);
  assert.notEqual(pre.code, 0, "staging failed: the mirror should be STALE before the write");
  assert.match(pre.err, /STALE/, `staging failed: expected a stale mirror\n${pre.out}\n${pre.err}`);
  return { bundleBefore, mirrorDigestBefore };
}

// ── (d) does NOT over-fire: an attributed, legitimately stale mirror regenerates ─
test("fence does NOT over-fire: a legitimate paper-surface.css change regenerates the mirror, exit 0, no refusal", () => {
  const root = makeTree();
  const { bundleBefore } = stageLegitimateDrift(root);
  const r = mirror(root, ["--write"]);
  assert.equal(r.code, 0, `--write must regenerate an ATTRIBUTED stale region\n${r.out}\n${r.err}`);
  assert.doesNotMatch(r.err, /REFUSED/, "an attributed region must not be refused");
  assert.match(r.out, /WROTE/, "the write must announce itself");
  assert.notEqual(readIn(root, BUNDLE_PATH), bundleBefore, "the mirror region was not actually rewritten");
});

// ── (e) a successful write UPDATES the manifest, so `--check` needs no --adopt ─
test("a successful mirror write records the region in emit-manifest.json (later check passes with NO --adopt)", () => {
  const root = makeTree();
  const { mirrorDigestBefore } = stageLegitimateDrift(root);
  const r = shell(root, ["--write"]);
  assert.equal(r.code, 0, `${SHELL} --write must regenerate an ATTRIBUTED stale region\n${r.out}\n${r.err}`);
  const after = manifestOf(root)[MIRROR_KEY];
  assert.notEqual(after, mirrorDigestBefore, `${MANIFEST_PATH} still holds the OLD mirror digest`);
  // and it is the digest of what is on disk NOW, not some other value
  const region = readIn(root, BUNDLE_PATH)
    .match(/BEGIN GENERATED: paper-surface[^\n]*\n([\s\S]*?)\n[ \t]*\/\* END GENERATED: paper-surface \*\//)[1];
  assert.equal(after, regionDigest(region), "the recorded digest does not describe the region on disk");
  // The property the criterion actually names: a later check is clean, no --adopt.
  const c = emit(root, ["--check"]);
  assert.equal(c.code, 0, `emit --check must pass after a mirror write, with no --adopt\n${c.out}\n${c.err}`);
  assert.match(c.out, /every generated region attributed/, "the mirror region must read as attributed");
  const m = mirror(root, []);
  assert.equal(m.code, 0, `the mirror check must pass after its own write\n${m.out}\n${m.err}`);
});

// ── (f) an unknown flag is still refused (the wrapper's argument contract) ────
test("the shell wrapper still refuses an unknown argument (exit 2) and --force without --write", () => {
  const root = makeTree();
  const bad = shell(root, ["--wat"]);
  assert.equal(bad.code, 2, `an unknown argument must exit 2\n${bad.out}\n${bad.err}`);
  const lonely = shell(root, ["--force"]);
  assert.equal(lonely.code, 2, `--force without --write must exit 2\n${lonely.out}\n${lonely.err}`);
});
