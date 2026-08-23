// __narrow_overflow_guards.test.mjs — jf-w1-engine-narrow-dark-fixes source guard.
//
// task-0e7a1a8ed32b5de5 found two criteria on jf-w1-engine-narrow-dark-fixes
// stamped met=true for CSS that was never pushed to origin/main:
//   1. .bp-lineage__body had no overflow-wrap/word-break — .bp-lineage__nodes
//      is an auto-fit minmax(150px,1fr) grid, so a node can be squeezed to its
//      150px floor at narrow measures, and a long unbroken body string (a URL,
//      a compound word) then blows the column out sideways instead of wrapping.
//   2. .bp-duel__table had no self-containment — it is a plain width:100% table
//      with no display:block/max-width/overflow-x, unlike .bp-table (which
//      already carries the three-declaration escape hatch for exactly this).
//
// Both were re-built from scratch here (the original branch never reached
// origin/main) rather than re-landed blind. This is the source guard that was
// missing the first time: it reds if either rule regresses to its pre-fix
// shape, so a future edit that reintroduces the bug is caught before a stamp
// can outlive the code again.
//
// Run: node src/__narrow_overflow_guards.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
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

const surface = readRepo("api/assets/paper-surface/paper-surface.css");

function ruleFor(selector, css) {
  // First `.selector { ... }` occurrence — mirrors __code_interior.test.mjs's
  // approach of matching one canonical declaration block, not every mention
  // of the class name (data_viz.ex/comments also say the string).
  const re = new RegExp(
    selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}",
  );
  const m = css.match(re);
  assert.ok(m, `no "${selector} { ... }" rule found in paper-surface.css`);
  return m[1];
}

// ── 1. .bp-lineage__body wraps a long unbroken string ─────────────────────────

check(".bp-lineage__body carries an overflow-wrap guard", () => {
  const decls = ruleFor(".bp-paper-surface .bp-lineage__body", surface);
  assert.ok(
    /overflow-wrap\s*:\s*anywhere/.test(decls),
    ".bp-lineage__body must set overflow-wrap: anywhere — without it a long " +
      "unbroken body string blows out the 150px-floor grid column sideways " +
      "instead of wrapping (task-0e7a1a8ed32b5de5).",
  );
  // The pre-existing declarations must survive the edit untouched.
  for (const must of ["font-size: 0.76rem", "line-height: 1.45", "margin-top: 5px"]) {
    assert.ok(decls.includes(must), `.bp-lineage__body lost a pre-existing declaration: ${must}`);
  }
});

// ── 2. .bp-duel__table self-contains like .bp-table does ──────────────────────

check(".bp-duel__table self-contains horizontally, .bp-table's own escape hatch", () => {
  const decls = ruleFor(".bp-paper-surface .bp-duel__table", surface);
  for (const must of ["display: block", "max-width: 100%", "overflow-x: auto"]) {
    assert.ok(
      decls.includes(must),
      `.bp-duel__table is missing "${must}" — without the full three-declaration ` +
        "escape hatch (.bp-table's own pattern) a wide duel table cannot scroll " +
        "and instead pushes the whole page wider at narrow measures.",
    );
  }
  // width:100% must survive — it is what keeps desktop (>=720px) unchanged.
  assert.ok(decls.includes("width: 100%"), ".bp-duel__table must keep width:100% so desktop layout is unchanged.");
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
