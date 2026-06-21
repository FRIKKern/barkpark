#!/usr/bin/env node
// acceptance-p5.mjs — the repeatable acceptance test for P5, the never-worse
// remake gate. The capstone: it uses P1 (truth), P2 (collapse proposal), P3
// (routing anchors) to gate a real doc restructure.
//
// Three MUST-PASS cases, mirroring P2/P3's acceptance output style:
//
//   POSITIVE     — build the REAL Golden-Rules↔Past-Mistakes collapse candidate
//                  (keep GR canonical; replace PM's overlapping facts with a
//                  typed pointer to GR; KEEP every non-overlapping PM fact, using
//                  P2's proposal so the overlap set is exactly the shared
//                  anchors). Run it through gateRemake. Assert: verdict is NOT
//                  reject (claims + links + anchors all survive — 100% of GR∪PM
//                  verifiable claims present in the after-text) AND verdict is
//                  HUMAN (it touches the verbatim-exempt sections). No file is
//                  written.
//
//   NEGATIVE-1   — same candidate but DROP one fact (the `systemctl restart`
//                  claim) from both GR and PM. Assert gateRemake → reject with
//                  that factKey in lostClaims.
//
//   NEGATIVE-2   — a candidate that drops an outbound link present in the
//                  original. Assert gateRemake → reject with it in lostLinks.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gateRemake } from "./remake.mjs";
import { runWaterfall } from "./waterfall.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const TARGET = "CLAUDE.md";
const PM_HEADING = "## Past Mistakes (NEVER REPEAT)";

// ── helpers ───────────────────────────────────────────────────────────────────
const bar = "═".repeat(74);
function out(s) { process.stdout.write(s); }

// Slice the Past-Mistakes section body (between its ## heading and the next ##).
function pmRange(text) {
  const lines = text.split("\n");
  let start = -1, end = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() === PM_HEADING) { start = i; break; }
  }
  if (start === -1) throw new Error("Past Mistakes heading not found");
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s/.test(lines[i])) { end = i; break; }
  }
  return { lines, start, end };
}

