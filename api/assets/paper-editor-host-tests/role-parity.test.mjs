// The live Barkpark shell must preserve the opening paragraph rhythm that the
// package stylesheet and role-node package tests require.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

check("opening canvas preserves paragraph rhythm in the live shell stylesheet", () => {
  for (const path of ["../../priv/static/assets/bp-paper-editor-shell.css"]) {
    const css = readFileSync(new URL(path, import.meta.url), "utf8");
    const openingRule = css.match(/\.bp-paper-editor > \.bp-paper-edit-canvas:nth-child\(1 of[^}]+\}/)?.[0];
    assert.ok(openingRule, `${path}: opening canvas rule must be present`);
    assert.match(openingRule, /> :first-child:not\(p\)\s*\{\s*margin-top: 0;/,
      `${path}: the reader retains its opening paragraph margin; only non-paragraph nodes may be clamped`);
  }
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
