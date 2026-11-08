// __build_ownership.test.mjs — the package owns its build.
//
// Package sources give seven files in dist/. A build reads nothing outside the
// package and writes nothing outside its output directory. scripts/sync-barkpark.mjs
// is the one path out to Barkpark, and scripts/pack-check.mjs holds the tarball to
// this package. The editor-shell fragments are pinned, so an edit to one moves its pin in
// the same diff. The paper-surface fragments, which emit --write can edit, are held by
// relations and by sync-barkpark --check.
//
// Everything runs in temporary directories. The sync and pack paths run on synthetic
// trees with an injected build, so this file never writes a real Barkpark sink and
// never packs. Nothing here reads outside the package.
//
// Run: node src/__build_ownership.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { transform } from "esbuild";
import { assertExactOutputs, assertPackageInputs, buildLocal, DIST, LOCAL_OUTPUTS } from "../scripts/build-local.mjs";
import { inspectPack, REQUIRED } from "../scripts/pack-check.mjs";
import { ASSET_MANIFEST, assembleAsset, PACKAGE_ROOT, readFragments, readPackageFile, validateCuts, validateFragmentSizes, validateMarkers } from "../scripts/source-assets.mjs";
import { render } from "../scripts/surface.mjs";
import { BROWSER_SINKS, expectedSinks, parseArgs, PROFILE_SINK, RAW_SURFACE_SINK, RAW_TOKENS_SINK, runSync } from "../scripts/sync-barkpark.mjs";
import { validatePackageProfile } from "../scripts/surface-package.mjs";

const root = PACKAGE_ROOT;
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const scratch = mkdtempSync(path.join(tmpdir(), "bp-build-ownership-"));
const inScratch = (name) => {
  const dir = path.join(scratch, name);
  mkdirSync(dir, { recursive: true });
  return dir;
};
process.once("exit", () => rmSync(scratch, { recursive: true, force: true }));

