// __callout_parity.test.mjs — loop-epic/parity-callout: the callout node-view
// View⇄Edit parity guard (pure-Node source assertion, same technique as
// __atom_chrome.test.mjs — a node-view cannot mount headless, so we assert the
// SOURCE that builds its DOM).
//
// The reader (walk.ex callout/3 :article) paints a callout as a tone card whose
// colour rides ENTIRELY on the `bp-callout--<tone>` class (→ --bp-tone-<tone>-*
// tokens, light + dark), with a RUN-IN <strong> title and NO icon; the
// collapsible variant is a native <details>/<summary class="bp-callout__summary">
// disclosure. This guard freezes the edit node-view to that shape so a refactor
// cannot silently re-introduce inline tone paint, an icon, or an edit-only
// <button> fold — any of which would drift Edit away from View.
//
// Run: node src/__callout_parity.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(__dirname, "canvas/callout-node.js"), "utf8");

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

// ── (a) DARK-TONE binding: colour rides the class, never inline paint ────────
check("callout binds tone via bp-callout--<tone> class, not inline paint", () => {
  assert.ok(
    /bp-callout--/.test(src),
    "callout-node.js no longer applies a `bp-callout--<tone>` class — tone colour " +
      "would stop resolving the --bp-tone-* tokens (light+dark) and drift from View.",
  );
  assert.ok(
    !/style\.(background|borderLeft|color)\s*=/.test(src),
    "callout-node.js writes an inline tone style (background/borderLeft/color) — " +
      "tone must ride the `bp-callout--<tone>` class ONLY, or the dark-mode token " +
      "swap silently drifts from the reader.",
  );
  assert.ok(
    !/CALLOUT_TONES|calloutToneChrome/.test(src),
    "callout-node.js still carries the deleted hex tone map (CALLOUT_TONES / " +
      "calloutToneChrome) — colour must come from the --bp-tone-* tokens, not hex.",
  );
});

// The tone class helper must mirror walk.ex callout_tone_class/1 EXACTLY (the
// canonical five or `info`) — NOT tone.js normalizeTone, which alias-expands.
check("callout resolves its tone class with the canonical-5-or-info helper (no alias expansion)", () => {
  assert.ok(
    /calloutToneClass/.test(src),
    "callout-node.js dropped calloutToneClass — reusing tone.js normalizeTone " +
      "would alias-expand (note→info, warn→warning) and diverge from the reader.",
  );
  assert.ok(
    !/normalizeTone/.test(src),
    "callout-node.js references normalizeTone — its alias expansion diverges from " +
      "walk.ex callout_tone_class/1 (canonical-5-or-info); use calloutToneClass.",
  );
});

// ── (b) RUN-IN structure: a <strong> title, no icon ──────────────────────────
check("callout builds a run-in <strong> title and NO icon", () => {
  assert.ok(
    /createElement\(\s*["']strong["']\s*\)/.test(src),
    "callout-node.js no longer builds a <strong> run-in title (reader emits " +
      "`<strong>title</strong> ` inline before the body).",
  );
  assert.ok(
    !/callout-icon/.test(src),
    "callout-node.js still builds a `callout-icon` — the reader paints NO icon; " +
      "an icon in Edit only would be a View⇄Edit divergence.",
  );
  assert.ok(
    !/\.icon\b/.test(src),
    "callout-node.js references an `.icon` chrome descriptor — the tone icon map " +
      "was deleted; the reader has no callout icon.",
  );
});

// ── (c) reader-shaped disclosure: native <details>/<summary>, no <button> ────
check("collapsible callout builds a native <details>/<summary> disclosure (not a <button> fold)", () => {
  assert.ok(
    /createElement\(\s*["']details["']\s*\)/.test(src),
    "callout-node.js no longer builds a <details> — the collapsible variant must " +
      "mirror the reader's native <details> disclosure (collapsible_callout_article/3).",
  );
  assert.ok(
    /createElement\(\s*["']summary["']\s*\)/.test(src),
    "callout-node.js no longer builds a <summary> — the reader emits " +
      "`<summary class=\"bp-callout__summary\">`.",
  );
  assert.ok(
    /bp-callout__summary/.test(src),
    "callout-node.js dropped the `bp-callout__summary` class — the summary would " +
      "stop being painted by the reader's summary rule.",
  );
  assert.ok(
    !/createElement\(\s*["']button["']\s*\)/.test(src),
    "callout-node.js still builds a <button> fold — the disclosure moved to a " +
      "native <details>/<summary>; an edit-only <button> is forbidden chrome (rule 6).",
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
