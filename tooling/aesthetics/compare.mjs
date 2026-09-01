#!/usr/bin/env node
// compare — the REGRESSION-DIFF half of the aesthetics CI guard. Pure Node,
// dependency-free. Takes two aesthetics-report.json paths (BASE = base-branch tip,
// HEAD = PR tip), reports the STRUCTURAL findings the PR newly INTRODUCES, plus
// a markdown summary for $GITHUB_STEP_SUMMARY. The regression logic lives here
// (not buried in YAML) so it is unit-testable in plain Node.
//
//   node tooling/aesthetics/compare.mjs <base-report.json> <head-report.json>
//       → prints the markdown summary to stdout; flags NEW structural findings.
//   node tooling/aesthetics/compare.mjs --self-test
//       → runs the embedded sanity checks (used by compare.test.mjs too).
//
// WHY STRUCTURAL-ONLY:
//   bp is ABSENT in CI, so the TASK signal (dead-task: junk + unscoped-open) is
//   computed off the snapshot/empty fallback and is NOT reliable run-to-run. We
//   therefore EXCLUDE dead-task from the regression check entirely. The structural
//   findings — root source clutter, dead docs, removable tracked build-output,
//   directory fan-out, yagni-orphans — are DETERMINISTIC from `git ls-files` + fs,
//   so they diff cleanly between base and head.
//
// WHY ADVISORY:
//   We only report. A NEW structural finding (or a Bloat-score drop) surfaces as a
//   ⚠️ in the summary; pre-existing mess is NEVER flagged (a PR is not penalized for
//   debt it did not create). The guard exits 0 always — the workflow uses the
//   `flagged` boolean only to emit a ::warning:: line, never to fail the merge.

import { readFileSync } from "node:fs";

// ── STRUCTURAL finding kinds (deterministic; bp-independent) ─────────────────
// dead-task is DELIBERATELY excluded — it depends on bp/snapshot, unreliable in CI.
const STRUCTURAL_KINDS = new Set(["root-clutter", "dead-doc", "dir-fanout", "yagni-orphan"]);

// A tracked-artifact finding is structural ONLY when it is the build-output
// roll-up (the genuinely-removable, neither-served-nor-published class). That
// finding carries a `sample` array; the per-file deliberate (served/published)
// and typedef rows do not — those are intentional commits we never flag.
function isStructural(f) {
  if (STRUCTURAL_KINDS.has(f.kind)) return true;
  if (f.kind === "tracked-artifact" && Array.isArray(f.sample)) return true;
  return false;
}

// Stable identity for a finding — kind + path, plus its sample set so a roll-up
// that GROWS (a new build file added to an existing tracked-artifact roll-up) is
// recognized as changed. We compare on kind+path for the headline identity and
// surface added sample paths separately.
function findingKey(f) {
  return `${f.kind}::${f.path}`;
}

// Collect the structural findings from a report, both bloat + aesthetics dims.
function structuralFindings(report) {
  const all = [
    ...((report.bloat && report.bloat.findings) || []),
    ...((report.aesthetics && report.aesthetics.findings) || []),
  ];
  return all.filter(isStructural);
}

// The core diff: which structural findings exist in HEAD but not in BASE, plus
// any newly-added sample paths under a structural roll-up that already existed.
// Returns { newFindings[], newSamples[], bloatDropped, scores }.
export function compareReports(base, head) {
  const baseFindings = structuralFindings(base);
  const headFindings = structuralFindings(head);
  const baseByKey = new Map(baseFindings.map((f) => [findingKey(f), f]));

  const newFindings = [];
  const newSamples = [];
  for (const hf of headFindings) {
    const bf = baseByKey.get(findingKey(hf));
    if (!bf) {
      newFindings.push(hf);           // a whole structural finding the PR introduced
      continue;
    }
    // same finding key exists in base — flag only sample paths NEW to head
    const baseSamples = new Set(Array.isArray(bf.sample) ? bf.sample : []);
    const headSamples = Array.isArray(hf.sample) ? hf.sample : [];
    for (const s of headSamples) if (!baseSamples.has(s)) newSamples.push({ key: findingKey(hf), path: s });
  }

  const baseBloat = (base.bloat && base.bloat.score) ?? null;
  const headBloat = (head.bloat && head.bloat.score) ?? null;
  const bloatDropped = baseBloat != null && headBloat != null && headBloat < baseBloat;

  const scores = {
    base: { bloat: baseBloat, aesthetics: (base.aesthetics && base.aesthetics.score) ?? null },
    head: { bloat: headBloat, aesthetics: (head.aesthetics && head.aesthetics.score) ?? null },
  };

  const flagged = newFindings.length > 0 || newSamples.length > 0 || bloatDropped;
  return { newFindings, newSamples, bloatDropped, scores, flagged };
}

// ── markdown rendering for $GITHUB_STEP_SUMMARY ──────────────────────────────
const KIND_LABEL = {
  "root-clutter": "root source clutter",
  "tracked-artifact": "tracked build-output",
  "dir-fanout": "directory fan-out",
  "dead-doc": "dead doc",
  "yagni-orphan": "yagni-orphan",
};
const esc = (s) => String(s).replace(/\|/g, "\\|").replace(/\n/g, " ");

