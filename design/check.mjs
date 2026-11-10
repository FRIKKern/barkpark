#!/usr/bin/env node
// design/check.mjs — the W1.2 drift gate. Re-emits every per-surface artifact
// into memory and byte-compares it against what is committed; any divergence is a
// non-zero exit with a per-artifact diff summary. PLUS §6: a cross-surface parity
// assertion that the emitted Go lifecycle literals, the emitted CSS glyph tones,
// and design/tokens.json agree on glyph, colour and the braille frame-set — so a
// GUI (CSS) vs TUI (Go) lifecycle divergence trips the gate.
// Dependency-free (Node built-ins only). Pairs with design/validate.mjs (shape)
// and design/emit.mjs (the single source of the emitted bytes).
import {
  evaluateAll, tokens, AIR_ROW_SPLIT, ruleGlyph, LIFE_ORDER, TYPE_STEPS, typeLadderFrom, LADDER_REFUSE, READING_STEPS, AIR_STEPS, EVIDENCE_KEYS, EVIDENCE_UNITS, SECTION_KEYS, SECTION_UNITS, RULE_KEYS, RULE_UNITS, MOTION_STEPS, MOTION_SURFACES, glyphOf, ARTIFACTS, repoRoot,
  INST_ORDER, PROVIDERS, INST_ROLE_CSS, instRoleChannels, hslToHex,
  readManifest, attribute, lostLines, regionDigest, MANIFEST_PATH,
  auditActions, AUDIT_ACTIONS_PATH,
} from "./emit.mjs";
import { evaluateMirror } from "./paper-editor-mirror.mjs";
import { evaluateReadingMeasure, TOKENS_PATH } from "./reading-measure.mjs";
import { derive, contrast, SLOTS, PASSTHROUGH_FAMILIES } from "./derive.mjs";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readAuthoredCss } from "../api/assets/paper-editor/src/__css_source_graph.mjs";
import { assembledText } from "../api/assets/paper-editor/scripts/source-assets.mjs";
import { failed } from "./check/state.mjs";

// ── --selftest: this tripwire's negative half ────────────────────────────────
// This gate ran for its whole life with nothing exercising it, and produced two
// ok-summary defect rows in a single day — one part printing `ok` beside its own
// FAIL lines, then Part B swallowing a TRUE `ok` — each proven only by a
// throwaway harness the builder wrote and threw away. --selftest is the standing
// replacement, in the idiom scripts/check-vendor-freshness.mjs and
// scripts/preview-parity-check.sh already use: it re-invokes THIS file as a
// subprocess with one part's failure path forced, and asserts the ok-summary
// gating in BOTH directions — a part that failed must WITHHOLD its ok, and a part
// that passed must PRINT its ok even when an earlier part failed. The body lives
// in design/check-selftest.mjs so the switch costs this file a dispatch rather
// than an indentation level wrapped around every Part.
if (process.argv.slice(2).includes("--selftest")) {
  const { selftest } = await import("./check-selftest.mjs");
  const ok = await selftest();
  // Drain before exiting. Node does not flush a pending stdout write on
  // process.exit(), so a piped reader can lose the verdict line while the exit
  // code still arrives — write("", cb) calls back only once everything queued
  // ahead of it has gone out. process.exitCode on its own will not do here: every
  // Part below is a top-level statement and would run on regardless.
  await new Promise((r) => process.stdout.write("", r));
  process.exit(ok ? 0 : 1);
}

// ── the Parts ────────────────────────────────────────────────────────────────
// Each Part lives in its own module under design/check/ and runs when imported.
// They are imported one at a time, in this order, AFTER the --selftest switch
// above: a static import would run every Part before that switch is read. The
// fault set and the failure count they share live in design/check/state.mjs.
// The imports at the top of this file stay as they were, so the modules the
// gate reads are loaded in the same order as before the split.
await import("./check/part-0.mjs");
const partA = await import("./check/part-a.mjs");
await import("./check/part-b.mjs");
await import("./check/part-c.mjs");
await import("./check/part-c2.mjs");
await import("./check/part-d.mjs");
await import("./check/part-e.mjs");
await import("./check/part-f.mjs");
await import("./check/part-g.mjs");
await import("./check/part-h.mjs");
await import("./check/part-h2.mjs");
await import("./check/part-i.mjs");
await import("./check/part-j.mjs");
await import("./check/part-k.mjs");
await import("./check/part-l.mjs");
await import("./check/part-m.mjs");
await import("./check/part-n.mjs");
await import("./check/part-o.mjs");
await import("./check/part-p.mjs");
await import("./check/part-q.mjs");
await import("./check/part-r.mjs");
const { unattributedSeen } = partA;

// ── verdict ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(unattributedSeen
    ? "\ndesign/check.mjs: FAILED — a generated region holds content design/emit.mjs never wrote (or a surface has drifted from design/tokens.json)."
    // Parts B–I are not drift checks (parity, contrast, fence predicates), so
    // naming drift here would send the reader to the wrong file. Say what the
    // gate actually knows: something above failed, and it is labelled.
    : "\ndesign/check.mjs: FAILED — see the labelled failure(s) above.");
  process.exit(1);
}
console.log(`\ndesign/check.mjs: PASS — ${ARTIFACTS.length} surfaces in lockstep + §6 lifecycle parity holds, every generated region attributed to design/emit.mjs.`);
