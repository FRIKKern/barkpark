import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { baselineBuild, upgradeBuilds } from "../paper-editor/hosts/run.mjs";

test("E12 refuses a candidate that is the baseline bundle under different metadata", () => {
  const baseline = baselineBuild();
  const dir = mkdtempSync(join(tmpdir(), "bp-host-same-build-test-"));
  const files = ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css"];
  assert.equal(baseline.sha.length, 40);
  assert.equal(baseline.bundleSha256.length, 64);
  try {
    writeFileSync(join(dir, "source-commit"), "f".repeat(40) + "\n");
    const sums = files.map((name) => {
      const bytes = readFileSync(join(baseline.dir, name));
      writeFileSync(join(dir, name), bytes);
      return `${createHash("sha256").update(bytes).digest("hex")}  ${name}`;
    });
    writeFileSync(join(dir, "SHA256SUMS"), sums.join("\n") + "\n");
    assert.throws(() => upgradeBuilds(null, dir), /byte-identical to baseline/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
