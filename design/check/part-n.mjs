// design/check/part-n.mjs — Part N of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { MOTION_STEPS, MOTION_SURFACES, tokens } from "../emit.mjs";
import { bumpFailed, failed, FAULT } from "./state.mjs";
import { want } from "./part-b.mjs";
import { atSource, ledger, readDesignSource } from "./part-e.mjs";
import { motionBlankAll, motionBlankComments } from "./part-m.mjs";

// ── Part N: motion-ladder parity + hand-typed duration ratchet ───────────────
// The motion twin of Part C (type-scale parity) and Part E (the colour-literal
// ratchet). tokens.json has carried motion.dur-1/-2/-3 since the first token
// file and design/emit.mjs emitted NONE of it: `grep -rn -- "--dur-" api/`
// returned exactly one hit, a COMMENT in root.html.heex explaining that a
// var(--dur-1) there would resolve to nothing. Every Studio transition was a
// hand-typed literal and nothing could see them, because the only literal census
// in this file counts COLOURS. spd-b21 emits the ladder; this part is what keeps
// it from decaying back.
//
// ── arm 1: parity + no shadow ────────────────────────────────────────────────
// For every surface on MOTION_SURFACES, each `--dur-N` must be declared with the
// tokens.json byte and declared EXACTLY ONCE. The uniqueness half is not
// pedantry: a second declaration LATER in the same file wins the cascade, so a
// hand-authored copy would keep painting while the generated one — the thing this
// gate reads — sits inert. A value-only assertion would report green while the
// surface ignored the token entirely.
//
// The ONE legitimate re-declaration is the reduced-motion collapse
// (`@media (prefers-reduced-motion: reduce) { :root { --dur-N: 0s } }`), which
// zeroes the ladder rather than shadowing it. It is recognised by its VALUE
// (`0s`) — not by an allowlist of paths — so it stays available to every surface
// and cannot be stretched to cover a literal that actually paints.
//
// ── arm 2: the hand-typed duration ratchet ───────────────────────────────────
// Exactly Part E's shape, over time instead of colour. design/exemptions.json
// `motion.entries` freezes the count of hand-typed duration literals per surface;
// any drift fails, up OR down, and the baseline must move in the same diff.
//
// COUNTING RULE (documented next to the implementation, as Part E's is):
//   A "duration literal" is a `<number>s` or `<number>ms` appearing inside the
//   VALUE of a `transition` / `transition-duration` / `transition-delay` /
//   `animation` / `animation-duration` / `animation-delay` declaration. A
//   `var(--dur-N)` is not a number and so is not counted — which is precisely
//   what lets a literal→token sweep register as a SHRINK. Times outside a motion
//   declaration are invisible here on purpose: `PUSH_TIMEOUT is 30000ms` in a
//   comment, a `phx-remove` JS `time: 320`, and a `<meta http-equiv="refresh">`
//   are not motion design. Before counting, the same two noise sources Part E
//   blanks are blanked (newline-preserving): every BEGIN/END GENERATED region —
//   an emitted duration is not a hand-stamp — and comments. Part E's
//   stripLedgerNoise is NOT reused: this ledger also scans `.ex` (the login
//   heredoc) and `.html` (the styleguide), which Part E's rule does not strip,
//   and widening the shared helper would silently move every colour baseline.
console.log("\ndesign/check.mjs — Part N: motion-ladder parity + hand-typed duration ratchet");
{
  let nFailed = 0;
  const nFail = (m) => { console.error(m); nFailed++; bumpFailed(); };

  // ── arm 1: the ladder reaches every emitting surface, exactly once ─────────
  const unit = tokens.motion._unit;
  for (const path of MOTION_SURFACES) {
    let text;
    try { text = readDesignSource(path); }
    catch (e) { nFail(`  Part N FAIL: ${path} — cannot read (${e.message})`); continue; }
    const src = motionBlankComments(text, path);
    for (const step of MOTION_STEPS) {
      const want = `${tokens.motion[step]}${unit}`;
      const decls = [...src.matchAll(new RegExp(`--${step}\\s*:\\s*([^;}]+)`, "g"))]
        .map((m) => m[1].trim());
      // The reduced-motion collapse zeroes the ladder; it is not a shadow.
      const painting = decls.filter((v) => v !== "0s");
      if (painting.length === 0) {
        nFail(
          `  Part N FAIL: ${path} declares no --${step}.\n` +
            `    It is on MOTION_SURFACES in design/emit.mjs — it draws transitions, so the ladder\n` +
            `    has to reach it. Most entries get it from the GENERATED block (\`node design/emit.mjs\n` +
            `    --write\`); cloud/priv/static/app.css declares it by hand in its decision-29 token\n` +
            `    area. Restore whichever applies, or drop the surface from the list if it genuinely\n` +
            `    no longer consumes durations.`,
        );
        continue;
      }
      if (painting.length > 1) {
        nFail(
          `  Part N FAIL: ${path} declares --${step} ${painting.length} times ` +
            `(${painting.map((v) => JSON.stringify(v)).join(", ")}).\n` +
            `    The LAST one wins the cascade, so a hand-authored copy keeps painting while the\n` +
            `    emitted declaration this gate reads sits inert — a token that is decorative again.\n` +
            `    Delete the hand copy and let the GENERATED block own the value. (A\n` +
            `    \`@media (prefers-reduced-motion: reduce)\` collapse to \`0s\` is exempt: it zeroes\n` +
            `    the ladder rather than replacing it.)`,
        );
        continue;
      }
      if (painting[0] !== want)
        nFail(
          `  Part N FAIL: ${path} declares --${step}: ${painting[0]} ≠ ` +
            `tokens.motion["${step}"] ${want}`,
        );
    }
  }

  // ── arm 2: the hand-typed duration ratchet ────────────────────────────────
  const MOTION_DECL = /\b(?:transition|animation)(?:-duration|-delay)?\s*:\s*([^;{}]*)/gi;
  const MOTION_LITERAL = /(?<![\w.-])\d*\.?\d+m?s(?![\w-])/gi;

  function countMotionLiterals(path) {
    const src = motionBlankAll(readDesignSource(path), path);
    let n = 0;
    for (const m of src.matchAll(MOTION_DECL)) n += (m[1].match(MOTION_LITERAL) || []).length;
    return n;
  }

  const motionLedger = (ledger.motion && ledger.motion.entries) || [];
  if (motionLedger.length === 0)
    nFail("  Part N FAIL: design/exemptions.json carries no `motion.entries` — the ratchet has nothing to hold");

  const rows = [];
  let baseTotal = 0, actualTotal = 0;
  for (const entry of motionLedger) {
    let actual;
    try { actual = countMotionLiterals(entry.path); }
    catch (e) { nFail(`  Part N FAIL: ${entry.path} — cannot count (${e.message})`); continue; }
    const baseline = entry.count;
    baseTotal += baseline;
    actualTotal += actual;
    const delta = actual - baseline;
    rows.push({ path: entry.path, baseline, actual, delta });
    if (delta > 0)
      nFail(
        `  Part N FAIL: ${atSource(entry.path)} GREW ${baseline} → ${actual} (+${delta}). A new hand-typed ` +
          `duration literal landed in a transition/animation declaration. Spend a ladder rung — ` +
          `var(--dur-1|--dur-2|--dur-3) — from the emitted GENERATED block; if the timing is ` +
          `genuinely off-ladder (a spinner loop, a long attention pulse), RAISE the baseline in ` +
          `design/exemptions.json IN THIS SAME DIFF with a note saying which literal and why.`,
      );
    else if (delta < 0)
      nFail(
        `  Part N FAIL: ${entry.path} SHRANK ${baseline} → ${actual} (${delta}) — a duration was ` +
          `tokenized (good!). LOWER the baseline to ${actual} in design/exemptions.json IN THIS ` +
          `SAME DIFF so the ratchet holds.`,
      );
  }

  {
    const pad = (s, n) => String(s).padEnd(n);
    const wPath = Math.max(4, ...rows.map((r) => r.path.length));
    console.log(`  ${pad("path", wPath)}  baseline  actual  delta`);
    for (const r of rows) {
      const mark = r.delta === 0 ? "ok  " : r.delta > 0 ? "GREW" : "SHRUNK";
      const d = r.delta > 0 ? `+${r.delta}` : String(r.delta);
      console.log(`  ${pad(r.path, wPath)}  ${pad(r.baseline, 8)}  ${pad(r.actual, 6)}  ${pad(d, 5)} ${mark}`);
    }
    console.log(`  ${pad("TOTAL", wPath)}  ${pad(baseTotal, 8)}  ${pad(actualTotal, 6)}`);
  }

  if (FAULT.has("N")) nFail("  Part N FAIL: injected fault (--selftest)");
  if (!nFailed)
    console.log(
      `  ok   the ${MOTION_STEPS.length}-rung motion ladder reaches ${MOTION_SURFACES.length} surface(s) ` +
        `with tokens.json's bytes and no shadow declaration; ${rows.length} ledgered surface(s), ` +
        `${actualTotal} hand-typed duration literal(s) frozen — none grew, none silently shrank`,
    );
}
