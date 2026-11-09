// __release_record.test.mjs — a version names one set of bytes.
//
// scripts/releases.json records each released tarball: its sha-256 and the sha-256 of
// every file in it. scripts/pack-check.mjs refuses to pack a recorded version with any
// other bytes, both after a real pack (inspectPack) and as prepack's last step, so a
// bare `npm pack` cannot make a second, different copy of a released version.
//
// Everything runs in temporary directories, on planted files and one build into a
// temporary folder. Nothing here packs.
//
// Run: node src/__release_record.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { inspectPack, readReleases, releaseMismatch, REQUIRED } from "../scripts/pack-check.mjs";
import { buildLocal } from "../scripts/build-local.mjs";
import { PACKAGE_ROOT, readPackageFile } from "../scripts/source-assets.mjs";
import { render } from "../scripts/surface.mjs";

const sha = (text) => createHash("sha256").update(text).digest("hex");
const scratch = mkdtempSync(path.join(tmpdir(), "bp-release-record-"));
process.once("exit", () => rmSync(scratch, { recursive: true, force: true }));
const dirWith = (name, files) => {
  const dir = path.join(scratch, name);
  for (const [file, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
    writeFileSync(path.join(dir, file), text);
  }
  return dir;
};

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
}

await check("the record holds 0.1.0-alpha.1 as released, file for file", () => {
  const [alpha1, ...rest] = readReleases();
  assert.equal(rest.length, 0);
  assert.equal(alpha1.version, "0.1.0-alpha.1");
  assert.equal(alpha1.tarball.sha256, "46b4e3b6ee57fd1570bc194ac7a383c84ba2c9c4cc377cacce52e08a10ea00a1");
  assert.deepEqual(Object.keys(alpha1.files).sort(), [...REQUIRED].sort(), "a release records exactly the files a pack ships");
  assert.equal(alpha1.files["dist/bp-paper-editor.bundle.js"], "2e58cdd25434c3064d4b9856f5d27f7452f8b45a72be665c1070b2bdaeba41cd");
  assert.equal(alpha1.files["dist/bp-paper-editor.css"], "a22d092a7119e83b3b27acf248054a78d27f9c8041d28690ef0f42694ae70007");
  for (const digest of Object.values(alpha1.files)) assert.match(digest, /^[0-9a-f]{64}$/);
});

await check("package.json is a pre-1.0 alpha that is not a recorded release", () => {
  const { version } = JSON.parse(readPackageFile("package.json").toString("utf8"));
  assert.match(version, /^0\.\d+\.\d+-alpha\.\d+$/, `package.json version ${version} is not a pre-1.0 alpha`);
  const recorded = readReleases().map((release) => release.version);
  assert.ok(!recorded.includes(version), `package.json says ${version}, which is already released: the next pack would refuse`);
});

const planted = { version: "0.0.0-planted", source: "a planted release", tarball: { sha256: "0".repeat(64) }, files: { "a.txt": sha("a"), "dist/b.js": sha("b") } };

await check("releaseMismatch names every changed, missing and extra file, and passes an exact match", () => {
  const releases = [planted];
  const exact = dirWith("exact", { "a.txt": "a", "dist/b.js": "b" });
  assert.equal(releaseMismatch({ dir: exact, version: "0.0.0-planted", files: ["a.txt", "dist/b.js"], releases }), null);
  assert.equal(releaseMismatch({ dir: dirWith("other", { "a.txt": "changed" }), version: "0.0.0-unreleased", files: ["a.txt"], releases }), null, "an unreleased version is not held");
  const changed = releaseMismatch({ dir: dirWith("changed", { "a.txt": "a", "dist/b.js": "b, one byte on" }), version: "0.0.0-planted", files: ["a.txt", "dist/b.js"], releases });
  assert.deepEqual(changed.differ, ["dist/b.js"]);
  const missing = releaseMismatch({ dir: dirWith("missing", { "dist/b.js": "b" }), version: "0.0.0-planted", files: ["dist/b.js"], releases });
  assert.deepEqual(missing.differ, ["a.txt"]);
  const extra = releaseMismatch({ dir: dirWith("extra", { "a.txt": "a", "dist/b.js": "b", "c.txt": "c" }), version: "0.0.0-planted", files: ["a.txt", "c.txt", "dist/b.js"], releases });
  assert.deepEqual(extra.differ, ["c.txt"]);
});

