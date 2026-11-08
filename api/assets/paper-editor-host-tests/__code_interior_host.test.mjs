// __code_interior_host.test.mjs — host-owned S9 CSS parity and token authority.
//
// Package source and package CSS assertions stay in
// paper-editor/src/__code_interior.test.mjs. This companion reads the live
// Barkpark shell mirror and canonical paper-surface source; neither is copied
// into the package.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { readAuthoredCss } from "../paper-editor/src/__css_source_graph.mjs";

const bundleCss = readAuthoredCss();
const shell = readFileSync(
  new URL("../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url),
  "utf8",
);
const surface = readFileSync(
  new URL("../paper-surface/paper-surface.css", import.meta.url),
  "utf8",
);

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

function areaDecls(css, label) {
  const m = css.match(/\.bp-canvas-code-area\s*\{([^}]*)\}/);
  assert.ok(m, `${label} has no .bp-canvas-code-area rule — the interior would ` +
    `fall back to the UA-default textarea size, diverging from the reader <pre>.`);
  return m[1]
    .split(";")
    .map((d) => d.trim().replace(/\s+/g, " "))
    .filter(Boolean)
    .sort();
}

check(".bp-canvas-code-area rule exists in BOTH sinks and is byte-identical", () => {
  const inBundle = areaDecls(bundleCss, "styles.css bundle");
  const inShell = areaDecls(shell, "bp-paper-editor-shell.css Studio sink");
  assert.deepEqual(
    inBundle,
    inShell,
    "the .bp-canvas-code-area rule drifted between the bundle and Studio sinks — " +
      "they must stay byte-identical or the standalone embedder and Studio paint " +
      "the code interior differently.",
  );
});

check("paper-surface.css defines a distinct --bp-codeblock-* family (not a --bp-pre-* reuse)", () => {
  for (const tok of [
    "--bp-codeblock-size:",
    "--bp-codeblock-lh:",
    "--bp-codeblock-pad:",
    "--bp-codeblock-margin:",
    "--bp-codeblock-radius:",
  ]) {
    assert.ok(
      surface.includes(tok),
      `paper-surface.css is missing ${tok} — the code-block frame family must be ` +
        `single-sourced there so the mirror-check propagates it to the bundle.`,
    );
  }
  assert.ok(surface.includes("--bp-pre-size: 14px"), "generic --bp-pre-size must stay 14px, untouched by S9.");
  assert.ok(!surface.includes("--bp-codeblock-accent-w:"), "--bp-codeblock-accent-w is a dead token; do not re-add it.");
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
