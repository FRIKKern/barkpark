import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CHROME_VERSION, defaultChromePath } from "./browser.mjs";
import { journeys } from "./journeys.mjs";
import { profiles } from "./profiles.mjs";
import { options, stagedBuild } from "./run.mjs";

test("browser path names the one pinned chrome-headless-shell build", () => {
  assert.equal(defaultChromePath({ platform: "darwin", arch: "arm64", home: "/home/me" }), `/home/me/.cache/puppeteer/chrome-headless-shell/mac_arm-${CHROME_VERSION}/chrome-headless-shell-mac-arm64/chrome-headless-shell`);
  assert.equal(defaultChromePath({ platform: "linux", arch: "x64", home: "/home/me" }), `/home/me/.cache/puppeteer/chrome-headless-shell/linux-${CHROME_VERSION}/chrome-headless-shell-linux64/chrome-headless-shell`);
  assert.throws(() => defaultChromePath({ platform: "win32", arch: "x64", home: "C:\\Users\\me" }), /no configured path/);
});

test("seven unique host pages declare their own CSS, globals and stubs", () => {
  assert.equal(profiles.length, 7);
  assert.equal(new Set(profiles.map(({ id }) => id)).size, 7);
  assert.equal(new Set(profiles.map(({ css }) => css)).size, 7);
  for (const entry of profiles) {
    assert.ok(entry.css.length && entry.globals.length > 1 && entry.stubs.length > 3);
    assert.match(entry.source, /:/);
  }
});

test("E01 through E12 are declared once and E09 stays an explicit diagnostic negative", () => {
  assert.deepEqual(journeys.map(({ id }) => id), Array.from({ length: 12 }, (_, index) => `E${String(index + 1).padStart(2, "0")}`));
  for (const journey of journeys) if (journey.state === "unavailable") assert.ok(journey.reason);
  assert.deepEqual(journeys.find(({ id }) => id === "E09"), {
    id: "E09", title: "Read=Edit same doc looks same reader/editor", state: "available", kind: "diagnostic-negative", expected: "red",
    dependency: "TG2 PR #25130 at 7b8ac416c8f9cde903537e130e429124777294da", artifact: "known-red screenshot",
  });
  assert.deepEqual(journeys.filter(({ state }) => state === "available").map(({ id }) => id), ["E01", "E02", "E03", "E04", "E05", "E06", "E07", "E08", "E09", "E10", "E11"]);
});

test("CLI is strict and --allow-unavailable is opt-in", () => {
  assert.equal(options([]).allowUnavailable, false);
  assert.equal(options(["--allow-unavailable", "--host=barkdown"]).host, "barkdown");
  assert.match(options(["--baseline=../served", "--candidate=../build"]).baseline, /\/served$/);
  assert.match(options(["--candidate=../build"]).candidate, /\/build$/);
  assert.throws(() => options(["--allow-unavailable=true"]), /unknown or malformed/);
  assert.throws(() => options(["--host=nope"]), /unknown host/);
  assert.throws(() => options(["--output=a", "--output=b"]), /given twice/);
  assert.throws(() => options(["--allow-unavailable", "--allow-unavailable"]), /given twice/);
});

test("candidate assets need a full source commit and matching SHA-256 manifest", () => {
  const dir = mkdtempSync(join(tmpdir(), "bp-host-candidate-test-"));
  const files = ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css"];
  try {
    writeFileSync(join(dir, "source-commit"), "a".repeat(40) + "\n");
    for (const name of files) writeFileSync(join(dir, name), `fixture ${name}\n`);
    const lines = files.map((name) => `${createHash("sha256").update(`fixture ${name}\n`).digest("hex")}  ${name}`);
    writeFileSync(join(dir, "SHA256SUMS"), lines.join("\n") + "\n");
    assert.equal(stagedBuild(dir).sha, "a".repeat(40));
    writeFileSync(join(dir, files[0]), "tampered\n");
    assert.throws(() => stagedBuild(dir), /checksum mismatch/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// The E12 baseline test needs git history and the host sink, so it lives in
// ../../paper-editor-host-tests/hosts-e12-baseline.test.mjs.