let failures = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${String(error.message).split("\n").join("\n      ")}`);
  }
};

// emit never writes the shell fragments, so their bytes stay pinned. An edit moves these
// in the same diff. The paper-surface fragments are emit's to write, so they get relations.
const FRAGMENT_PINS = {
    "00-editor-shell-core.css": [39352, "dc39a687197622fe5e991842edb596171a193bb0729b16fb5bbbb065aa79e718"],
    "01-canvas-blocks-fields.css": [48261, "3074c3375dbfa9ae4762d0513aae1699672fefed9c8101df1f578575108c2d30"],
    "02-native-blocks-link-preview.css": [24059, "7b6bdef84cf23bf07a8a122415b85cd205bc094cc799a93bc539068128a9de6a"],
    "03-contextual-editors.css": [31385, "2dbb2786d2bfd0690be17faf7ad12c120e4cd27f91564ea7d85d7ba3742902e0"],
    "04-contextual-panels-gutter.css": [20668, "63c6dd1a684e9b124d7da380c825ae7df1e8f91005d184dbcbf0d5074e6ece16"],
};
const ASSEMBLED = { "editor-shell": "004898ef2561adc2a4f632f1a1effb99b5739928432294923412ed224279dcee" };
const MERMAID = "497f333123b6d476ef8f5290824db16ae3a9b2d967ed2a9d898375a519f939a9";

// ── fragments ──────────────────────────────────────────────────────────────

await check("the editor-shell fragments have their pinned size and hash", () => {
  const { dir } = ASSET_MANIFEST["editor-shell"];
  for (const [name, [size, digest]] of Object.entries(FRAGMENT_PINS)) {
    const bytes = readPackageFile(`${dir}/${name}`);
    assert.equal(bytes.length, size, `${dir}/${name} size`);
    assert.equal(sha(bytes), digest, `${dir}/${name} hash`);
  }
  assert.equal(sha(assembleAsset("editor-shell")), ASSEMBLED["editor-shell"], "editor-shell assembly digest");
});

// Relations, not digests: emit --write can edit a surface fragment, and that moves no pin
// here. The bytes a host gets are held by sync-barkpark --check.
await check("the fragments on disk are the manifest's, each within its limits", () => {
  for (const id of ["paper-surface", "editor-shell"]) {
    const { dir, fragments } = ASSET_MANIFEST[id];
    assert.deepEqual(fragments.map((f) => f.name).sort(), readdirSync(path.join(root, dir)).filter((name) => name !== ".DS_Store").sort(), `${id}: the manifest names exactly the files in ${dir}`);
    for (const { name, bytes } of readFragments(id)) assert.ok(bytes.length > 0, `${dir}/${name} is empty`);
    validateFragmentSizes(readFragments(id), ASSET_MANIFEST[id], id);
  }
});

await check("the manifest lists each asset's fragments in file name order", () => {
  for (const id of ["paper-surface", "editor-shell"]) {
    const names = ASSET_MANIFEST[id].fragments.map((f) => f.name);
    assert.deepEqual(names, [...names].sort(), `${id}: a swap in the manifest reorders the assembled bytes`);
  }
});

await check("the fragments concatenate with an empty separator", () => {
  for (const id of ["paper-surface", "editor-shell"]) {
    const assembled = assembleAsset(id);
    assert.ok(assembled.equals(Buffer.concat(readFragments(id).map((part) => part.bytes))), `${id} adds nothing between fragments`);
    assert.equal(assembled.at(-1), 10, `${id} keeps its final newline`);
  }
});

await check("the physical line budgets hold on every new file", () => {
  const lines = (rel) => readPackageFile(rel).reduce((count, byte) => count + (byte === 10 ? 1 : 0), 0);
  const budgets = {
    "scripts/source-assets.mjs": 260,
    "scripts/build-local.mjs": 240,
    "scripts/sync-barkpark.mjs": 360,
    "src/__build_ownership.test.mjs": 500,
    "src/bp-paper-mermaid.js": 236,
    LICENSE: 201,
  };
  for (const [rel, budget] of Object.entries(budgets)) assert.ok(lines(rel) <= budget, `${rel} has ${lines(rel)} lines, budget ${budget}`);
});

await check("a cut must fall at CSS depth zero", () => {
  const parts = (...texts) => texts.map((text, i) => ({ name: `f${i}.css`, bytes: Buffer.from(text) }));
  validateCuts(parts(".a { color: red; }\n", "/* b */ .b { background: url(x.png); content: \"}\"; }\n"));
  assert.throws(() => validateCuts(parts(".a { color: red;\n", "}\n")), /the cut after f0\.css is inside 1 open brace/);
  assert.throws(() => validateCuts(parts("/* open\n", "closed */\n")), /the cut after f0\.css is inside a comment/);
  assert.throws(() => validateCuts(parts('.a::after { content: "x\n', '"; }\n')), /the cut after f0\.css is inside a string/);
  assert.throws(() => validateCuts(parts(".a { background: url(x", ".png); }\n")), /the cut after f0\.css is inside a url\(\)/);
  assert.throws(() => validateCuts(parts("}\n")), /closes a brace it never opened/);
  assert.throws(() => validateCuts(parts(".a {\n")), /the end of the stylesheet is inside 1 open brace/);
});

await check("each generated marker is in fragment 01 exactly once", () => {
  const manifest = ASSET_MANIFEST["paper-surface"];
  assert.equal(manifest.markerFragment, "01-components-generated-theme.css");
  assert.equal(manifest.markers.length, 4);
  const real = readFragments("paper-surface");
  validateMarkers(real, manifest, "paper-surface");
  const marker = manifest.markers[0];
  const planted = (edit) => real.map((part) => part.name === manifest.markerFragment ? { name: part.name, bytes: Buffer.from(edit(part.bytes.toString("latin1")), "latin1") } : part);
  assert.throws(() => validateMarkers(planted((css) => css.replace(marker, "")), manifest), /appears 0 times/);
  assert.throws(() => validateMarkers(planted((css) => css + marker), manifest), /appears 2 times/);
  const moved = real.map((part) => part.name === "00-foundation-type.css" ? { name: part.name, bytes: Buffer.concat([part.bytes, Buffer.from(marker)]) } : part.name === manifest.markerFragment ? { name: part.name, bytes: Buffer.from(part.bytes.toString("latin1").replace(marker, ""), "latin1") } : part);
  assert.throws(() => validateMarkers(moved, manifest), /is in 00-foundation-type\.css, expected 01-components-generated-theme\.css/);
});

await check("a fragment that is too small, too large or missing its final newline is refused", () => {
  const manifest = ASSET_MANIFEST["paper-surface"];
  const name = manifest.fragments[0].name;
  const { floorBytes, capBytes } = manifest.fragments[0];
  assert.throws(() => validateFragmentSizes([{ name, bytes: Buffer.from("x\n") }], manifest), /outside/);
  assert.throws(() => validateFragmentSizes([{ name, bytes: Buffer.alloc(capBytes + 1, 10) }], manifest), /outside/);
  assert.throws(() => validateFragmentSizes([{ name, bytes: Buffer.alloc(floorBytes, 32) }], manifest), /final newline/);
  assert.throws(() => validateFragmentSizes([{ name: "new.css", bytes: Buffer.from("x\n") }], manifest), /not in the manifest/);
});

// ── reading only the package ───────────────────────────────────────────────

await check("a source that is a symlink is refused, wherever it points", () => {
  const fake = inScratch("symlink-root");
  writeFileSync(path.join(fake, "outside.css"), ".a {}\n");
  mkdirSync(path.join(fake, "src"));
  symlinkSync(path.join(fake, "outside.css"), path.join(fake, "src/a.css"));
  assert.throws(() => readPackageFile("src/a.css", { root: fake }), /must be a regular file/);
  symlinkSync(path.join(fake, "src"), path.join(fake, "linked"));
  assert.throws(() => readPackageFile("linked/plain.css", { root: fake }), /ENOENT|must resolve/);
  writeFileSync(path.join(fake, "src/plain.css"), ".b {}\n");
  assert.throws(() => readPackageFile("linked/plain.css", { root: fake }), /must resolve to its direct package path/);
  assert.equal(readPackageFile("src/plain.css", { root: fake }).toString(), ".b {}\n");
});

await check("nothing under src/ or scripts/ is a symlink", () => {
  const links = ["src", "scripts"].flatMap((dir) => readdirSync(path.join(root, dir), { recursive: true }).map((rel) => path.join(dir, String(rel))).filter((rel) => lstatSync(path.join(root, rel)).isSymbolicLink()));
  assert.deepEqual(links, []);
});

await check("no module on a build or pack path names a Barkpark path, except the reader in surface.mjs", () => {
  const seen = new Map();
  const walk = (rel) => {
    if (seen.has(rel)) return;
    const text = readPackageFile(rel).toString("utf8");
    seen.set(rel, text);
    for (const [, spec] of text.matchAll(/(?:from\s+|import\s*\(\s*|^import\s+)["'](\.[^"']+)["']/gm)) {
      const next = path.posix.normalize(path.posix.join(path.posix.dirname(rel), spec));
      assert.ok(!next.startsWith("../"), `${rel} imports ${spec}, outside the package`);
      walk(next);
    }
  };
  for (const entry of ["scripts/build-local.mjs", "scripts/pack-check.mjs", "scripts/third-party-notices.mjs"]) walk(entry);
  assert.ok(seen.has("scripts/surface.mjs") && seen.has("scripts/source-assets.mjs") && seen.has("scripts/build-bundle.mjs") && seen.size >= 8, `walked only ${[...seen.keys()]}`);
  // A step up in any spelling. The package root itself is the one step a module may take.
  const outward = /\.\.\/\.\.\/|\.\.\/paper-surface|priv\/static|api\/assets\/paper-surface|web\/public|["'`]\.\.\/?["'`]|["'`]\.\.\/(?!src\/)|dirname\(\s*(?:path\.)?dirname|createRequire/;
  const packageRootLine = /path\.resolve\(path\.dirname\(.*?\),\s*"\.\."\)/;
  const code = (text) => text.split("\n").filter((line) => !/^\s*\/\//.test(line));
  const hits = [...seen].flatMap(([rel, text]) => code(text).filter((line) => outward.test(line.replace(packageRootLine, ""))).map((line) => `${rel}: ${line.trim()}`));
  // The walk above follows literal imports only, so a computed one must be named here.
  const computed = [...seen].flatMap(([rel, text]) => code(text).filter((line) => /\bimport\s*\(\s*[^"'\s]/.test(line)).map((line) => `${rel}: ${line.trim()}`));
  assert.deepEqual(computed, ["scripts/pack-check.mjs: const shipped = await import(pathToFileURL(contract).href);"]);
  assert.deepEqual(hits, [
    `scripts/build-local.mjs: if (!/^(src|node_modules)\\//.test(input) || input.split("/").includes(".."))`,
    `scripts/surface.mjs: const readerDir = path.join(root, "../../lib/barkpark/portable_doc/render");`,
  ]);
  const reader = code(seen.get("scripts/surface.mjs")).filter((line) => line.includes("readerDir"));
  assert.ok(reader.every((line) => !line.includes("export async function packageSurface")), "packageSurface does not take the reader");
});

await check("the input census refuses a parent traversal and anything outside src and node_modules", () => {
  const census = (...inputs) => ({ "x.css": { inputs: Object.fromEntries(inputs.map((input) => [input, {}])) } });
  assertPackageInputs(census("src/a.js", "node_modules/b/c.js"));
  for (const bad of ["../../priv/static/assets/bp-paper-editor.css", "../paper-surface/paper-surface.css", "src/../../x.js", "scripts/a.js", "dist/a.js"])
    assert.throws(() => assertPackageInputs(census("src/ok.js", bad)), /not package source/, bad);
  assert.throws(() => assertPackageInputs(census()), /reports no inputs/);
});

// ── the build ──────────────────────────────────────────────────────────────

const buildDir = path.join(inScratch("build"), "dist");
const built = await buildLocal({ outDir: buildDir, logLevel: "warning" });
const builtBytes = Object.fromEntries(readdirSync(buildDir).map((name) => [name, readFileSync(path.join(buildDir, name))]));

await check("a build writes exactly the seven outputs and takes only package inputs", () => {
  assert.equal(LOCAL_OUTPUTS.length, 7);
  assert.deepEqual(readdirSync(buildDir).sort(), [...LOCAL_OUTPUTS].sort());
  assertExactOutputs(buildDir);
  assert.deepEqual(Object.keys(built.metafiles).sort(), ["bp-paper-code.js", "bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-surface.css"]);
  const inputs = Object.values(built.metafiles).flatMap((metafile) => Object.keys(metafile.inputs));
  assert.ok(inputs.length > 400, `only ${inputs.length} inputs`);
  assert.deepEqual(inputs.filter((input) => !/^(src|node_modules)\//.test(input) || input.includes("..")), []);
  assert.deepEqual(Object.keys(built.metafiles["bp-paper-surface.css"].inputs), ["src/paper-surface/assembled.css"]);
});

await check("the exact-output check refuses a missing file and an extra one", () => {
  const dir = inScratch("exact");
  for (const name of LOCAL_OUTPUTS.slice(1)) writeFileSync(path.join(dir, name), "x");
  assert.throws(() => assertExactOutputs(dir), /expected exactly/);
  writeFileSync(path.join(dir, LOCAL_OUTPUTS[0]), "x");
  assertExactOutputs(dir);
  writeFileSync(path.join(dir, "bp-paper-editor.bundle.js.map"), "x");
  assert.throws(() => assertExactOutputs(dir), /expected exactly/);
  assertExactOutputs(dir, { dev: true });
  writeFileSync(path.join(dir, "surface.json"), "{}");
  assert.throws(() => assertExactOutputs(dir, { dev: true }), /expected exactly/, "the profile is not an eighth output");
});

await check("the outputs are the assembled and copied package bytes", async () => {
  const { code } = await transform(assembleAsset("paper-surface").toString("utf8"), { loader: "css", minify: true });
  assert.equal(builtBytes["bp-paper-surface.css"].toString("utf8"), code, "the surface is the assembly, minified");
  assert.equal(sha(builtBytes["bp-paper-editor-shell.css"]), ASSEMBLED["editor-shell"], "shell is the assembly, unchanged");
  assert.equal(sha(builtBytes["bp-paper-mermaid.js"]), MERMAID, "mermaid is the package copy, unchanged");
  assert.ok(builtBytes["contract.js"].equals(readPackageFile("src/contract.js")), "contract is the package copy, unchanged");
});

await check("a build reads the evidence off its own bundle and matches package.json", () => {
  const pkg = JSON.parse(readPackageFile("package.json").toString("utf8"));
  assert.equal(built.evidence.contract, pkg.barkpark.contractVersion);
  assert.equal(built.evidence.editor, pkg.version);
  assert.match(built.evidence.build, /^[0-9a-f]{12}$/);
  assert.ok(builtBytes["bp-paper-editor.bundle.js"].includes(built.evidence.build), "the bundle carries the BUILD_SHA");
  assert.equal("reader" in built.evidence, false, "a build composes no reader");
});

await check("the tracked profile keeps its path and shape and agrees with the package, BUILD_SHA aside", () => {
  const tracked = JSON.parse(readPackageFile("host-profile/surface.json").toString("utf8"));
  validatePackageProfile({ ...built.evidence, build: tracked.build }, tracked);
  assert.equal(readPackageFile("host-profile/surface.json").toString("utf8"), render(tracked), "the tracked file is the canonical rendering");
  assert.throws(() => validatePackageProfile({ ...built.evidence, build: "000000000000" }, tracked), /profile build differs/);
});

await check("the package scripts are the approved set", () => {
  const { scripts } = JSON.parse(readPackageFile("package.json").toString("utf8"));
  assert.equal(scripts.build, "node scripts/build-local.mjs");
  assert.equal(scripts["build:dev"], "node scripts/build-local.mjs --dev");
  assert.equal(scripts["sync:barkpark:check"], "node scripts/sync-barkpark.mjs --check");
  assert.equal(scripts["sync:barkpark:write"], "node scripts/sync-barkpark.mjs --write");
  assert.equal(scripts.prepack, "npm run build && node scripts/third-party-notices.mjs --check && node scripts/pack-check.mjs --prepack");
  assert.equal(scripts["pack:check"], "node scripts/pack-check.mjs");
  assert.equal("build:web" in scripts, false);
  assert.equal("pack:stage" in scripts, false);
  assert.equal(existsSync(path.join(root, "scripts/pack-stage.mjs")), false);
});

await check("the testing ground serves only outputs a build makes", () => {
  const page = readPackageFile("src/testing-ground/page/index.html").toString("utf8");
  const requested = [...page.matchAll(/(?:src|href)="build\/([^"]+)"/g)].map((match) => match[1]).sort();
  assert.deepEqual(requested, ["bp-paper-editor-shell.css", "bp-paper-editor.bundle.js", "bp-paper-editor.css"]);
  assert.deepEqual(requested.filter((name) => !LOCAL_OUTPUTS.includes(name)), []);
  const server = readPackageFile("src/testing-ground/server.mjs").toString("utf8");
  assert.ok(server.includes('const BUNDLE_FILES = ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css"];'), "server.mjs serves the same three files");
});

// ── the outward sync, on a synthetic tree ──────────────────────────────────

const ALL_SINKS = [
  "api/assets/paper-surface/paper-surface.css",
  "api/assets/paper-surface/code-tokens.css",
  "api/priv/static/assets/bp-paper-editor.bundle.js",
  "api/priv/static/assets/bp-paper-editor.css",
  "api/priv/static/assets/bp-paper-code.js",
  "api/priv/static/assets/bp-paper-surface.css",
  "api/priv/static/assets/bp-paper-editor-shell.css",
  "api/priv/static/assets/bp-paper-mermaid.js",
  "web/public/bp-paper-editor.bundle.js",
  "web/public/assets/bp-paper-editor.css",
  "api/assets/paper-editor/host-profile/surface.json",
];
const fakeBuild = async () => ({
  outputs: Object.fromEntries(Object.keys(BROWSER_SINKS).map((name) => [name, Buffer.from(`built ${name}`)])),
  profile: Buffer.from("composed profile\n"),
});
const listTree = (dir) => readdirSync(dir, { recursive: true }).map(String).filter((rel) => lstatSync(path.join(dir, rel)).isFile()).sort();
const snapshot = (dir) => Object.fromEntries(listTree(dir).map((rel) => [rel, sha(readFileSync(path.join(dir, rel)))]));
const logged = () => {
  const lines = [];
  return { lines, log: (line) => lines.push(line), warn: (line) => lines.push(line) };
};
const sync = (repo, options = {}) => {
  const out = logged();
  return runSync({ repo, build: fakeBuild, hasToolchain: () => true, log: out.log, warn: out.warn, ...options }).then((code) => ({ code, lines: out.lines }));
};

await check("the sync has exactly the eleven approved destinations", async () => {
  const sinks = expectedSinks({ built: await fakeBuild(), rawSurface: Buffer.from("s"), rawTokens: Buffer.from("t") }).map(([destination]) => destination);
  assert.deepEqual([...sinks].sort(), [...ALL_SINKS].sort());
  assert.equal(new Set(sinks).size, 11);
  assert.equal(sinks.at(-1), PROFILE_SINK, "the profile is written last");
  assert.equal(Object.keys(BROWSER_SINKS).includes("contract.js"), false, "contract.js stays a package output");
});

await check("--check names every missing sink, exits 1 and writes nothing", async () => {
  const repo = inScratch("sync-empty");
  const { code, lines } = await sync(repo);
  assert.equal(code, 1);
  for (const sink of ALL_SINKS) assert.ok(lines.includes(`MISSING  ${sink}`), sink);
  assert.ok(lines.some((line) => line.includes("npm run sync:barkpark:write")), "it prints the remedy");
  assert.deepEqual(listTree(repo), []);
});

await check("--write writes exactly the eleven sinks with the built bytes, and --check then passes", async () => {
  const repo = inScratch("sync-write");
  const { code, lines } = await sync(repo, { write: true });
  assert.equal(code, 0);
  assert.deepEqual(listTree(repo), [...ALL_SINKS].sort());
  assert.ok(readFileSync(path.join(repo, RAW_SURFACE_SINK)).equals(assembleAsset("paper-surface")));
  assert.ok(readFileSync(path.join(repo, RAW_TOKENS_SINK)).equals(readPackageFile("src/code-tokens.css")));
  assert.equal(readFileSync(path.join(repo, "web/public/assets/bp-paper-editor.css"), "utf8"), "built bp-paper-editor.css");
  assert.equal(lines.filter((line) => line.startsWith("WROTE")).length, 11);
  const again = await sync(repo);
  assert.equal(again.code, 0);
  assert.ok(again.lines.includes("sync-barkpark --check: all 11 Barkpark sinks match a fresh build"));
});

await check("each stale sink is named alone, --check leaves it, and --write fixes only it", async () => {
  const repo = inScratch("sync-stale");
  await sync(repo, { write: true });
  for (const sink of ALL_SINKS) {
    const at = path.join(repo, sink);
    const good = readFileSync(at);
    writeFileSync(at, "stale");
    const before = snapshot(repo);
    const { code, lines } = await sync(repo);
    assert.equal(code, 1, sink);
    assert.deepEqual(lines.filter((line) => /^(STALE|MISSING) /.test(line)), [`STALE  ${sink}`]);
    assert.deepEqual(snapshot(repo), before, "--check wrote nothing");
    const fixed = await sync(repo, { write: true });
    assert.deepEqual(fixed.lines.filter((line) => line.startsWith("WROTE")), [`WROTE  ${sink}`]);
    assert.ok(readFileSync(at).equals(good));
  }
});

await check("a stale sink never moves bytes back into the package", async () => {
  const repo = inScratch("sync-inward");
  await sync(repo, { write: true });
  const packageBefore = snapshot(path.join(root, "src/paper-surface"));
  writeFileSync(path.join(repo, RAW_SURFACE_SINK), "changed in the host");
  await sync(repo, { write: true });
  assert.deepEqual(snapshot(path.join(root, "src/paper-surface")), packageBefore);
  assert.ok(readFileSync(path.join(repo, RAW_SURFACE_SINK)).equals(assembleAsset("paper-surface")), "the package wins");
});

await check("--surface-only writes the raw surface and the profile, and no browser asset", async () => {
  const repo = inScratch("sync-surface-only");
  const { code } = await sync(repo, { write: true, surfaceOnly: true });
  assert.equal(code, 0);
  assert.deepEqual(listTree(repo), [PROFILE_SINK, RAW_SURFACE_SINK].sort());
  await sync(repo, { write: true });
  const browserBefore = Object.values(BROWSER_SINKS).flat();
  for (const sink of browserBefore) writeFileSync(path.join(repo, sink), "older browser asset");
  writeFileSync(path.join(repo, RAW_SURFACE_SINK), "stale");
  await sync(repo, { write: true, surfaceOnly: true });
  for (const sink of browserBefore) assert.equal(readFileSync(path.join(repo, sink), "utf8"), "older browser asset", sink);
  assert.ok(readFileSync(path.join(repo, RAW_SURFACE_SINK)).equals(assembleAsset("paper-surface")));
});

await check("--surface-only says when a full sync is still needed, and only then", async () => {
  const repo = inScratch("sync-surface-only-behind");
  await sync(repo, { write: true });
  const quiet = await sync(repo, { write: true, surfaceOnly: true });
  assert.ok(!quiet.lines.some((line) => line.includes("full sync")), "every sink matches, so nothing is owed");
  writeFileSync(path.join(repo, BROWSER_SINKS["bp-paper-editor.bundle.js"][0]), "older bundle");
  const { code, lines } = await sync(repo, { write: true, surfaceOnly: true });
  assert.equal(code, 0);
  assert.equal(lines.filter((line) => line.includes("a full sync is still needed")).length, 1, lines.join("\n"));
});

await check("a sink that is a directory is reported, and a write refuses it before writing anything", async () => {
  const repo = inScratch("sync-sink-directory");
  await sync(repo, { write: true });
  const sink = BROWSER_SINKS["bp-paper-editor.bundle.js"][0];
  rmSync(path.join(repo, sink));
  mkdirSync(path.join(repo, sink));
  writeFileSync(path.join(repo, RAW_SURFACE_SINK), "stale");
  const checked = await sync(repo);
  assert.equal(checked.code, 1);
  assert.ok(checked.lines.includes(`NOT A FILE  ${sink}`), checked.lines.join("\n"));
  const before = snapshot(repo);
  await assert.rejects(sync(repo, { write: true }), /is not a file; nothing was written/);
  assert.deepEqual(snapshot(repo), before, "nothing was written");
  assert.equal((await sync(repo, { write: true, surfaceOnly: true })).code, 0, "the surface sinks still sync");
});

await check("with no toolchain, --surface-only writes the raw surface and says so; every other mode refuses", async () => {
  const repo = inScratch("sync-no-toolchain");
  const never = async () => assert.fail("no toolchain means no build");
  const { code, lines } = await sync(repo, { write: true, surfaceOnly: true, build: never, hasToolchain: () => false });
  assert.equal(code, 0);
  assert.deepEqual(listTree(repo), [RAW_SURFACE_SINK]);
  assert.ok(lines.some((line) => line.includes("was not composed")), "it says the profile was not composed");
  const bare = inScratch("sync-bare-package");
  cpSync(path.join(root, "src/paper-surface"), path.join(bare, "src/paper-surface"), { recursive: true });
  const bareRepo = inScratch("sync-bare-repo");
  assert.equal((await sync(bareRepo, { root: bare, write: true, surfaceOnly: true, build: never, hasToolchain: () => false })).code, 0, "the surface fragments alone are enough");
  assert.deepEqual(listTree(bareRepo), [RAW_SURFACE_SINK]);
  await assert.rejects(sync(repo, { build: never, hasToolchain: () => false }), /run npm ci first/);
  await assert.rejects(sync(repo, { write: true, build: never, hasToolchain: () => false }), /run npm ci first/);
  await assert.rejects(sync(repo, { surfaceOnly: true }), /--surface-only is a write mode/);
});

await check("the sync CLI takes exactly its three forms", () => {
  assert.deepEqual(parseArgs(["--check"]), { write: false, surfaceOnly: false });
  assert.deepEqual(parseArgs(["--write"]), { write: true, surfaceOnly: false });
  assert.deepEqual(parseArgs(["--write", "--surface-only"]), { write: true, surfaceOnly: true });
  for (const bad of [[], ["--check", "--write"], ["--surface-only"], ["--check", "--surface-only"], ["--write", "--write"], ["--bogus"], ["--write", "extra"]]) assert.equal(parseArgs(bad), null, JSON.stringify(bad));
  const run = spawnSync(process.execPath, [path.join(root, "scripts/sync-barkpark.mjs"), "--bogus"], { encoding: "utf8" });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /bad arguments/);
});

// ── the tarball, on a synthetic unpacked package ───────────────────────────

const packFixture = (name) => {
  const base = inScratch(`pack-${name}`);
  const pkgRoot = path.join(base, "root");
  const pkgDir = path.join(base, "package");
  const tracked = JSON.parse(readPackageFile("host-profile/surface.json").toString("utf8"));
  const profile = render({ ...tracked, build: built.evidence.build });
  for (const dir of [pkgRoot, pkgDir]) {
    mkdirSync(path.join(dir, "host-profile"), { recursive: true });
    cpSync(buildDir, path.join(dir, "dist"), { recursive: true });
    for (const rel of ["package.json", "LICENSE", "README.md", "EMBED-CONTRACT.md", "THIRD-PARTY-NOTICES.txt", "third-party-notices.json", "index.d.ts", "contract.d.ts"]) cpSync(path.join(root, rel), path.join(dir, rel));
    writeFileSync(path.join(dir, "host-profile/surface.json"), profile);
  }
  return { pkgRoot, pkgDir, files: [...REQUIRED] };
};
const inspect = ({ pkgRoot, pkgDir, files }) => inspectPack({ files, pkgDir, root: pkgRoot });

await check("a good tarball passes, and it is exactly the seven dist files plus the required set", async () => {
  assert.deepEqual(await inspect(packFixture("good")), []);
  assert.deepEqual(REQUIRED.filter((file) => file.startsWith("dist/")).length, 7);
  assert.ok(REQUIRED.includes("LICENSE") && REQUIRED.includes("host-profile/surface.json"));
});

await check("the pack checks name a missing output, an extra one and a leaked source", async () => {
  const missing = packFixture("missing");
  missing.files = missing.files.filter((file) => file !== "dist/contract.js");
  assert.ok((await inspect(missing)).includes("tarball is missing dist/contract.js"));
  const extra = packFixture("extra");
  extra.files.push("dist/bp-paper-editor.bundle.js.map");
  assert.ok((await inspect(extra)).includes("tarball carries dist/bp-paper-editor.bundle.js.map, which the build does not output"));
  const leaked = packFixture("leaked");
  leaked.files.push("src/index.js", "scripts/build-local.mjs");
  const failed = await inspect(leaked);
  assert.ok(failed.includes("tarball leaks a file it should not ship: src/index.js"));
  assert.ok(failed.includes("tarball leaks a file it should not ship: scripts/build-local.mjs"));
});

await check("the pack checks hold dist, LICENSE and the profile to this package, and prepack refuses a stale profile", async () => {
  const dist = packFixture("stale-dist");
  writeFileSync(path.join(dist.pkgDir, "dist/bp-paper-mermaid.js"), "changed");
  assert.ok((await inspect(dist)).includes("dist/bp-paper-mermaid.js differs from this package's dist/bp-paper-mermaid.js"));
  const license = packFixture("stale-license");
  writeFileSync(path.join(license.pkgDir, "LICENSE"), "changed");
  assert.ok((await inspect(license)).includes("LICENSE differs from this package's tracked LICENSE"));
  const profile = packFixture("stale-profile");
  const tracked = JSON.parse(readFileSync(path.join(profile.pkgRoot, "host-profile/surface.json"), "utf8"));
  for (const dir of [profile.pkgRoot, profile.pkgDir]) writeFileSync(path.join(dir, "host-profile/surface.json"), render({ ...tracked, build: "000000000000" }));
  assert.ok((await inspect(profile)).some((failure) => failure.includes("does not match the packed build") && failure.includes("build differs")));
  // prepack's last step, so a bare npm pack or npm publish cannot ship that profile.
  const prepack = (dir) => spawnSync(process.execPath, [path.join(root, "scripts/pack-check.mjs"), "--prepack", dir], { encoding: "utf8" });
  const refused = prepack(profile.pkgRoot);
  assert.ok(refused.status === 1 && /REFUSED, nothing packed[\s\S]*build differs/.test(refused.stderr), `prepack took a stale profile: ${refused.status} ${refused.stderr}`);
  assert.equal(prepack(packFixture("prepack-good").pkgRoot).status, 0, "prepack refused a fresh profile");
});

if (failures) {
  console.log(`\n${failures} build ownership check(s) FAILED`);
  process.exit(1);
}
console.log("\nall build ownership checks PASS");
