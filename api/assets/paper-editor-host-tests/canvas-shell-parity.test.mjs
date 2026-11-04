import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");

assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-cards-config,\s*\.bp-paper-contextual-controls\.bp-paper-stats-config\s*\{[^}]*bottom: 100%;/s,
  "shell: native collection configuration sits above authored content in every palette");
assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-cards-config\[open\],\s*\.bp-paper-contextual-controls\.bp-paper-stats-config\[open\]\s*\{[^}]*position: relative;/s,
  "shell: native collection fallback opens in flow without covering fields");
assert.match(css, /\[data-paper-palette="legacy"\] \.bp-paper-editor-body \.ProseMirror > p\s*\{\s*margin: 1em 0;\s*\}/,
  "shell: legacy paragraphs retain reader spacing without changing article typography");
assert.match(css, /\[data-paper-palette="legacy"\] \.bp-paper-contextual-controls\s*\{[^}]*bottom: 100%;/s,
  "shell: legacy fallback control sits above, not over, authored text");
assert.match(css, /\[data-paper-palette="legacy"\] \.bp-paper-contextual-controls\[open\]\s*\{[^}]*position: relative;/s,
  "shell: opened legacy configuration remains reachable in normal flow");

assert.match(css,
  /\.bp-canvas-card\s*>\s*bp-media-picker\.bp-canvas-card__media-picker\[hidden\]\s*\{[^}]*display:\s*none\s*!important/s,
  "shell: direct Card picker stays out of layout while its image owns activation");

assert.match(css, /\n\.bp-canvas-technical \{ overflow-x: visible; \}/,
  "shell: technical atom never clips the reader's evidence pull");

assert.match(css,
  /\[data-bp-fleet-body\] \[contenteditable="plaintext-only"\]\s*\{\s*cursor:\s*text;/,
  "shell: native inline fields keep the text cursor without changing reader DOM");

assert.match(css, /\[data-bp-text-boundary\]\s*\{[^}]*border-inline-start:/,
  "shell: public/Studio surface distinguishes the notice from authored prose");

assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-notes-config\s*\{[^}]*bottom: 100%;/s,
  "shell: notes configuration sits above the authored rows");
assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-notes-config\[open\]\s*\{[^}]*position: relative;/s,
  "shell: opened notes configuration flows without covering rows");

const rule = css.match(/\.bp-paper-surface \.bp-canvas-stats-inline > \.bp-paper-surface\s*\{([^}]+)\}/)?.[1];
assert.ok(rule, "shell: nested Stats paint retains the enclosing reader evidence band");
for (const token of ["band", "band-max", "fill", "gutter", "width", "pull"]) {
  assert.ok(rule.includes(`--bp-evidence-${token}: inherit;`), `shell: inherit ${token}`);
}
