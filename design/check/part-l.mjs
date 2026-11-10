// design/check/part-l.mjs — Part L of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { SECTION_KEYS, SECTION_UNITS, tokens } from "../emit.mjs";
import { bumpFailed, failed, FAULT } from "./state.mjs";
import { RAW_SURFACE_PATH, readDesignSource } from "./part-e.mjs";

// ── Part L: the SECTION BOUNDARY reaches a real consumer, on BOTH surfaces ───
// space.section emits `--tok-section-{beat,rule,gap}`, each surface bridges them
// onto `--bp-section-*`, and ONE declaration per surface spends all three on the
// section head. Part J's shape (emitted → bridged → read) is necessary here and
// not sufficient, because this device is a TWIN: the reader's
// `.bp-paper-surface > #paper-body > h2` and the editor's
// `.bp-paper-editor-body > h2` are two hand-maintained declarations of one law,
// and the way this fails is not a deleted token — it is one surface keeping the
// air while the other keeps the rule, which every per-surface census passes.
//
// So Part L checks the three tokens on BOTH surfaces AND that each surface's
// section-head declaration spends all three properties, AND that the reader
// carries the keyed-stream leg — the one that actually ships (bulldocs_live.ex
// wraps every top-level block in a class-less div; a reader rule written only
// against the flat shape is dead on the live page and green in every gate that
// does not look at the selector).
console.log("\ndesign/check.mjs — Part L: section-boundary consumer census");
{
  let lFailed = 0;
  const lFail = (m) => { console.error(m); lFailed++; bumpFailed(); };

  const SECTION_SURFACES = [
    { path: "api/assets/paper-surface/paper-surface.css", head: ".bp-paper-surface > #paper-body > h2" },
    { path: "api/assets/paper-editor/src/styles.css", head: ".bp-paper-editor-body > h2" },
  ];
  // The three properties that make the device. Air without a rule is a long
  // pause; a rule without the gap is underlined text. A surface that declares
  // two of three has a HALF device, which is the exact drift a twin invites.
  const HEAD_PROPS = [
    ["margin-top", "beat"],
    ["border-top", "rule"],
    ["padding-top", "gap"],
  ];

  for (const { path, head } of SECTION_SURFACES) {
    const css = readDesignSource(path);

    for (const key of SECTION_KEYS) {
      const value =
        key === "beat"
          ? `calc(var(--tok-air-beat) * ${String(tokens.space.section.beat).replace(".", "\\.")})`
          : `${tokens.space.section[key]}${SECTION_UNITS[key]}`;
      // 1. emitted — `beat` as a ratio of the air beat, never a resolved pixel,
      //    so section rhythm cannot drift away from evidence rhythm.
      if (!new RegExp(`--tok-section-${key}: ${value.replace(/[()*]/g, "\\$&")};`).test(css))
        lFail(`  Part L FAIL: --tok-section-${key} is not emitted as ${value} in ${path}`);
      // 2. bridged onto the --bp-* name the rules read.
      if (!css.includes(`--bp-section-${key}: var(--tok-section-${key});`))
        lFail(`  Part L FAIL: --bp-section-${key} has no bridge onto --tok-section-${key} in ${path}`);
      // 3. actually READ (the bridge declaration itself excluded, so a bridge
      //    feeding only itself does not count as a consumer).
      const read = css
        .split("\n")
        .some((l) => l.includes(`var(--bp-section-${key}`) && !l.includes(`--bp-section-${key}: var(`));
      if (!read)
        lFail(
          `  Part L FAIL: --bp-section-${key} is emitted and bridged in ${path} but NOTHING consumes it.\n` +
            `    A token with no reader is not a single source — it is a dead one. Either spend it on\n` +
            `    the ${head} rule, or drop it from space.section + SECTION_KEYS in design/emit.mjs.`,
        );
    }

    // 4. the section-head declaration exists on this surface and is WHOLE.
    const at = css.indexOf(head);
    if (at === -1) {
      lFail(`  Part L FAIL: ${path} has no ${head} rule — this surface has no section head at all`);
      continue;
    }
    const block = css.slice(at, css.indexOf("}", at) + 1);
    for (const [prop, key] of HEAD_PROPS) {
      if (!new RegExp(`${prop}:[^;]*var\\(--bp-section-${key}\\)`).test(block))
        lFail(
          `  Part L FAIL: the ${head} rule in ${path} does not set ${prop} from --bp-section-${key}.\n` +
            `    The section boundary is air + rule + gap TOGETHER; two of the three is a half device,\n` +
            `    and a half device on ONE surface is View<->Edit drift that every other gate passes.`,
        );
    }
  }

  // 5. the reader's keyed-stream leg. bulldocs_live.ex streams each top-level
  //    block as a class-less `<div id data-block-id>`, so `#paper-body > h2`
  //    alone matches only the legacy whole-body path and the render rig — the
  //    live reader would show no section heads and nothing here would notice.
  const surfaceCss = readDesignSource(RAW_SURFACE_PATH);
  if (!surfaceCss.includes(".bp-paper-surface > #paper-body > div:not([class]) > h2"))
    lFail(
      `  Part L FAIL: paper-surface.css has no keyed-stream leg for the section head.\n` +
        `    The block-backed reader wraps every top-level block in <div id data-block-id> — without\n` +
        `    \`> #paper-body > div:not([class]) > h2\` the device is dead on the page that ships.`,
    );

  if (FAULT.has("L")) lFail("  Part L FAIL: injected fault (--selftest)");
  if (!lFailed)
    console.log(
      `  ok   ${SECTION_KEYS.length} section tokens emitted, bridged and consumed on both the reader and the editor surface, ` +
        `each head spending all three on one declaration, and the reader carrying its keyed-stream leg`,
    );
}