await check("inspectPack fails a pack of a recorded version with other bytes, by version and file", async () => {
  const root = dirWith("pack-root", { "package.json": JSON.stringify({ name: "x", version: "0.0.0-planted", main: "a.txt", types: "a.txt", barkpark: { contractVersion: "0.0.0" } }) });
  const pkgDir = dirWith("pack-unpacked", { "a.txt": "a", "dist/b.js": "b, changed" });
  const failed = await inspectPack({ files: ["a.txt", "dist/b.js"], pkgDir, root, contractVersion: "0.0.0", releases: [planted] });
  const released = failed.filter((failure) => failure.includes("is already released"));
  assert.equal(released.length, 1, failed.join("\n"));
  assert.match(released[0], /^version 0\.0\.0-planted is already released \(a planted release, tarball sha256 0{64}\) and these files differ from it: dist\/b\.js\./);
  const same = dirWith("pack-same", { "a.txt": "a", "dist/b.js": "b" });
  const passed = await inspectPack({ files: ["a.txt", "dist/b.js"], pkgDir: same, root, contractVersion: "0.0.0", releases: [planted] });
  assert.ok(!passed.some((failure) => failure.includes("is already released")), passed.join("\n"));
});

await check("prepack refuses a package still at 0.1.0-alpha.1 with other bytes, against the real record", async () => {
  const prepack = (dir) => spawnSync(process.execPath, [path.join(PACKAGE_ROOT, "scripts/pack-check.mjs"), "--prepack", dir], { encoding: "utf8" });
  // A real build and its own profile, so the profile check passes and only the release
  // check can refuse: the package of a branch that forgot to bump past alpha.1.
  const stale = path.join(scratch, "prepack-alpha1");
  const { evidence } = await buildLocal({ outDir: path.join(stale, "dist"), logLevel: "warning" });
  for (const rel of REQUIRED.filter((file) => !file.startsWith("dist/") && file !== "host-profile/surface.json")) cpSync(path.join(PACKAGE_ROOT, rel), path.join(stale, rel));
  const tracked = JSON.parse(readPackageFile("host-profile/surface.json").toString("utf8"));
  mkdirSync(path.join(stale, "host-profile"));
  writeFileSync(path.join(stale, "host-profile/surface.json"), render({ ...tracked, build: evidence.build }));
  const pkg = JSON.parse(readPackageFile("package.json").toString("utf8"));
  writeFileSync(path.join(stale, "package.json"), JSON.stringify({ ...pkg, version: "0.1.0-alpha.1" }, null, 2) + "\n");
  const refused = prepack(stale);
  assert.equal(refused.status, 1, refused.stderr);
  assert.ok(!refused.stderr.includes("does not match the build"), `the profile check refused too, so this proves nothing about the release check: ${refused.stderr}`);
  assert.match(refused.stderr, /prepack: REFUSED, nothing packed\. version 0\.1\.0-alpha\.1 is already released \(.*run 41730501762.*tarball sha256 46b4e3b6ee57fd1570bc194ac7a383c84ba2c9c4cc377cacce52e08a10ea00a1\) and these files differ from it: .*dist\/bp-paper-editor\.bundle\.js.*package\.json/);
  const unreleased = prepack(dirWith("prepack-unreleased", { "package.json": JSON.stringify({ name: "@portable-doc/editor", version: "0.1.0-alpha.999" }) }));
  assert.ok(!unreleased.stderr.includes("is already released"), unreleased.stderr);
});

if (failures) {
  console.log(`\n${failures} release record check(s) FAILED`);
  process.exit(1);
}
console.log("\nall release record checks PASS");
