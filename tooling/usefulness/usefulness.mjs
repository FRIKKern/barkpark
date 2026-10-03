#!/usr/bin/env node
// REACH axis (formerly "usefulness"). v2 Phase 0: reach is a PURE PROGRAMMATIC
// value — the normalized (0-100) transitive-dependent count. No agent pass is
// needed to produce the number; it is computed from the dependency graph.
//
// The agent "why it's useful" prose is KEPT as a `why` DESCRIPTION (graded
// "reusability") — it explains why a file is reusable; it is NOT a score.
//
//   usefulness.mjs batches  → per-file agent tasks (reach prior seeded)   [free]
//   usefulness.mjs merge     → usefulness-report.json (reach + why)        [free]
//
// usefulness-report.json keeps its filename for back-compat; each entry now
// carries: reach (raw transitive count), reachScore (0-100 surfaced value),
// why (description text), plus legacy `usefulness`/`why_useful` mirrors.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { platformReach, resolveProfile, scanElixir, readConfigs } from "../lib/platform-reach.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const cmd = process.argv[2] || "batches";
const BATCH = 10;

const nodes = JSON.parse(readFileSync(join(ROOT, "tooling/barkpark-sync/nodes.json"), "utf8")).nodes;
const risk = (existsSync(join(ROOT, "tooling/risk/risk-report.json")) ? JSON.parse(readFileSync(join(ROOT, "tooling/risk/risk-report.json"), "utf8")).files : {});

// transitive reach = how many files (transitively) depend on this one, FOR
// THE DECLARED PLATFORM PROFILE (task-403fe20b2a7f2743). An edge from an
// :os.type() backend selector to a backend the profile never selects carries
// no reach. The edge stays in the graph, and the report names the discount.
// Profile: --platform <p> > CODY_PLATFORM > "linux" (the deployed fleet).
const platformArg = (() => { const i = process.argv.indexOf("--platform"); return i > 0 ? process.argv[i + 1] : null; })();
const PROFILE = resolveProfile(platformArg);
const PR = platformReach(nodes, { ...scanElixir(ROOT), configSrcs: readConfigs(ROOT), profile: PROFILE.profile });
const byId = Object.fromEntries(nodes.map(n => [n.id, n]));
function reach(id) { return PR.files[byId[id].path]?.reach ?? 0; }

function prior(n) {
  const r = reach(n.id), f = n.fields, rk = risk[n.path] || {};
  let v = Math.min(45, Math.log2(1 + r) * 12);            // reach — the core usefulness signal
  if (f.fanIn >= 3) v += 8;                                // directly depended-upon
  if (f.entrypoint) v += 12;                               // an entry surface
  if (f.seam) v += 10;                                     // public wire contract = broadly leveraged
  if ((rk.testScore ?? 0) >= 50) v += 8;                   // reliable → safe to rely on
  if (f.stack === "elixir" && /\/(content|plugin|portable_doc|search|sheets)\b/.test(n.path)) v += 6;
  return { reach: r, prior: Math.max(1, Math.min(100, Math.round(v))) };
}

if (cmd === "batches") {
  const BDIR = join(HERE, "batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
  if (!existsSync(join(HERE, "results"))) mkdirSync(join(HERE, "results"));
  const rows = nodes.map(n => { const p = prior(n); return { path: n.path, id: n.id, stack: n.fields.stack, role: n.fields.role, importance: n.fields.importance, fanIn: n.fields.fanIn, reach: p.reach, usefulnessPrior: p.prior, description: n.fields.description }; });
  const pad = (i) => String(i).padStart(3, "0");
  let b = 0; for (let i = 0; i < rows.length; i += BATCH) { writeFileSync(join(BDIR, `batch-${pad(b)}.json`), JSON.stringify({ batch: b, files: rows.slice(i, i + BATCH) }, null, 2)); b++; }
  writeFileSync(join(HERE, "batch-count.txt"), String(b));
  process.stderr.write(`[usefulness] ${rows.length} files → ${b} batches (prior = reach × leverage × reliability)\n`);
  const top = [...rows].sort((a, x) => x.usefulnessPrior - a.usefulnessPrior).slice(0, 8);
  for (const r of top) process.stderr.write(`  prior ${String(r.usefulnessPrior).padStart(3)} reach ${String(r.reach).padStart(3)}  ${r.path}\n`);
}

if (cmd === "merge") {
  const RDIR = join(HERE, "results");
  // The agent prose stays only as a DESCRIPTION (the `why`); the score is computed.
  const out = {};
  for (const f of (existsSync(RDIR) ? readdirSync(RDIR) : []).filter(f => f.endsWith(".json"))) {
    try { for (const r of JSON.parse(readFileSync(join(RDIR, f), "utf8"))) if (r?.path) out[r.path] = { why_useful: r.why_useful }; } catch {}
  }
  // reach = pure programmatic: normalize the transitive-dependent count to 0-100.
  // Distribution is heavily skewed, so log-scale against the corpus max.
  const reachByPath = {}; let maxReach = 0;
  for (const n of nodes) { const r = reach(n.id); reachByPath[n.path] = r; if (r > maxReach) maxReach = r; }
  const denom = Math.log2(1 + maxReach) || 1;
  const reachScore = (r) => Math.round((Math.log2(1 + r) / denom) * 100);
  const report = {
    at: new Date().toISOString(),
    // Every report DECLARES the platform its reach was scored for.
    platform: { profile: PROFILE.profile, source: PROFILE.source },
    platformVerdicts: PR.verdicts,
    files: {},
  };
  for (const n of nodes) {
    const a = out[n.path]; const r = reachByPath[n.path]; const score = reachScore(r);
    const why = a?.why_useful || "";
    report.files[n.path] = {
      reach: r, reachScore: score, why,
      // The platform discount, spelled out: the raw count and each selector
      // edge that did not count, with why. Absent when nothing was discounted.
      ...(PR.files[n.path]?.discounted
        ? { reachRaw: PR.files[n.path].raw, platformDiscount: PR.files[n.path].edges.filter(e => e.state === "inactive").map(e => ({ selector: e.selector, state: e.state, why: e.why })) }
        : {}),
      // legacy mirrors so older readers keep working; treat the score as reach.
      usefulness: score, why_useful: why,
    };
  }
  writeFileSync(join(HERE, "usefulness-report.json"), JSON.stringify(report, null, 2));
  const n = Object.values(report.files).filter(x => x.why).length;
  process.stderr.write(`[reach] computed reach for ${nodes.length} files (normalized 0-100) · ${n} carry a 'why' description → usefulness-report.json\n`);
  const disc = Object.entries(PR.files).filter(([, f]) => f.discounted);
  process.stderr.write(`[reach] platform profile ${PROFILE.profile} (${PROFILE.source}) · ${PR.verdicts.length} selector edge(s), ${disc.length} file(s) discounted\n`);
  for (const [p, f] of disc) process.stderr.write(`  ${p}: reach ${f.raw} → ${f.reach} — ${f.edges.filter(e => e.state === "inactive").map(e => e.why).join("; ")}\n`);
}
