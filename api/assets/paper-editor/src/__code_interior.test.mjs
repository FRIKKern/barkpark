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
//   2. both CSS sinks (styles.css bundle + root.html.heex Studio inline) carry a
//      token-bound `.bp-canvas-code-area` rule, byte-identical to each other,
//      binding the SAME --bp-codeblock-*/--paper-* tokens the reader <pre> uses.
//   3. the --bp-codeblock-* token family exists in the single source
//      (paper-surface.css) — a distinct family, NOT a reuse of --bp-pre-*.
//
// Run: node src/__code_interior.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const readSrc = (rel) => readFileSync(join(__dirname, rel), "utf8");
// Repo-root-relative sinks (…/api/assets/paper-editor/src → repo root is 4 up).
const readRepo = (rel) => readFileSync(join(__dirname, "../../../..", rel), "utf8");

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
const heex = readRepo("api/lib/barkpark_web/layouts/root.html.heex");
const surface = readRepo("api/assets/paper-surface/paper-surface.css");

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

// ── 2. Both CSS sinks carry the token-bound interior rule, byte-aligned ───────

// Extract the `.bp-canvas-code-area { … }` declaration body from a stylesheet,
// normalising whitespace so the bundle (multi-line) and the heex-inlined copy
// compare on their declarations, not their indentation.
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
  const inHeex = areaDecls(heex, "root.html.heex Studio inline");
  assert.deepEqual(
    inBundle,
    inHeex,
    "the .bp-canvas-code-area rule drifted between the bundle and Studio sinks — " +
      "they must stay byte-identical or the standalone embedder and Studio paint " +
      "the code interior differently.",
  );
});

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

// ── 3. The --bp-codeblock-* family is a distinct token set in the source ──────

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
  // Guard against collapsing into the generic pre tokens (would regress the 14px
  // generic <pre> and the inline-code chip).
  assert.ok(surface.includes("--bp-pre-size: 14px"), "generic --bp-pre-size must stay 14px, untouched by S9.");
  // task-ddb1e0ab09a62466: the 3px left bar is RETIRED. The token that sized it
  // must not come back into the source, and the bundle's frame rule must not
  // paint a border-left — the --paper-bg-deep slab on the --paper-bg page is the
  // whole mark now, byte-identical with the reader <pre> and the Studio mirror.
  // Keyed on the DECLARATION form (`name:`) — the retirement note in the source
  // names the token in prose, and prose is not a token.
  assert.ok(!surface.includes("--bp-codeblock-accent-w:"), "--bp-codeblock-accent-w is a dead token; do not re-add it.");
  const frame = bundleCss.match(/\.bp-paper-editor-body pre\.bp-canvas-code\s*\{([^}]*)\}/);
  assert.ok(frame, ".bp-paper-editor-body pre.bp-canvas-code frame rule missing from the bundle");
  assert.ok(!frame[1].includes("border-left"), "pre.bp-canvas-code must not paint a border-left (the code bar was retired).");
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