// Build the REAL collapse candidate via P2's proposal. We keep Golden Rules
// fully intact (canonical) and rewrite the Past-Mistakes section: every PM list
// item whose ONLY verifiable anchors are in the shared (overlapping) set is
// replaced by the typed pointer; PM items carrying a NON-overlapping fact or an
// outbound link are kept verbatim. This is the lose-no-fact collapse P2 proposes.
function buildCollapseCandidate(beforeText) {
  // P2 gives us the exact shared overlap set + the typed pointer markdown.
  const res = runWaterfall([TARGET]);
  const cluster = res.clusters.find((c) => {
    const pair = new Set([c.a.slug, c.b.slug]);
    return pair.has("golden-rules") && pair.has("past-mistakes-never-repeat");
  });
  if (!cluster) throw new Error("GR↔PM cluster not found by P2");
  const pointerMd = cluster.proposal.pointer.typedMarkdown;
  const sharedRaw = cluster.proposal.sharedRaw; // surfaces of the shared facts

  const { lines, start, end } = pmRange(beforeText);
  // Keep the heading + the blank line after it; replace the numbered list with a
  // pointer line that carries the shared fact surfaces in backticks (so the
  // overlapping facts also survive textually in PM), THEN re-append every PM
  // item that carries a UNIQUE fact or an outbound link so no PM-only fact is
  // lost. We detect uniqueness conservatively: any item line that contains a
  // doc-path link or a backtick token NOT in sharedRaw is kept.
  const sharedSet = new Set(sharedRaw);
  const body = lines.slice(start + 1, end);
  const kept = [];
  for (const line of body) {
    if (!/^\d+\.\s/.test(line)) continue; // only list items
    const hasLink = /docs\/|api\/|\]\(/.test(line);
    // unique backtick token not in the shared surfaces?
    let uniqueAnchor = false;
    for (const m of line.matchAll(/`([^`]+)`/g)) {
      const raw = m[1].trim();
      if (!sharedSet.has(raw) && !sharedSet.has(raw.replace(/\/+$/, ""))) {
        uniqueAnchor = true;
      }
    }
    if (hasLink || uniqueAnchor) kept.push(line);
  }

  const newPm = [
    lines[start],            // the ## heading
    "",
    pointerMd,               // the typed pointer — carries shared anchors in `…`
    "",
    "Non-overlapping mistakes (kept in full):",
    ...kept,
  ];
  const after = [
    ...lines.slice(0, start),
    ...newPm,
    "",
    ...lines.slice(end),
  ].join("\n");
  return { after, pointerMd, sharedRaw };
}

function main() {
  const beforePath = TARGET;
  const beforeText = readFileSync(join(ROOT, TARGET), "utf8");
  const absTarget = join(ROOT, TARGET);
  const mtimeBefore = statSync(absTarget).mtimeMs;

  out(`\n${bar}\nDOC-TRUTH REMAKE GATE (P5) — ACCEPTANCE\n${bar}\n`);
  out(`target: ${TARGET}  ·  capstone gate over P1 (truth) + P2 (collapse) + P3 (routing)\n`);

  // ── POSITIVE ────────────────────────────────────────────────────────────────
  out(`\nPOSITIVE — real GR↔PM collapse (keep GR canonical, point PM at it)\n`);
  const { after: afterPos } = buildCollapseCandidate(beforeText);
  const meta = { at: "POSITIVE", requiresOwnerSignoff: true };
  const rPos = gateRemake({ beforePath, beforeText, afterText: afterPos, meta });

  const bc = rPos.classification.beforeFactCount;
  const ac = rPos.classification.afterFactCount;
  out(`  verifiable facts — before: ${bc} · after: ${ac} · lost: ${rPos.lostClaims.length}\n`);
  out(`  outbound links   — before: ${rPos.classification.beforeLinkCount} · after: ${rPos.classification.afterLinkCount} · lost: ${rPos.lostLinks.length}\n`);
  out(`  routing anchors checked: ${rPos.classification.routingAnchorsChecked.length} · dropped: ${rPos.lostAnchors.length}\n`);
  out(`  verdict: ${rPos.verdict.toUpperCase()}  (${rPos.reason})\n`);
  const positivePass =
    rPos.verdict !== "reject" &&
    rPos.verdict === "human" &&
    rPos.lostClaims.length === 0 &&
    rPos.lostLinks.length === 0 &&
    rPos.lostAnchors.length === 0;
  out(`  POSITIVE: ${positivePass ? "PASS" : "FAIL"} (not-reject AND human, lost:0 across claims/links/anchors)\n`);

  // ── NEGATIVE-1 — drop a fact ────────────────────────────────────────────────
  out(`\nNEGATIVE-1 — drop the \`systemctl restart\` fact from BOTH GR and PM\n`);
  // Remove every line that carries the systemctl-restart fact from the after.
  const afterNeg1 = afterPos
    .split("\n")
    .filter((l) => !/systemctl\s+restart/i.test(l))
    .join("\n");
  // also drop it from the BEFORE→AFTER honestly: the before still has it, the
  // after no longer does → a lost fact. (We gate before=real, after=neg1.)
  const rNeg1 = gateRemake({ beforePath, beforeText, afterText: afterNeg1, meta: { at: "NEGATIVE-1" } });
  const droppedFk = "cmd:systemctl restart";
  const neg1Pass = rNeg1.verdict === "reject" && rNeg1.lostClaims.includes(droppedFk);
  out(`  verdict: ${rNeg1.verdict.toUpperCase()}  (${rNeg1.reason})\n`);
  out(`  lostClaims includes "${droppedFk}": ${rNeg1.lostClaims.includes(droppedFk)}\n`);
  out(`  lostClaims: ${rNeg1.lostClaims.join(", ") || "(none)"}\n`);
  out(`  NEGATIVE-1: ${neg1Pass ? "PASS" : "FAIL"} (reject with the dropped factKey)\n`);

  // ── NEGATIVE-2 — drop an outbound link ──────────────────────────────────────
  out(`\nNEGATIVE-2 — drop an outbound doc-path link present in the original\n`);
  // The PM rule-11 line carries `docs/ops/studio-nav-bug-2026-04-19.md`. Build a
  // candidate that keeps every fact but removes that link surface.
  const droppedLink = "docs/ops/studio-nav-bug-2026-04-19.md";
  const afterNeg2 = afterPos.replace(new RegExp("`" + droppedLink + "`", "g"), "the ops runbook")
    .replace(droppedLink, "the ops runbook");
  const rNeg2 = gateRemake({ beforePath, beforeText, afterText: afterNeg2, meta: { at: "NEGATIVE-2" } });
  const neg2Pass = rNeg2.verdict === "reject" && rNeg2.lostLinks.includes(droppedLink);
  out(`  verdict: ${rNeg2.verdict.toUpperCase()}  (${rNeg2.reason})\n`);
  out(`  lostLinks includes "${droppedLink}": ${rNeg2.lostLinks.includes(droppedLink)}\n`);
  out(`  lostLinks: ${rNeg2.lostLinks.join(", ") || "(none)"}\n`);
  out(`  NEGATIVE-2: ${neg2Pass ? "PASS" : "FAIL"} (reject with the dropped link)\n`);

  // ── no-write assertion ──────────────────────────────────────────────────────
  const mtimeAfter = statSync(absTarget).mtimeMs;
  const noWrite = mtimeBefore === mtimeAfter;
  out(`\nNO-WRITE — the gate never touched ${TARGET} on disk: ${noWrite ? "confirmed" : "VIOLATED"}\n`);

  // ── summary ─────────────────────────────────────────────────────────────────
  const allPass = positivePass && neg1Pass && neg2Pass && noWrite;
  out(`\n${bar}\nSUMMARY\n${bar}\n`);
  out(`  POSITIVE:    ${positivePass ? "PASS ✓" : "FAIL ✗"}  (verdict human, lost:0 — facts ${bc}→${ac})\n`);
  out(`  NEGATIVE-1:  ${neg1Pass ? "PASS ✓" : "FAIL ✗"}  (reject, lost fact ${droppedFk})\n`);
  out(`  NEGATIVE-2:  ${neg2Pass ? "PASS ✓" : "FAIL ✗"}  (reject, lost link ${droppedLink})\n`);
  out(`  NO-WRITE:    ${noWrite ? "PASS ✓" : "FAIL ✗"}  (gate proposes/evaluates, never applies)\n`);
  out(`${bar}\n`);

  process.exit(allPass ? 0 : 1);
}

main();
