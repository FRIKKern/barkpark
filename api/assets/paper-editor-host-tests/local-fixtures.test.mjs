import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const PKG = join(REPO, "api/assets/paper-editor");
const manifest = JSON.parse(readFileSync(join(PKG, "test-inputs/manifest.json"), "utf8"));
const pkg = JSON.parse(readFileSync(join(PKG, "package.json"), "utf8"));
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

assert.equal(manifest.version, 1);
assert.equal(manifest.upstream_repo, "https://github.com/FRIKKern/barkpark");
assert.equal(manifest.files.length, 3, "the package-local cohort stays deliberately bounded");
assert.ok(pkg.files.every((path) => !path.startsWith("test-inputs")), "test inputs are excluded from the npm package");

for (const file of manifest.files) {
  assert.equal(file.package, false, `${file.local} is test-only`);
  assert.match(file.local, /^test-inputs\//, `${file.local} stays under the package test-input boundary`);
  assert.match(file.commit, /^[0-9a-f]{40}$/, `${file.local} pins an exact upstream commit`);

  const local = readFileSync(join(PKG, file.local));
  const current = readFileSync(join(REPO, file.upstream));
  const pinned = execFileSync("git", ["show", `${file.commit}:${file.upstream}`], { cwd: REPO });
  assert.equal(sha256(local), file.sha256, `${file.local} matches its manifest digest`);
  assert.deepEqual(local, current, `${file.local} matches the current upstream fixture`);
  assert.deepEqual(local, pinned, `${file.local} matches the fixture at its pinned upstream commit`);

  for (const consumer of file.consumers) {
    const source = readFileSync(join(PKG, consumer.path), "utf8");
    assert.ok(source.includes(consumer.literal), `${consumer.path} reads ${file.local}`);
  }
}

console.log("PASS package-local fixtures: 3 pinned inputs, 4 consumers, current and exact-commit bytes match");
