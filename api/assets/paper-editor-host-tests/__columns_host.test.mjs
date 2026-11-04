// __columns_host.test.mjs — live host and canonical CSS authority for columns.
//
// Package conversion behavior and package styles remain in
// paper-editor/src/__columns.test.mjs. This companion reads the canonical
// paper-surface source and Barkpark's committed shell mirror directly.

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

const columnStyles = [
  ["../paper-surface/paper-surface.css", ".bp-paper-surface"],
  ["../../priv/static/assets/bp-paper-editor-shell.css", ".bp-paper-editor-body"],
].map(([path, scope]) => {
  const css = readFileSync(new URL(path, import.meta.url), "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .flatMap(([, selectors, body]) => selectors.split(",").map((selector) => ({
      selector: selector.trim(), body,
    })));
  return { path, scope, rules };
});

function assertEvidenceReset(sheet, selector) {
  const rule = sheet.rules.find((rule) => rule.selector === selector);
  assert.ok(rule, `${sheet.path}: missing ${selector}`);
  assert.match(rule.body, /--bp-evidence-width:\s*100%;/);
  assert.match(rule.body, /--bp-evidence-pull:\s*0px;/);
}

check("section-cell columns reset the page evidence band in reader and editor mirrors", () => {
  for (const sheet of columnStyles) {
    assertEvidenceReset(sheet, `${sheet.scope} .bp-section__cell .bp-cols`);
  }
});

check("wrapperless canvas grid columns reset evidence at the direct-child boundary", () => {
  for (const sheet of columnStyles.slice(1)) {
    assertEvidenceReset(sheet, ".bp-canvas-section > .bp-section__grid > .bp-cols");
  }
});

check("top-level columns still inherit the evidence width and pull", () => {
  for (const sheet of columnStyles) {
    const base = sheet.rules.find((rule) => rule.selector === `${sheet.scope} .bp-cols`);
    assert.ok(base, `${sheet.path}: missing top-level columns rule`);
    assert.match(base.body, /width:\s*var\(--bp-evidence-width, 100%\);/);
    assert.match(base.body, /margin-inline:\s*var\(--bp-evidence-pull, 0px\);/);
    const allowedResets = new Set([
      `${sheet.scope} .bp-section__cell .bp-cols`,
      ".bp-canvas-section > .bp-section__grid > .bp-cols",
    ]);
    for (const rule of sheet.rules.filter((rule) => /\.bp-cols$/.test(rule.selector))) {
      if (!allowedResets.has(rule.selector)) {
        assert.doesNotMatch(rule.body, /--bp-evidence-(?:width|pull)\s*:/,
          `${sheet.path}: ${rule.selector} must not reset inherited evidence`);
      }
    }
  }
});

check("a column cell resets the evidence band for every block it holds, nested surfaces included", () => {
  for (const sheet of columnStyles) {
    for (const selector of [
      `${sheet.scope} .bp-cols__c`,
      `${sheet.scope} .bp-cols__c .bp-paper-surface`,
      `${sheet.scope} .bp-cols__c .bp-paper-body`,
    ]) {
      const resets = sheet.rules.filter((rule) => rule.selector === selector
        && /--bp-evidence-width:\s*100%;/.test(rule.body)
        && /--bp-evidence-pull:\s*0px;/.test(rule.body));
      assert.ok(resets.length, `${sheet.path}: ${selector} must reset --bp-evidence-width/--bp-evidence-pull`);
    }
  }
});

check("nested tables use their column width, not the page evidence band", () => {
  for (const path of ["../paper-surface/paper-surface.css"]) {
    const css = readFileSync(new URL(path, import.meta.url), "utf8");
    assert.match(css, /\.bp-cols__c \.bp-table\s*\{[^}]*--bp-evidence-width:\s*100%;[^}]*--bp-evidence-pull:\s*0px;/,
      `${path}: a nested table must not inherit the page-wide breakout`);
  }
});

if (failures > 0) {
  console.log(`\n${failures} FAILURE(S)`);
  process.exit(1);
}
console.log("\nall host columns CSS checks PASS");
