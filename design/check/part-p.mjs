// design/check/part-p.mjs — Part P of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { AIR_ROW_SPLIT, AIR_STEPS, repoRoot, ruleGlyph, tokens } from "../emit.mjs";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part P: the TERMINAL space ladder reaches a real Go consumer ─────────────
// Parts J/K/L/M census the space families on the WEB surfaces, where a token is
// a CSS custom property and "dead" means nothing reads the var(). The same
// families now have a Go arm (internal/pdrender/tokens_gen.go), and that arm can
// go dead in a way no CSS census can see: a Go symbol that nothing references
// still COMPILES — package-level vars and consts are not unused-variable errors —
// so an emitted ladder can sit in a generated file forever, byte-perfect and
// rendering nothing. That is the exact failure mode the interim loop produced:
// four web devices shipped and pdrender got zero.
//
// So Part P asserts the same chain the CSS parts do, in Go terms:
//   1. EMITTED    — the symbol is in the generated file, with the value the
//                   generator derives from tokens.json (ratios verbatim, the
//                   collapse threshold, the gaps in whole rows, the two glyphs).
//   2. CONSUMED   — some NON-generated file in internal/pdrender references it.
//                   tokens_gen.go itself is excluded, so a symbol that only
//                   appears in its own declaration does not count as read.
// The ladder's SHAPE (exactly two rungs, monotonic, derived from the ratios
// rather than hand-listed) is asserted on the Go side, where it can be executed:
// internal/pdrender/air_test.go.
console.log("\ndesign/check.mjs — Part P: terminal space-ladder Go consumer census");
{
  const failedBeforeP = failed;
  const pFail = (m) => fail(m);
  const genPath = "internal/pdrender/tokens_gen.go";
  const gen = readFileSync(join(repoRoot, genPath), "utf8");
  // Every non-generated .go file in the package is a candidate consumer. Read
  // from disk rather than a hand list, so a consumer moved to a new file keeps
  // working and a consumer DELETED reds here.
  const pkgDir = join(repoRoot, "internal/pdrender");
  const consumers = readdirSync(pkgDir)
    .filter((f) => f.endsWith(".go") && f !== "tokens_gen.go")
    .map((f) => ({ path: `internal/pdrender/${f}`, text: readFileSync(join(pkgDir, f), "utf8") }));

  const air = tokens.space.air;
  const sec = tokens.space.section;
  // [symbol, the exact emitted line it must appear on]
  // Compared against a SPACE-COLLAPSED copy of the file: the generator aligns
  // the const block, so padding is a formatting detail and must not be the thing
  // this census pins. The VALUE is.
  const genFlat = gen.replace(/[ \t]+/g, " ");
  const expected = [
    ["GenAirRowSplit", `GenAirRowSplit = ${AIR_ROW_SPLIT}`],
    ["GenAirRowsDefault", "GenAirRowsDefault = 1"],
    ["GenSectionGapRows", `GenSectionGapRows = ${Math.round(sec.beat)}`],
    ["GenSectionHeadGapRows", `GenSectionHeadGapRows = ${Math.round(sec.gap / air.beat)}`],
    ["GenAirRatios", "var GenAirRatios = map[string]float64{"],
    ["GenAirOrder", `var GenAirOrder = []string{${AIR_STEPS.map((k) => `"${k}"`).join(", ")}}`],
    ["GenRuleGlyph", "var GenRuleGlyph = map[string]string{"],
  ];
  for (const [symbol, line] of expected) {
    if (!genFlat.includes(line))
      pFail(`  Part P FAIL: ${genPath} does not emit ${symbol} as \`${line}\` — the Go arm has drifted from design/tokens.json`);
    const hits = consumers.filter(({ text }) => text.includes(symbol));
    if (hits.length === 0)
      pFail(
        `  Part P FAIL: ${symbol} is emitted into ${genPath} but NOTHING in internal/pdrender reads it.\n` +
          `    An unreferenced Go symbol still compiles, so a dead token here is SILENT — the exact\n` +
          `    way pdrender ended up with four web devices and zero of its own. Either give it a\n` +
          `    consumer (air.go / pdrender.go / blocks.go) or drop it from the pdrenderGo() arm in\n` +
          `    design/emit.mjs.`,
      );
  }
  // Each air ratio is emitted VERBATIM — the Go side must never round, re-rank
  // or re-type them; the collapse is a predicate applied to these, not a table.
  for (const step of AIR_STEPS) {
    if (!genFlat.includes(`"${step}": ${air[step]},`))
      pFail(`  Part P FAIL: GenAirRatios does not carry ${step}: ${air[step]} verbatim from space.air`);
  }
  // Both rule weights resolve to DISTINCT glyphs — a ladder whose two rungs are
  // the same glyph draws structure and chrome at one weight, which is the drift
  // space.rule exists to refuse.
  const glyphs = [ruleGlyph(tokens.space.rule.hairline), ruleGlyph(sec.rule)];
  if (glyphs[0] === glyphs[1])
    pFail(`  Part P FAIL: hairline and section rules both resolve to ${JSON.stringify(glyphs[0])} — the terminal rule ladder has collapsed to one weight`);
  for (const [key, glyph] of [["hairline", glyphs[0]], ["section", glyphs[1]]])
    if (!gen.includes(`"${key}":`) || !gen.includes(JSON.stringify(glyph)))
      pFail(`  Part P FAIL: GenRuleGlyph does not emit ${key} as ${JSON.stringify(glyph)}`);

  if (FAULT.has("P")) pFail("  Part P FAIL: injected fault (--selftest)");
  if (failed === failedBeforeP)
    console.log(
      `  ok   ${expected.length} terminal space symbols emitted from space.air/section/rule, ` +
        `each read by a live consumer in internal/pdrender (${consumers.length} candidate file(s))`,
    );
}
