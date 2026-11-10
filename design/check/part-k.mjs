// design/check/part-k.mjs — Part K of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { EVIDENCE_KEYS, EVIDENCE_UNITS, tokens } from "../emit.mjs";
import { fail, FAULT } from "./state.mjs";
import { RAW_SURFACE_PATH, readDesignSource } from "./part-e.mjs";

// ── Part K: the EVIDENCE BAND reaches a real consumer ────────────────────────
// space.evidence emits five `--tok-evidence-*` inputs; paper-surface.css bridges
// each onto `--bp-evidence-*` and composes four of them into ONE derived width,
// which the breakout rules and the article <figure> emitters then read.
//
// That chain has three distinct ways to go quietly dead, and Part J's shape only
// catches the first:
//
//   1. a token emitted and bridged but read by nothing — the pe-w1 defect.
//   2. a token bridged and read ONLY by its own bridge, i.e. dropped out of the
//      `--bp-evidence-width` composition. The band would still resolve, still
//      look plausible, and silently stop honouring (say) the gutter — which is
//      the one term standing between the band and a sideways-scrolling page.
//   3. a breakout rule that takes the WIDTH but not the PULL. The component
//      grows to the right instead of growing about its centre: still wide, still
//      green on any width assertion, and visibly off-axis on the page. So the
//      two are censused as a PAIR, per rule, and a half-breakout reds.
console.log("\ndesign/check.mjs — Part K: evidence-band consumer census");
{
  // Part K counts its OWN failures in `kFailed` as well as calling `fail`. That
  // local count was once the ONLY defence against a sticky shared flag: `failed`
  // was a boolean, so once ANY earlier part had tripped it, `failed ===
  // failedBefore<X>` was true again and a part printed its green line beside its
  // own red ones. Proven while mutation-testing this part — dropping the gutter
  // term reds the mirror check first, and Part K then printed both two FAILs and
  // its `ok`. `failed` is now a COUNT (see its declaration at the top of this
  // file), so `failed === failedBefore<X>` is a per-part delta and Parts D-J are
  // correct by the same construction. `kFailed` is redundant with that now, and is
  // kept only because Parts L-O already spell the same local-count idiom (lFailed,
  // mFailed, nFailed, oFailed); churning five parts to save five lines would cost
  // more in review than it buys.
  let kFailed = false;
  const kFail = (msg) => { kFailed = true; fail(msg); };
  const kebab = (s) => s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
  const surfacePath = RAW_SURFACE_PATH;
  const surfaceCss = readDesignSource(surfacePath);
  // Consumers may live in the stylesheet OR inline on renderer output — a figure
  // has to survive a stylesheet-less sink, so its width and pull ride inline
  // `var(--bp-evidence-*, <fallback>)` in the emitting Elixir source, exactly as
  // its air beat does.
  const consumerSources = [
    surfacePath,
    "api/lib/barkpark/portable_doc/render/figures.ex",
    "api/lib/barkpark/portable_doc/render/compose.ex",
    "api/lib/barkpark/portable_doc/render/components.ex",
  ].map((p) => ({ path: p, text: readDesignSource(p) }));

  const readsOf = (name) =>
    consumerSources.flatMap(({ path, text }) =>
      text
        .split("\n")
        .filter((l) => l.includes(`var(--bp-evidence-${name}`) && !l.includes(`--bp-evidence-${name}: var(`))
        .map((l) => `${path}: ${l.trim().slice(0, 80)}`),
    );

  for (const key of EVIDENCE_KEYS) {
    const name = kebab(key);
    const value = `${tokens.space.evidence[key]}${EVIDENCE_UNITS[key]}`;
    // 1. emitted, with its authored unit — `fill` is a bare ratio and `caption`
    //    is a character count; emitting either as px is the drift this catches.
    if (!surfaceCss.includes(`--tok-evidence-${name}: ${value};`))
      kFail(`  Part K FAIL: --tok-evidence-${name} is not emitted as ${value} in ${surfacePath}`);

    // 2. bridged onto the --bp-* name every rule reads.
    if (!surfaceCss.includes(`--bp-evidence-${name}: var(--tok-evidence-${name});`))
      kFail(`  Part K FAIL: --bp-evidence-${name} has no bridge onto --tok-evidence-${name} in ${surfacePath}`);

    // 3. actually READ. The bridge line itself is excluded, so a bridge that only
    //    feeds itself does not count as a consumer.
    if (readsOf(name).length === 0)
      kFail(
        `  Part K FAIL: --bp-evidence-${name} is emitted and bridged but NOTHING consumes it.\n` +
          `    A token with no reader is not a single source — it is a dead one. Either fold it\n` +
          `    into the --bp-evidence-width composition, give it a rule, or drop it from\n` +
          `    space.evidence + EVIDENCE_KEYS in design/emit.mjs.`,
      );
  }

  // The derived pair. `width` composes the four geometry inputs; `pull` re-centres
  // the wider box on the column's axis. Neither is a token — both are the law —
  // so they are censused for consumers the same way.
  const widthDecl = surfaceCss.split("\n").find((l) => l.includes("--bp-evidence-width: "));
  if (!widthDecl) {
    kFail(`  Part K FAIL: ${surfacePath} declares no --bp-evidence-width — the band has no composed law`);
  } else {
    for (const key of ["band", "bandMax", "fill", "gutter"]) {
      const name = kebab(key);
      if (!widthDecl.includes(`var(--bp-evidence-${name})`))
        kFail(
          `  Part K FAIL: --bp-evidence-width does not read --bp-evidence-${name}.\n` +
            `    The band would still resolve and still look plausible while silently ignoring\n` +
            `    that term — and 'gutter' is the only thing keeping the band off the viewport edge.`,
        );
    }
  }
  for (const derived of ["width", "pull"]) {
    if (readsOf(derived).length === 0)
      kFail(`  Part K FAIL: --bp-evidence-${derived} is composed but NOTHING consumes it — the band is computed and never applied`);
  }

  // The shipped breakout SET, each rule censused for the width/pull PAIR. These
  // are the components the wave decided improve with width; a class listed here
  // that stops breaking out reds, and so does one that breaks out by half.
  const BREAKOUT_RULES = [".bp-table", ".bp-stats", ".bp-chart", ".bp-diff", ".bp-filetree"];
  for (const cls of BREAKOUT_RULES) {
    const rule = surfaceCss
      .split("}")
      .find((block) => block.includes(`.bp-paper-surface ${cls} {`) || block.includes(`.bp-paper-surface ${cls},`));
    if (!rule) {
      kFail(`  Part K FAIL: no .bp-paper-surface ${cls} rule in ${surfacePath} — the breakout set names a component that is not styled here`);
      continue;
    }
    for (const half of ["width", "pull"]) {
      if (!rule.includes(`var(--bp-evidence-${half}`))
        kFail(
          `  Part K FAIL: .bp-paper-surface ${cls} does not read --bp-evidence-${half}.\n` +
            `    A component takes the band's width and its centring pull TOGETHER; with only\n` +
            `    one it grows off-axis instead of about the column's centre.`,
        );
    }
  }

  // The four article <figure> emitters carry the same pair inline. Counted, not
  // just found: three of the four live in figures.ex and one in compose.ex, and a
  // figure family that silently loses the breakout is exactly the regression the
  // count catches. Any attribute may precede `style` (the diagram figure carries
  // `class="bp-diagram"` first), so the match is on the tag, not its first byte.
  const figureBreakouts = consumerSources
    .filter(({ path }) => path.endsWith(".ex"))
    .flatMap(({ text }) => text.split("\n").filter((l) => /<figure\b[^>]*\sstyle=/.test(l) && l.includes("--bp-evidence-width")));
  if (figureBreakouts.length !== 4)
    kFail(
      `  Part K FAIL: ${figureBreakouts.length} article <figure> emitter(s) carry the evidence breakout, expected 4\n` +
        `    (diagram + asciicast + video in render/figures.ex, generic figure in render/compose.ex).`,
    );

  // diff + filetree are INLINE-produced breakouts. Their emitters write the whole
  // box as an inline `style=`, which beats any class rule, so the pair has to be
  // on the EMITTER — and the CSS rule that mirrors it must agree. Censusing only
  // the stylesheet would have called the half-breakout green: measured, the diff
  // took the band's width from CSS, left the pull to an inline `margin: 4px 0`,
  // and overflowed the page by 110px.
  const componentsEx = consumerSources.find(({ path }) => path.endsWith("components.ex")).text;
  for (const cls of ["bp-diff", "bp-filetree"]) {
    const line = componentsEx.split("\n").find((l) => l.includes(`<div class="${cls} `));
    if (!line) {
      kFail(`  Part K FAIL: no <div class="${cls} …"> emitter found in render/components.ex`);
      continue;
    }
    for (const half of ["width", "pull"]) {
      if (!line.includes(`var(--bp-evidence-${half}`))
        kFail(
          `  Part K FAIL: the ${cls} emitter's inline style does not read --bp-evidence-${half}.\n` +
            `    An inline style beats the class rule, so declaring one half in CSS and leaving the\n` +
            `    other to the emitter grows the component off-axis instead of about the column.`,
        );
    }
  }

  if (FAULT.has("K")) kFail("  Part K FAIL: injected fault (--selftest)");
  if (!kFailed)
    console.log(
      `  ok   ${EVIDENCE_KEYS.length} evidence tokens emitted with their authored units, bridged onto --bp-evidence-*, ` +
        `all four geometry terms folded into one composed width, and ${BREAKOUT_RULES.length} breakout rules + 4 article figures reading the width/pull pair`,
    );
}
