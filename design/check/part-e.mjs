// design/check/part-e.mjs — Part E of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { assembledText } from "../../api/assets/paper-editor/scripts/source-assets.mjs";
import { readAuthoredCss } from "../../api/assets/paper-editor/src/__css_source_graph.mjs";
import { repoRoot } from "../emit.mjs";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part E: hand-stamped color-literal exemption ledger ──────────────────────
// The theme-system north star is "no surface holds a color literal the compiler
// did not put there." We are mid-migration — a handful of surfaces still carry
// hand-stamped literals the emitter has not yet reached. design/exemptions.json
// FREEZES the current count per surface; this part re-counts and FAILS on ANY
// drift. It is a one-way ratchet: the number may only go DOWN, and every change
// (up OR down) must be accompanied by a baseline edit in the SAME diff.
//
//   • growth  → a NEW hand-stamped literal slipped in — a regression.
//   • shrink  → a literal was tokenized — good, but the baseline MUST be lowered
//               in the same diff so the ratchet keeps holding (a stale-high
//               baseline would let a future regression hide under the slack).
//
// COUNTING RULE (documented here, next to the implementation):
//   A "color literal" is `#hex` (3-8 hex digits, word-bounded) OR an
//   rgb()/rgba()/hsl()/hsla() whose first argument is NOT `var(` — i.e. a literal
//   channel value, not compiler-driven token consumption. `hsl(var(--x) / .1)` is
//   EXCLUDED on purpose: it is exactly the tokenized form we want, and excluding
//   it is what lets a literal→var() conversion show up as a shrink (a hex or
//   literal-hsl disappears and its var() replacement is not re-counted).
//   Before counting, two noise sources are blanked (newline-preserving, so the
//   regex can't match across them):
//     1. every BEGIN/END GENERATED: <name> marker region — a generator owns those
//        literals, so they are not hand-stamps. Three generators emit such blocks:
//        `tokens` (design/emit.mjs), `paper-surface` (the reader→editor mirror), and
//        `status-tones` (the status skin) — all blanked, and
//     2. comments — CSS `/* … */`, HTML `<!-- … -->`, and HEEx `<%!-- … --%>` /
//        `<%# … %>` — so e.g. the `#940` PR-ref inside app.css's
//        `/* Pre-claim queued state (#940) … */` note is not miscounted as a hex.
//   Shell (.sh) carries no scanned comment syntax here (the only literals are the
//   4 hex in the holding-page <style>, which live inside a heredoc, not a `#`
//   comment), so no comment pass runs for it.
console.log("\ndesign/check.mjs — Part E: hand-stamped color-literal exemption ledger");
const failedBeforeE = failed;

const here = dirname(dirname(fileURLToPath(import.meta.url)));
const PACKAGE_CSS_PATH = "api/assets/paper-editor/src/styles.css";
// The raw surface is read from the package's assembled fragments, its source. The
// sink path stays the name these Parts report and design/exemptions.json keys on,
// because the sink holds these same bytes (sync-barkpark --check).
const RAW_SURFACE_PATH = "api/assets/paper-surface/paper-surface.css";
// A failure on that name tells the reader where the literal really lives.
const atSource = (path) => path === RAW_SURFACE_PATH ? `${path} (edit its fragment under api/assets/paper-editor/src/paper-surface/, not this synced copy)` : path;
const readDesignSource = (path) => path === PACKAGE_CSS_PATH
  ? readAuthoredCss()
  : path === RAW_SURFACE_PATH
    ? assembledText("paper-surface", { root: join(repoRoot, "api/assets/paper-editor") })
    : readFileSync(join(repoRoot, path), "utf8");
// Any generator-owned block — `/* BEGIN GENERATED: <name> … END GENERATED: <name> */`
// — is emitter output, not a hand-stamp. Today three generators write such blocks:
// `tokens` (the theme compiler, design/emit.mjs), `paper-surface` (the reader→editor
// mirror, scripts/paper-editor-mirror-check.sh), and `status-tones` (the status skin,
// scripts/status-manifest-check.sh). The name is captured and back-referenced so the
// END must match its own BEGIN — abutting blocks (status-tones then tokens in
// paper-surface.css) each strip cleanly instead of one swallowing the other.
const LEDGER_MARKER =
  /[ \t]*\/\* BEGIN GENERATED: ([\w-]+)[\s\S]*?END GENERATED: \1 \*\//g;
