// tooling/risk/test-proxy.mjs — the presence-PROXY score for the Tested
// dimension, used whenever a source file has no Istanbul coverage-final.json
// (most of js/, web/, packages/ and sdk/ — risk.mjs:108-218 only MEASURES
// coverage for Go + Elixir, and for JS packages that already ran vitest
// --coverage). Pulled out of risk.mjs (a long-running top-level script with
// no isMain guard) so it is a pure, millisecond-testable unit.
//
// THE BUG THIS FIXES: the old inline formula —
//   Math.min(100, (has ? 60 : 0) + Math.min(40, refs * 8))
// — gated the +60 "has a sibling test" bonus on FILE EXISTENCE alone. An
// empty placeholder `foo.test.ts` next to `foo.ts` scored 60/100, identical
// to a densely-asserted real suite. quality.mjs's Tested dimension (and the
// headline grade) then treated the placeholder as tested.
//
// THE FIX: the +60 bonus is now gated on ACTUAL ASSERTION DENSITY in the
// sibling's source — a zero-assertion sibling scores materially below a
// real one and reports source "proxy-unasserted" instead of "proxy", so the
// distinction survives into risk-report.json even though risk.mjs still
// falls back to the same presence-proxy shape for every other file.

// Assertion dialects actually in use across js/, web/ and tooling/ test
// suites (surveyed 2026-08-31): `expect(` dominates (jest/vitest — 121
// files), `assert.<method>(` is the node:assert/strict style (78 files,
// mostly tooling/), and a handful of bare `assert(` boolean checks. Also
// covers `t.deepEqual(` (tape/ava) and chai's `.should.<method>` even though
// neither appears in this repo today — the task brief names them explicitly
// as dialects to gate on, so a future suite written in either still counts.
const ASSERTION_PATTERNS = [
  /\bexpect\s*\(/g,
  /\bassert\.\w+\s*\(/g,
  /\bassert\s*\(/g,
  /\bt\.deepEqual\s*\(/g,
  /\.should\.\w+/g,
];

// Count assertion SITES in a sibling test file's source text. Pure string
// scan, no parsing — a heuristic density signal, not an AST-accurate count.
export function countAssertions(sourceText) {
  if (!sourceText) return 0;
  let n = 0;
  for (const re of ASSERTION_PATTERNS) {
    const m = sourceText.match(re);
    if (m) n += m.length;
  }
  return n;
}

// The refs component is UNCHANGED from the original inline formula: up to
// 40 points from how many times the module token shows up across the test
// corpus (8 points per reference, capped at 40).
function refsComponent(refs) {
  return Math.min(40, Math.max(0, refs || 0) * 8);
}

// scoreTestProxy(siblingSource, refs) -> { score, source }
//   siblingSource: the sibling test file's SOURCE TEXT, or null/undefined
//                   when risk.mjs found no sibling at all (siblingTestPath
//                   returned null). An empty string ("" — a zero-byte
//                   sibling) is still treated as "has a sibling" with zero
//                   assertions, which correctly falls into proxy-unasserted.
//   refs:           the existing testCorpus reference count for this file's
//                    module token (untouched by this fix).
//
// Returns the same proxyScore the old formula produced whenever the sibling
// carries real assertions (source: "proxy", so existing grades do not shift
// wholesale) — but when a sibling exists with ZERO assertion sites, the
// presence bonus drops from 60 to 10 and source is "proxy-unasserted".
export function scoreTestProxy(siblingSource, refs) {
  const hasSibling = siblingSource != null;
  const refsPart = refsComponent(refs);
  if (!hasSibling) return { score: Math.min(100, refsPart), source: "proxy" };

  const assertions = countAssertions(siblingSource);
  if (assertions === 0) {
    // Materially below the legacy 60 — an existing placeholder like `test.todo`
    // or an empty `describe` block still earns a small presence credit (a
    // sibling file is weak evidence of intent) but never reads as "tested".
    return { score: Math.min(100, 10 + refsPart), source: "proxy-unasserted" };
  }
  return { score: Math.min(100, 60 + refsPart), source: "proxy" };
}
