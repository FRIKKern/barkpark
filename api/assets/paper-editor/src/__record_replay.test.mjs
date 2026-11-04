// __record_replay.test.mjs — the replay recorder drives the same mounted table
// control an author uses. Keep this in the normal package chain: a removed public
// method once left the historical-fixture tool unable to record the current tree.
// Run: node src/__record_replay.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = fileURLToPath(new URL("..", import.meta.url));
const recorder = fileURLToPath(new URL("../scripts/record-replay.mjs", import.meta.url));
const outputDir = mkdtempSync(join(tmpdir(), "paper-editor-record-replay-"));
const outputPath = join(outputDir, "recording.json");
const output = openSync(outputPath, "w");
let run;
try {
  run = spawnSync(process.execPath, [recorder, packageRoot, "0000000000"], {
    cwd: packageRoot,
    encoding: "utf8",
    timeout: 60_000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", output, "pipe"],
  });
} finally {
  closeSync(output);
}

try {
  assert.equal(run.error, undefined, `record-replay failed to start: ${run.error?.message || "unknown error"}`);
  assert.equal(run.signal, null, `record-replay ended on signal ${run.signal}`);
  assert.equal(run.status, 0, `record-replay exited ${run.status}:\n${run.stderr}`);
  assert.equal(run.stderr, "", `record-replay wrote stderr:\n${run.stderr}`);

  const stdout = readFileSync(outputPath, "utf8");
  let recording;
  assert.doesNotThrow(() => {
    recording = JSON.parse(stdout);
  }, `record-replay did not print JSON:\n${stdout}`);

  const tableStructure = recording.scenes.find((scene) => scene.scene === "table-structure");
  assert.ok(tableStructure, "record-replay omitted the table-structure scene");
  assert.deepEqual(
    tableStructure.batches.map((batch) => batch.map(({ op, action }) => ({ op, action }))),
    [[{ op: "patch-table-structure", action: "add-row" }]],
    "table-structure must record exactly one Add row op from the mounted control",
  );
} finally {
  rmSync(outputDir, { recursive: true, force: true });
}

console.log("record-replay current-tree regression passed");
