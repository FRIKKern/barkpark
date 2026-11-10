// design/check/part-j.mjs — Part J of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { AIR_STEPS, tokens } from "../emit.mjs";
import { fail, failed, FAULT } from "./state.mjs";
import { RAW_SURFACE_PATH, readDesignSource } from "./part-e.mjs";

// ── Part J: the AIR scale reaches a real consumer ────────────────────────────
// space.air emits `--tok-air-<step>` onto the paper surface, paper-surface.css
// bridges each onto `--bp-air-<step>`, and the six consumers live in THREE files —
// two of them Elixir renderers that emit the beat as an inline `var(--bp-air-*)`
// on markup this CSS gate would otherwise never see.
//
// That spread is exactly the shape pe-w1-reader-editorial-typography found and
// fixed: `--bp-*-tracking` was declared in tokens.json and consumed NOWHERE, and
// nothing failed, because "single-source" and "single-source and unread" look
// identical until you measure the page. So this part refuses the silence in both
// directions — emitted-but-unbridged, and bridged-but-unconsumed. A step whose
// consumer is deleted (or renamed) reds here instead of quietly flattening the
// reader's evidence spacing back to zero.
console.log("\ndesign/check.mjs — Part J: air-scale consumer census");
{
  const failedBeforeJ = failed;
  const surfaceCss = readDesignSource(RAW_SURFACE_PATH);
  // Consumers may live in the stylesheet OR inline on renderer output. Both are
  // legitimate: a figure's beat has to survive a stylesheet-less sink, so it
  // rides `var(--bp-air-figure, <fallback>)` in the emitting Elixir source.
  const consumerSources = [
    "api/assets/paper-surface/paper-surface.css",
    "api/lib/barkpark/portable_doc/render/figures.ex",
    "api/lib/barkpark/portable_doc/render/compose.ex",
  ].map((p) => ({ path: p, text: readDesignSource(p) }));

  for (const step of AIR_STEPS) {
    const ratio = tokens.space.air[step];
    // 1. emitted, as a ratio of the beat — never a resolved literal.
    const emitted = new RegExp(`--tok-air-${step}: calc\\(var\\(--tok-air-beat\\) \\* ${String(ratio).replace(".", "\\.")}\\);`);
    if (!emitted.test(surfaceCss))
      fail(`  Part J FAIL: --tok-air-${step} is not emitted as calc(var(--tok-air-beat) * ${ratio}) in paper-surface.css`);

    // 2. bridged onto the --bp-* name every rule reads.
    if (!surfaceCss.includes(`--bp-air-${step}: var(--tok-air-${step});`))
      fail(`  Part J FAIL: --bp-air-${step} has no bridge onto --tok-air-${step} in paper-surface.css`);

    // 3. actually READ by something. The bridge declaration itself is excluded,
    //    so a bridge that only feeds itself does not count as a consumer.
    const hits = consumerSources.flatMap(({ path, text }) =>
      text
        .split("\n")
        .filter((l) => l.includes(`var(--bp-air-${step}`) && !l.includes(`--bp-air-${step}: var(`))
        .map((l) => `${path}: ${l.trim().slice(0, 80)}`),
    );
    if (hits.length === 0)
      fail(
        `  Part J FAIL: --bp-air-${step} is emitted and bridged but NOTHING consumes it.\n` +
          `    A token with no reader is not a single source — it is a dead one. Either give it\n` +
          `    a rule (paper-surface.css) or an inline var() on the emitting renderer, or drop\n` +
          `    the step from space.air + AIR_STEPS.`,
      );
  }
  if (FAULT.has("J")) fail("  Part J FAIL: injected fault (--selftest)");
  if (failed === failedBeforeJ)
    console.log(`  ok   ${AIR_STEPS.length} air steps emitted as beat ratios, bridged onto --bp-air-*, and each read by a live consumer`);
}
