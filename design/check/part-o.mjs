// design/check/part-o.mjs — Part O of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { bumpFailed, failed, FAULT } from "./state.mjs";
import { atSource, ledger, readDesignSource } from "./part-e.mjs";
import { motionBlankAll } from "./part-m.mjs";

// ── Part O: hand-stamped TYPE/MEASURE literal ratchet ────────────────────────
// The third literal census, after Part E (colour) and Part N (duration). Both of
// those were written because nothing in the repo could SEE their category; type
// was the last blind one. Part E's LEDGER_LITERAL matches colour and only colour
// — `git grep font-size design/check.mjs` was empty before this part — so a
// hand-stamped `font-size: 13px` added to api/assets/paper-surface/paper-surface.css
// was invisible to every gate in CI. This part closes that hole with Part E's
// machinery, over size instead of colour.
//
// FILE SET — DERIVED, NEVER HAND-LISTED. The surfaces are exactly the `.css` /
// `.heex` members of the colour ledger (`entries` in design/exemptions.json):
// those are, by construction, the stylesheets the design system has already
// declared it owns. `type.entries` must COVER that derived set exactly — a new
// colour-ledger stylesheet reds this part until its type baseline is stamped
// too, and a stylesheet leaving the colour ledger reds it until its type row
// goes with it. The non-CSS colour entries (bp-graph.js Canvas renderers, the
// deploy.sh holding page) are excluded: they hold no CSS type declarations, and
// a row frozen at 0 would be a ratchet with nothing to hold.
//
// COUNTING RULE (documented here, next to the implementation, as E's and N's are):
//   A "type/measure literal" is a number carrying a `px`/`rem`/`em`/`ch` unit
//   inside the VALUE of a `font-size` / `letter-spacing` / `line-height` /
//   `max-width` declaration — plus, for `line-height` ONLY, a UNITLESS ratio
//   (`line-height: 1.45`), which is that property's ordinary hand-stamped form;
//   excluding it would leave line-height all but uncounted. `%` is not counted
//   (a percentage is relative layout, not a stamped measure).
//   `var(--bp-…)` is not a number and so is not counted — that is exactly what
//   lets a literal→token sweep register as a SHRINK.
//   PRECEDENCE — a fallback literal COUNTS: in `max-width: var(--x, 50ch)` the
//   `50ch` is counted. It is a hand-stamped value like any other; it paints
//   whenever the token is absent, and dropping it (the tokenized end state) must
//   register as a shrink, exactly as dropping a dead `var(--paper-x, #hex)`
//   colour fallback does under Part E.
//   Blanked before counting (newline-preserving, so no regex spans the gap):
//     1. every BEGIN/END GENERATED region — an emitted size is not a hand-stamp;
//     2. comments (CSS block, HTML, HEEx) — both via Part N's motionBlankAll,
//        whose extension set (.css/.heex/.html/.ex) is a superset of this one's;
//     3. `@media` PRELUDES — `@media (max-width: 720px)` is a layout breakpoint,
//        not a stamped measure, and counting it would red this gate on every new
//        responsive rule for no design reason. Declarations INSIDE the block are
//        still counted; only the condition list is blanked.
console.log("\ndesign/check.mjs — Part O: hand-stamped type/measure literal ratchet");
{
  let oFailed = 0;
  const oFail = (m) => { console.error(m); oFailed++; bumpFailed(); };

  const TYPE_DECL = /\b(font-size|letter-spacing|line-height|max-width)\s*:\s*([^;{}]*)/gi;
  const TYPE_UNIT = /(?<![\w.-])\d*\.?\d+(?:px|rem|em|ch)(?![\w-])/gi;
  // A bare ratio: a number not glued to a unit, a word, a `%` or a `#`.
  const TYPE_RATIO = /(?<![\w.#-])\d*\.?\d+(?![\w.%-])/g;
  const typeBlank = (m) => m.replace(/[^\n]/g, " ");

  function countTypeLiterals(path) {
    const src = motionBlankAll(readDesignSource(path), path)
      .replace(/@media[^{]*/gi, typeBlank);
    let n = 0;
    for (const m of src.matchAll(TYPE_DECL)) {
      const units = (m[2].match(TYPE_UNIT) || []).length;
      n += m[1].toLowerCase() === "line-height"
        // Strip the unit-bearing numbers first so `1.5rem` is not counted twice.
        ? units + (m[2].replace(TYPE_UNIT, " ").match(TYPE_RATIO) || []).length
        : units;
    }
    return n;
  }

  // The derived set: every stylesheet/template already on the COLOUR ledger.
  const derived = (ledger.entries || [])
    .map((e) => e.path)
    .filter((p) => p.endsWith(".css") || p.endsWith(".heex"));
  const typeLedger = (ledger.type && ledger.type.entries) || [];
  const stamped = typeLedger.map((e) => e.path);

  if (derived.length === 0)
    oFail(
      "  Part O FAIL: the derived file set is EMPTY — design/exemptions.json `entries` holds no " +
        ".css/.heex surface, so this ratchet would scan nothing and pass forever.",
    );
  const missing = derived.filter((p) => !stamped.includes(p));
  const orphan = stamped.filter((p) => !derived.includes(p));
  if (missing.length)
    oFail(
      `  Part O FAIL: ${missing.length} colour-ledger stylesheet(s) carry NO type baseline: ` +
        `${missing.join(", ")}.\n` +
        `    The file set is derived from \`entries\`, so a surface joining the colour ledger joins\n` +
        `    this one. Add a \`type.entries\` row with the COMPUTED count (run this gate to read it).`,
    );
  if (orphan.length)
    oFail(
      `  Part O FAIL: ${orphan.length} \`type.entries\` row(s) name a path that is no longer a ` +
        `.css/.heex colour-ledger entry: ${orphan.join(", ")}. Drop the row in the same diff.`,
    );

  const oRows = [];
  let oBaseTotal = 0, oActualTotal = 0;
  for (const entry of typeLedger) {
    if (!derived.includes(entry.path)) continue; // already reported as an orphan
    let actual, firstNew = null;
    try { actual = countTypeLiterals(entry.path); }
    catch (e) { oFail(`  Part O FAIL: ${entry.path} — cannot count (${e.message})`); continue; }
    const baseline = entry.count;
    oBaseTotal += baseline;
    oActualTotal += actual;
    const delta = actual - baseline;
    oRows.push({ path: entry.path, baseline, actual, delta });
    if (delta > 0) {
      // Name the offender, not just the number: find the LAST declaration this
      // file holds beyond the baseline's worth, which for an appended rule is
      // the one that was just added. Reported with line + text so the author
      // does not have to bisect the file.
      const src = motionBlankAll(readDesignSource(entry.path), entry.path)
        .replace(/@media[^{]*/gi, typeBlank);
      const hits = [];
      for (const m of src.matchAll(TYPE_DECL)) {
        const units = (m[2].match(TYPE_UNIT) || []).length;
        const k = m[1].toLowerCase() === "line-height"
          ? units + (m[2].replace(TYPE_UNIT, " ").match(TYPE_RATIO) || []).length
          : units;
        for (let i = 0; i < k; i++) hits.push(m);
      }
      const m = hits[baseline] || hits[hits.length - 1];
      if (m) {
        const line = src.slice(0, m.index).split("\n").length;
        firstNew = `${entry.path}:${line}: ${m[0].trim().replace(/\s+/g, " ").slice(0, 100)}`;
      }
      oFail(
        `  Part O FAIL: ${atSource(entry.path)} GREW ${baseline} → ${actual} (+${delta}). A new hand-stamped ` +
          `type/measure literal landed in a font-size/letter-spacing/line-height/max-width ` +
          `declaration.\n` +
          (firstNew ? `    first literal past the baseline: ${firstNew}\n` : "") +
          `    Consume the emitted type scale (var(--text-…)/var(--paper-…)) instead; if the value ` +
          `is genuinely un-tokenizable, RAISE the baseline in design/exemptions.json IN THIS SAME ` +
          `DIFF with a note saying which literal and why.`,
      );
    } else if (delta < 0) {
      oFail(
        `  Part O FAIL: ${entry.path} SHRANK ${baseline} → ${actual} (${delta}) — a type literal was ` +
          `tokenized (good!). LOWER the baseline to ${actual} in design/exemptions.json IN THIS SAME ` +
          `DIFF so the ratchet holds (a stale-high baseline lets a future regression hide under the slack).`,
      );
    }
  }

  // POSITIVE CONTROL. A census that scans zero files, or whose every row reads 0,
  // passes forever and measures nothing — the exact failure Part E's `_retired`
  // note records for the minified editor bundle. Assert the instrument has a
  // subject before believing its verdict.
  if (oRows.length === 0)
    oFail("  Part O FAIL: no type-ledger row was measured — this part scanned nothing and would pass forever.");
  else if (oRows.every((r) => r.actual === 0))
    oFail(
      "  Part O FAIL: every type-ledger row counted 0 literals. Either every stylesheet is fully " +
        "tokenized (then retire this part deliberately) or the counting rule stopped matching — " +
        "a census that finds nothing everywhere is a broken instrument, not a clean tree.",
    );

  {
    const pad = (s, n) => String(s).padEnd(n);
    const wPath = Math.max(4, ...oRows.map((r) => r.path.length));
    console.log(`  ${pad("path", wPath)}  baseline  actual  delta`);
    for (const r of oRows) {
      const mark = r.delta === 0 ? "ok  " : r.delta > 0 ? "GREW" : "SHRUNK";
      const d = r.delta > 0 ? `+${r.delta}` : String(r.delta);
      console.log(`  ${pad(r.path, wPath)}  ${pad(r.baseline, 8)}  ${pad(r.actual, 6)}  ${pad(d, 5)} ${mark}`);
    }
    console.log(`  ${pad("TOTAL", wPath)}  ${pad(oBaseTotal, 8)}  ${pad(oActualTotal, 6)}`);
  }

  if (FAULT.has("O")) oFail("  Part O FAIL: injected fault (--selftest)");
  if (!oFailed)
    console.log(
      `  ok   ${oRows.length} derived stylesheet(s), ${oActualTotal} hand-stamped type/measure ` +
        `literal(s) frozen — none grew, none silently shrank`,
    );
}
