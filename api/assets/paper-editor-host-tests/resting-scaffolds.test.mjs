// Barkpark's committed shell and canonical reader surface preserve the host
// half of resting-scaffold geometry. Runtime state/history stays package-owned.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

for (const path of ["../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(path, import.meta.url), "utf8");
  assert.match(css, /\.bp-expandable__body \.bp-paper-editor-body > \.ProseMirror > h2\s*\{\s*margin-top: 1\.9em; border-top: 0; padding-top: 0;/, "nested headings do not acquire root section rules");
  assert.match(css, /\.bp-paper-editor-body \.ProseMirror > \.bp-resting-scaffold\s*\{\s*display: none;/, "the committed host shell preserves reader margin collapse");
  assert.match(css, /\.bp-paper-editor-body \.bp-scaffold-control:focus-visible\s*\{\s*outline: 2px solid var\(--paper-accent\)/, "hidden content controls retain visible keyboard focus");
  assert.match(css, /@media \(max-width: 720px\)\s*\{[^}]*\.bp-section__cell\s*\{\s*grid-column: 1 \/ -1 !important;/, "mobile section spans cannot create implicit columns");
}
assert.match(readFileSync(new URL("../paper-surface/paper-surface.css", import.meta.url), "utf8"), /@media \(max-width: 720px\)\s*\{[^}]*\.bp-section__cell\s*\{\s*grid-column: 1 \/ -1 !important;/, "reader uses the same mobile span reset");
