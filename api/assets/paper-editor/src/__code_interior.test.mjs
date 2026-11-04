// __code_interior.test.mjs — S9 code-interior frame-parity gate.
//
// The edit-canvas code ATOM's frame (<pre class="bp-canvas-code">) and its
// <textarea> EDIT island must read byte-identically to the reader's static
// <pre> (Barkpark.PortableDoc.Render.Figures.code_block_html/1). The residual
// round-2 drift was FONT-FAMILY + an un-styled interior: the node-view stamped
// an inline font stack ("…SFMono-Regular…Consolas…") that (a) diverged from the
// reader's --paper-font-mono and (b) being inline, out-ranked the token; and the
// textarea set NO font-size/line-height/colour so the editable code fell back to
// the UA-default (~13.3px) — a visibly different size than the reader's 0.9rem.
//
// This pure-Node source guard (no DOM, no browser — same shape as
// __atom_chrome / __divider_parity) locks the fix:
//   1. code-node.js NO LONGER sets font-family / typography inline on the <pre>
//      frame or the <textarea> (so the shared token can win).
//   2. package styles.css carries the token-bound `.bp-canvas-code-area` rule,
//      binding the SAME --bp-codeblock-*/--paper-* tokens the reader <pre> uses.
//   3. the package frame keeps the retired code bar absent.
//
// The companion host test owns parity with bp-paper-editor-shell.css and the
// canonical --bp-codeblock-* token family in paper-surface.css.
//
// Run: node src/__code_interior.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const readSrc = (rel) => readFileSync(join(__dirname, rel), "utf8");

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

const codeNode = readSrc("canvas/code-node.js");
const bundleCss = readSrc("styles.css");

// ── 1. The inline font drift is GONE from the node-view source ────────────────

check("code-node.js sets NO inline font-family on the <pre> frame or <textarea>", () => {
  assert.ok(
    !/\.style\.fontFamily\s*=/.test(codeNode),
    "code-node.js still assigns .style.fontFamily — the inline stack out-ranks " +
      "the --paper-font-mono token and re-introduces the S9 font drift. Font must " +
      "live ONLY in the .bp-canvas-code / .bp-canvas-code-area CSS rules.",
  );
});

check("code-node.js sets NO inline font-size/line-height/whiteSpace on the interior", () => {
  // The interior typography must come from the token-bound CSS, not inline JS.
  for (const prop of ["fontSize", "lineHeight", "whiteSpace", "overflowWrap"]) {
    assert.ok(
      !new RegExp(`\\.style\\.${prop}\\s*=`).test(codeNode),
      `code-node.js still assigns .style.${prop} inline — move it to the ` +
        `.bp-canvas-code-area / .bp-canvas-code CSS rule so it stays token-bound.`,
    );
  }
});

// ── 2. Package CSS carries the token-bound interior rule ─────────────────

// Extract the `.bp-canvas-code-area { … }` declaration body from a stylesheet,
// normalising whitespace so token checks compare declarations, not indentation.
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

check(".bp-canvas-code-area binds the code interior to the shared tokens (not literals)", () => {
  const decls = areaDecls(bundleCss, "styles.css bundle").join(" | ");
  for (const tok of [
    "font-family: var(--paper-font-mono)",
    "font-size: var(--bp-codeblock-size)",
    "line-height: var(--bp-codeblock-lh)",
    "color: var(--paper-ink)",
  ]) {
    assert.ok(
      decls.includes(tok),
      `.bp-canvas-code-area is missing \`${tok}\` — the editable code must bind ` +
        `the SAME token the reader <pre> resolves so the two render identically.`,
    );
  }
  // white-space:pre == the reader <pre>'s no-wrap semantics.
  assert.ok(decls.includes("white-space: pre"), ".bp-canvas-code-area must set white-space:pre (reader parity).");
});

// ── 3. The package frame keeps the retired code bar absent ───────────────

check("the package code frame keeps the retired code bar absent", () => {
  const frame = bundleCss.match(/\.bp-paper-editor-body pre\.bp-canvas-code\s*\{([^}]*)\}/);
  assert.ok(frame, ".bp-paper-editor-body pre.bp-canvas-code frame rule missing from the bundle");
  assert.ok(!frame[1].includes("border-left"), "pre.bp-canvas-code must not paint a border-left (the code bar was retired).");
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
