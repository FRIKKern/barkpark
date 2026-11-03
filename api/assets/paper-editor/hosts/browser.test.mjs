import assert from "node:assert/strict";
import test from "node:test";
import { CHROME_VERSION, defaultChromePath } from "./browser.mjs";
import { journeys } from "./journeys.mjs";
import { profiles } from "./profiles.mjs";
import { options } from "./run.mjs";

test("browser path names the one pinned chrome-headless-shell build", () => {
  assert.equal(defaultChromePath({ platform: "darwin", arch: "arm64", home: "/home/me" }), `/home/me/.cache/puppeteer/chrome-headless-shell/mac_arm-${CHROME_VERSION}/chrome-headless-shell-mac-arm64/chrome-headless-shell`);
  assert.equal(defaultChromePath({ platform: "linux", arch: "x64", home: "/home/me" }), `/home/me/.cache/puppeteer/chrome-headless-shell/linux-${CHROME_VERSION}/chrome-headless-shell-linux64/chrome-headless-shell`);
  assert.throws(() => defaultChromePath({ platform: "win32", arch: "x64", home: "C:\\Users\\me" }), /no configured path/);
});

test("seven unique host pages are declared", () => {
  assert.equal(profiles.length, 7);
  assert.equal(new Set(profiles.map(({ id }) => id)).size, 7);
  for (const entry of profiles) assert.ok(entry.globals.length && entry.stubs.length);
});

test("E01 through E12 are declared once and unavailable journeys explain why", () => {
  assert.deepEqual(journeys.map(({ id }) => id), Array.from({ length: 12 }, (_, index) => `E${String(index + 1).padStart(2, "0")}`));
  for (const journey of journeys) if (journey.state === "unavailable") assert.ok(journey.reason);
  assert.match(journeys.find(({ id }) => id === "E09").reason, /task-53f2fc33b834114f/);
});

test("CLI is strict and --allow-unavailable is opt-in", () => {
  assert.equal(options([]).allowUnavailable, false);
  assert.equal(options(["--allow-unavailable", "--host=barkdown"]).host, "barkdown");
  assert.throws(() => options(["--allow-unavailable=true"]), /unknown or malformed/);
  assert.throws(() => options(["--host=nope"]), /unknown host/);
  assert.throws(() => options(["--output=a", "--output=b"]), /given twice/);
  assert.throws(() => options(["--allow-unavailable", "--allow-unavailable"]), /given twice/);
});
