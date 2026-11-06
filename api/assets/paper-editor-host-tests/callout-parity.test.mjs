// callout-parity.test.mjs — host-owned parity between the portable editor,
// the canonical paper surface, and the live Barkpark reader.
//
// Run from api/assets/paper-editor:
//   node ../paper-editor-host-tests/callout-parity.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { readAuthoredCss } from "../paper-editor/src/__css_source_graph.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(
  join(__dirname, "../paper-editor/src/canvas/callout-node.js"),
  "utf8",
);
const bundleCss = readAuthoredCss();
const surfaceCss = readFileSync(
  join(__dirname, "../paper-surface/paper-surface.css"),
  "utf8",
);
const walkEx = readFileSync(
  join(__dirname, "../../lib/barkpark/portable_doc/render/walk.ex"),
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

// ── (d) the tone VOCABULARY is a PREDICATE, not a snapshot ───────────────────
//
// WHY THIS ARM EXISTS. The verdict tones `loss`/`peace` (design/tokens.json
// color.verdict) shipped into the reader (walk.ex callout_tone_class/1) and into
// the JS SDK (core.ts CALLOUT_TONES) and into paper-surface.css — and NOT into
// this editor. Every guard that should have caught it was an ENUMERATION: the
// Elixir view/edit parity test carries a hardcoded eight-selector
// `@callout_tone_elements` list, so a SEVENTH tone was invisible to it and the
// embedder painted an authored verdict callout with no rail at all.
//
// So this arm derives the vocabulary from the READER every run and compares
// SETS. A tone added to walk.ex without the editor twin reds here on its own,
// with no list to remember to widen.
//
// Both halves assert their derived set is NON-EMPTY and print it first: a regex
// that stops matching would otherwise turn every comparison below into a
// vacuous pass over two empty sets.

const classModifiers = (css, scope) => {
  const out = new Set();
  const re = new RegExp(
    `\\.${scope}\\s+\\.bp-callout--([a-z]+)\\s*\\{([^}]*)\\}`,
    "g",
  );
  let m;
  while ((m = re.exec(css)) !== null) out.add(m[1]);
  return out;
};

const declsFor = (css, scope, mod) => {
  const m = css.match(
    new RegExp(`\\.${scope}\\s+\\.bp-callout--${mod}\\s*\\{([^}]*)\\}`),
  );
  if (!m) return null;
  const map = new Map();
  for (const d of m[1].split(";")) {
    const i = d.indexOf(":");
    if (i < 0) continue;
    map.set(d.slice(0, i).trim(), d.slice(i + 1).trim().replace(/\s+/g, " "));
  }
  return map;
};

const sorted = (set) => [...set].sort();

check("the reader's callout tone modifiers each have a byte-equal embedder twin", () => {
  const reader = classModifiers(surfaceCss, "bp-paper-surface");
  const editor = classModifiers(bundleCss, "bp-paper-editor-body");
  console.log(`      reader modifiers (paper-surface.css): ${sorted(reader).join(", ") || "(none)"}`);
  console.log(`      editor modifiers (styles.css):        ${sorted(editor).join(", ") || "(none)"}`);

  assert.ok(
    reader.size >= 5,
    `derived only ${reader.size} \`.bp-paper-surface .bp-callout--*\` rules out of ` +
      "paper-surface.css — the selector shape moved and this whole arm just went " +
      "vacuous. Fix the parse, do not delete the check.",
  );

  const missing = sorted(reader).filter((mod) => !editor.has(mod));
  assert.deepEqual(
    missing,
    [],
    `the embedder bundle has no \`.bp-paper-editor-body .bp-callout--${missing.join("/")}\` ` +
      "rule for a tone the reader paints. A standalone host has no `.bp-paper-surface` " +
      "ancestor, so that callout falls through to the bare `.bp-callout` default and " +
      "Edit shows no tone where /papers shows one. Copy the reader rule into " +
      "api/assets/paper-editor/src/styles/canvas.css (and run: npm run sync:barkpark:write).",
  );

  for (const mod of sorted(reader)) {
    const a = declsFor(surfaceCss, "bp-paper-surface", mod);
    const b = declsFor(bundleCss, "bp-paper-editor-body", mod);
    assert.ok(a && a.size > 0, `parsed no declarations for reader .bp-callout--${mod}`);
    assert.deepEqual(
      [...b.entries()].sort(),
      [...a.entries()].sort(),
      `tone drift on \`.bp-callout--${mod}\`: the embedder mirror disagrees with the ` +
        "reader rule in paper-surface.css. The mirror is byte-copied on purpose.",
    );
  }
});

check("the editor's tone vocabulary equals the reader's callout_tone_class/1 clauses", () => {
  const readerTones = new Set(
    [...walkEx.matchAll(/defp callout_tone_class\("([a-z]+)"\)/g)].map((m) => m[1]),
  );
  // Anchored on the helper's own literal — a bare `"word",` sweep over the file
  // would harvest unrelated strings (it picked up `"div"` on the first run).
  const vocab = src.match(/calloutToneClass\(tone\)\s*\{\s*return\s*\[([^\]]*)\]/);
  const editorTones = new Set(
    vocab ? [...vocab[1].matchAll(/"([a-z]+)"/g)].map((m) => m[1]) : [],
  );
  console.log(`      walk.ex callout_tone_class/1: ${sorted(readerTones).join(", ") || "(none)"}`);
  console.log(`      editor calloutToneClass():    ${sorted(editorTones).join(", ") || "(none)"}`);

  assert.ok(
    readerTones.size >= 5,
    `derived only ${readerTones.size} tones from walk.ex callout_tone_class/1 — the ` +
      "clause shape moved and this comparison just went vacuous.",
  );
  assert.ok(
    editorTones.size >= 5,
    `derived only ${editorTones.size} tones from callout-node.js calloutToneClass() — the ` +
      "literal moved out of calloutToneClass() and this comparison just went vacuous.",
  );
  assert.deepEqual(
    sorted(editorTones),
    sorted(readerTones),
    "callout-node.js calloutToneClass() and walk.ex callout_tone_class/1 disagree. A tone " +
      "the reader knows and the editor does not is silently collapsed onto " +
      "`bp-callout--info` in Edit — that is exactly how the verdict tones shipped " +
      "half-wired. Widen the calloutToneClass() vocabulary (and toneLabel) to match.",
  );
});

check("every reader tone has the reader's own <summary> label in the editor", () => {
  const labels = [...walkEx.matchAll(/defp tone_label\("([a-z]+)"\), do: "([A-Za-z]+)"/g)];
  console.log(`      walk.ex tone_label/1: ${labels.map(([, t, l]) => `${t}=>${l}`).join(", ") || "(none)"}`);
  assert.ok(
    labels.length >= 5,
    `derived only ${labels.length} tone_label/1 clauses from walk.ex — vacuous.`,
  );
  for (const [, tone, label] of labels) {
    assert.ok(
      new RegExp(`case "${tone}":\\s*\\n\\s*return "${label}";`).test(src),
      `callout-node.js toneLabel() has no \`case "${tone}": return "${label}";\` — the ` +
        "collapsed <details> summary would read \"Info\" in Edit where the reader " +
        `writes "${label}".`,
    );
  }
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
