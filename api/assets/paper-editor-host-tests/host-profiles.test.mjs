// Barkpark's committed Studio, Reader and web sources must stay within their
// declared host profiles. The package companion owns the synthetic checker and
// CLI behavior; this host test owns only Barkpark's live source closure.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { check } from "../paper-editor/host-profile/check.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../paper-editor");
const profiles = path.join(root, "host-profile");

let failures = 0;
const test = (name, fn) => {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
};

for (const file of ["../paper-editor/host-profile/studio.json", "../paper-editor/host-profile/reader.json", "../paper-editor/host-profile/web.json"]) {
  test(`${path.basename(file)}: that Barkpark host uses only what its profile lists`, () => {
    const profile = JSON.parse(readFileSync(new URL(file, import.meta.url), "utf8"));
    const surface = JSON.parse(readFileSync(path.join(profiles, "surface.json"), "utf8"));
    assert.deepEqual(check(profile, surface, profiles), []);
  });
}

if (failures) {
  console.log(`\n${failures} host profile check(s) FAILED`);
  process.exit(1);
}
console.log("\nall host profile checks PASS");