export function renderMarkdown(diff, head) {
  const { scores, newFindings, newSamples, bloatDropped, flagged } = diff;
  const L = [];
  L.push("## Filebase aesthetics — Cody YAGNI critic (advisory)");
  L.push("");
  L.push("Higher = cleaner. This guard is **advisory** — it never blocks the merge.");
  L.push("It flags only the STRUCTURAL findings a PR **newly introduces** vs the base branch");
  L.push("(root source clutter · dead docs · removable tracked build-output · dir fan-out · yagni-orphans).");
  L.push("The task signal (junk / unscoped tasks) is **excluded** — bp is absent in CI, so it is not deterministic.");
  L.push("");

  // scores table
  L.push("| dimension | base | PR head |");
  L.push("|---|---|---|");
  L.push(`| Bloat | ${scores.base.bloat ?? "—"} | ${scores.head.bloat ?? "—"} |`);
  L.push(`| Aesthetics | ${scores.base.aesthetics ?? "—"} | ${scores.head.aesthetics ?? "—"} |`);
  L.push("");

  // verdict
  if (!flagged) {
    L.push("✅ **No new structural mess.** This PR introduces no new root clutter, dead docs, or removable build-output.");
  } else {
    L.push("⚠️ **This PR introduces new filebase mess (advisory — not blocking):**");
    L.push("");
    if (bloatDropped) {
      L.push(`- ⚠️ Bloat dropped **${scores.base.bloat} → ${scores.head.bloat}** vs the base branch.`);
    }
    for (const f of newFindings) {
      L.push(`- ⚠️ NEW ${KIND_LABEL[f.kind] || f.kind}: \`${esc(f.path)}\` — ${esc(f.why)}`);
    }
    for (const s of newSamples) {
      L.push(`- ⚠️ NEW file under \`${esc(s.key)}\`: \`${esc(s.path)}\``);
    }
  }
  L.push("");

  // full HEAD findings (so every PR shows the filebase grade), top by severity
  const allHead = [
    ...((head.bloat && head.bloat.findings) || []),
    ...((head.aesthetics && head.aesthetics.findings) || []),
  ].slice().sort((a, b) => (b.severity || 0) - (a.severity || 0));
  if (allHead.length) {
    L.push("<details><summary>All findings on this PR head (top 10 by severity)</summary>");
    L.push("");
    L.push("| kind | path | severity | why |");
    L.push("|---|---|---|---|");
    for (const f of allHead.slice(0, 10)) {
      L.push(`| ${esc(f.kind)} | \`${esc(f.path)}\` | ${f.severity ?? "—"} | ${esc(f.why)} |`);
    }
    L.push("");
    L.push("</details>");
  }
  L.push("");
  return L.join("\n");
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function readReport(p) {
  return JSON.parse(readFileSync(p, "utf8"));
}

function selfTest() {
  const baseReport = {
    bloat: { score: 96, findings: [{ kind: "tracked-artifact", path: "api/x.d.ts", severity: 0.2, why: "typedef" }] },
    aesthetics: { score: 99, findings: [{ kind: "dead-task", path: "bp-task:(unscoped ×3)", severity: 0.32, why: "unscoped" }] },
  };
  // head adds ONE new structural finding: root-clutter
  const headReport = {
    bloat: { score: 90, findings: [
      { kind: "root-clutter", path: "(repo root)", severity: 0.5, why: "5 source files sit in the repo ROOT" },
      { kind: "tracked-artifact", path: "api/x.d.ts", severity: 0.2, why: "typedef" },
    ] },
    aesthetics: { score: 99, findings: [{ kind: "dead-task", path: "bp-task:(unscoped ×4)", severity: 0.32, why: "unscoped" }] },
  };
  // Aborting at the first failed arm IS the behaviour here.
  const fail = (m) => { console.error("SELF-TEST FAIL: " + m); process.exit(1); }; // pipe-exit-ok: selftest abort, one stderr line, never the piped payload

  // 1. head with a new root-clutter → flags exactly that one structural finding
  const d1 = compareReports(baseReport, headReport);
  if (!d1.flagged) fail("expected flagged=true for new root-clutter");
  if (d1.newFindings.length !== 1) fail(`expected exactly 1 new finding, got ${d1.newFindings.length}`);
  if (d1.newFindings[0].kind !== "root-clutter") fail("expected the new finding to be root-clutter");
  if (!d1.bloatDropped) fail("expected bloatDropped=true (96→90)");

  // 2. dead-task drift is NOT flagged (task signal excluded) — base had ×3, head ×4
  if (d1.newFindings.some((f) => f.kind === "dead-task")) fail("dead-task must never be a structural finding");

  // 3. identical reports → NO flag (clean PR = no alarm)
  const d2 = compareReports(baseReport, baseReport);
  if (d2.flagged) fail("identical reports must not flag");
  if (d2.newFindings.length !== 0) fail("identical reports must yield 0 new findings");

  console.log("compare.mjs self-test: OK");
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const args = process.argv.slice(2);
  if (args.includes("--self-test")) {
    selfTest();
  } else if (args.length === 2) {
    const diff = compareReports(readReport(args[0]), readReport(args[1]));
    const head = readReport(args[1]);
    process.stdout.write(renderMarkdown(diff, head));
    // ADVISORY: always exit 0. The workflow reads stdout + the `flagged` line
    // below to emit a ::warning::; it never fails the merge on a non-zero exit.
    if (diff.flagged) process.stdout.write("\nAESTHETICS_GUARD_FLAGGED=1\n");
    // exitCode, never exit(): this line follows a full renderMarkdown()
    // write into a `| tee` pipe, and process.exit() does not wait for a
    // pending pipe write to drain. Nothing runs after this block.
    process.exitCode = 0;
  } else {
    console.error("usage: node tooling/aesthetics/compare.mjs <base-report.json> <head-report.json>");
    console.error("   or: node tooling/aesthetics/compare.mjs --self-test");
    process.exitCode = 2;
  }
}