const LEDGER_LITERAL = /#[0-9a-fA-F]{3,8}\b|(?:rgba?|hsla?)\(\s*(?!var\()/gi;
const ledgerBlank = (m) => m.replace(/[^\n]/g, " ");

function stripLedgerNoise(text, path) {
  let s = text.replace(LEDGER_MARKER, ledgerBlank);
  if (path.endsWith(".css") || path.endsWith(".heex")) {
    s = s.replace(/\/\*[\s\S]*?\*\//g, ledgerBlank); // CSS / <style> block comments
  }
  if (path.endsWith(".heex")) {
    s = s
      .replace(/<!--[\s\S]*?-->/g, ledgerBlank)   // HTML comments
      .replace(/<%!--[\s\S]*?--%>/g, ledgerBlank) // HEEx public comments
      .replace(/<%#[\s\S]*?%>/g, ledgerBlank);    // HEEx code comments
  }
  return s;
}

function countLedgerLiterals(path) {
  const text = readDesignSource(path);
  const cleaned = stripLedgerNoise(text, path);
  return (cleaned.match(LEDGER_LITERAL) || []).length;
}

let ledger;
try {
  ledger = JSON.parse(readFileSync(join(here, "exemptions.json"), "utf8"));
} catch (e) {
  fail(`  Part E FAIL: cannot read design/exemptions.json — ${e.message}`);
  ledger = { entries: [] };
}

const ledgerRows = [];
let ledgerBaselineTotal = 0, ledgerActualTotal = 0;
for (const entry of ledger.entries) {
  let actual;
  try { actual = countLedgerLiterals(entry.path); }
  catch (e) {
    fail(`  Part E FAIL: ${entry.path} — cannot count (${e.message})`);
    continue;
  }
  const baseline = entry.count;
  ledgerBaselineTotal += baseline;
  ledgerActualTotal += actual;
  const delta = actual - baseline;
  ledgerRows.push({ path: entry.path, baseline, actual, delta });
  if (delta > 0) {
    fail(
      `  Part E FAIL: ${atSource(entry.path)} GREW ${baseline} → ${actual} (+${delta}). A new ` +
      `hand-stamped color literal was added outside the generated block. Tokenize it ` +
      `(consume var(--…) from the emitted BEGIN/END GENERATED block); if it is genuinely ` +
      `un-tokenizable, RAISE the baseline in design/exemptions.json IN THIS SAME DIFF with a note.`
    );
  } else if (delta < 0) {
    fail(
      `  Part E FAIL: ${entry.path} SHRANK ${baseline} → ${actual} (${delta}) — a literal was ` +
      `tokenized (good!). LOWER the baseline to ${actual} in design/exemptions.json IN THIS SAME ` +
      `DIFF so the ratchet holds (a stale-high baseline lets a future regression hide under the slack).`
    );
  }
}

// Ledger table (path, baseline, actual, delta) — always printed, pass or fail.
{
  const pad = (s, n) => String(s).padEnd(n);
  const wPath = Math.max(4, ...ledgerRows.map((r) => r.path.length));
  console.log(`  ${pad("path", wPath)}  baseline  actual  delta`);
  for (const r of ledgerRows) {
    const mark = r.delta === 0 ? "ok  " : r.delta > 0 ? "GREW" : "SHRUNK";
    const d = r.delta > 0 ? `+${r.delta}` : String(r.delta);
    console.log(`  ${pad(r.path, wPath)}  ${pad(r.baseline, 8)}  ${pad(r.actual, 6)}  ${pad(d, 5)} ${mark}`);
  }
  console.log(`  ${pad("TOTAL", wPath)}  ${pad(ledgerBaselineTotal, 8)}  ${pad(ledgerActualTotal, 6)}`);
}

if (FAULT.has("E")) fail("  Part E FAIL: injected fault (--selftest)");
if (failed === failedBeforeE)
  console.log(
    `  ok   ${ledgerRows.length} ledgered surface(s), ${ledgerActualTotal} hand-stamped ` +
    `literal(s) frozen — none grew, none silently shrank`
  );

export { atSource, here, ledger, LEDGER_MARKER, RAW_SURFACE_PATH, readDesignSource };
