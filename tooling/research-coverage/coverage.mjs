#!/usr/bin/env node
// Research-coverage ledger — the PROGRAMMATIC guarantee that every file has been
// evaluated, and that re-checking costs ZERO tokens until something actually
// changes. Walks the filesystem (not just git), content-hashes every file, and
// diffs against the ledger to classify: covered / stale / new / orphaned.
//
// The skill flow:
//   coverage.mjs scan      → report coverage %, list stale+new                      [free]
//                            NOT read-only: it rewrites coverage-report.json, which
//                            tooling/quality, tooling/cody and tooling/status all
//                            read. The write is atomic (tmp+rename) and idempotent,
//                            so re-executing scan is safe, but it IS a write.
//   coverage.mjs batches   → write per-batch files for ONLY the stale+new set      [free]
//   <agents research those batches, writing results/>                              [tokens — only on drift]
//   coverage.mjs record    → fold agent results into the ledger w/ current hashes  [free]
//   coverage.mjs prune     → drop orphaned (deleted) files from the ledger         [free]
//   coverage.mjs seed      → bootstrap the ledger from the importance run          [free, one-time]
//
// EVERY LEDGER MUTATION GOES THROUGH withLedger (see ledger-io.mjs): a lockfile
// mutex, a re-read INSIDE the lock, a rev CAS, and an atomic tmp+rename. Before
// that, two concurrent `record` runs with disjoint results deterministically
// destroyed one whole contribution with no error — and every entry was rebuilt
// from a fixed seven-key literal, silently dropping any field a newer writer had
// added. ledger-io.mjs carries the mutation evidence for both.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, mkdirSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { readLedger, withLedger, writeJsonAtomic, foldEntry, provenanceKeysFrom } from "./ledger-io.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const cfg = JSON.parse(readFileSync(join(HERE, "config.json"), "utf8"));
// BP_RESEARCH_LEDGER relocates the ledger. Two writers pointed at one shared
// path share one lock and one critical section, which is what lets the
// concurrency test give each writer its OWN results/ directory instead of
// racing to swap files in a shared one. It is also the seam the sibling
// reproducibility row (tgw-bl-coverage-ledger-unreproducible) needs to move
// this ledger off one laptop.
const LEDGER = process.env.BP_RESEARCH_LEDGER || join(HERE, "research-ledger.json");
const PROV = provenanceKeysFrom(cfg);
const cmd = process.argv[2] || "scan";
const now = () => new Date().toISOString();

// ---- glob excludes ----
function expand(g){const m=g.match(/\{([^{}]+)\}/);if(!m)return[g];return m[1].split(",").flatMap(o=>expand(g.slice(0,m.index)+o+g.slice(m.index+m[0].length)));}
function globToRe(g){let re="";for(let i=0;i<g.length;i++){const c=g[i];if(c==="*"){if(g[i+1]==="*"){if(g[i+2]==="/"){re+="(?:.*/)?";i+=2;}else{re+=".*";i+=1;}}else re+="[^/]*";}else if(c==="/")re+="/";else if("+?^${}()|[].\\".includes(c))re+="\\"+c;else re+=c;}return new RegExp("^"+re+"$");}
const reC=new Map();
const matchAny=(p,globs)=>globs.some(g=>expand(g).some(e=>{if(!reC.has(e))reC.set(e,globToRe(e));return reC.get(e).test(p);}));
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

// ---- enumerate project files = tracked ∪ untracked-not-ignored, minus binaries/sensitive ----
function projectFiles() {
  const tracked = git(["ls-files"]).split("\n").filter(Boolean);
  const untracked = git(["ls-files", "--others", "--exclude-standard"]).split("\n").filter(Boolean);
  const all = [...new Set([...tracked, ...untracked])];
  return all.filter(f =>
    !cfg.excludePathPrefixes.some(p => f.startsWith(p)) &&
    !matchAny(f, cfg.excludeGlobs)
  );
}
const hashOf = (rel) => { try { return createHash("sha256").update(readFileSync(join(ROOT, rel))).digest("hex").slice(0, 16); } catch { return "ERR"; } };

const loadLedger = () => readLedger(LEDGER);

// ---- classify current disk vs ledger ----
function classify(ledger) {
  const disk = projectFiles();
  const covered = [], stale = [], fresh = [];
  for (const f of disk) {
    const h = hashOf(f);
    const e = ledger.files[f];
    if (!e) fresh.push({ path: f, hash: h });
    else if (e.hash !== h) stale.push({ path: f, hash: h });
    else covered.push(f);
  }
  const diskSet = new Set(disk);
  const orphaned = Object.keys(ledger.files).filter(f => !diskSet.has(f));
  const total = disk.length;
  const pct = total ? Math.round((covered.length / total) * 1000) / 10 : 100;
  return { disk, covered, stale, fresh, orphaned, total, pct };
}

// ======================================================================= scan
if (cmd === "scan") {
  const ledger = loadLedger();
  const c = classify(ledger);
  const report = { at: now(), total: c.total, covered: c.covered.length, stale: c.stale.length, new: c.fresh.length, orphaned: c.orphaned.length,
    pct: c.pct, lastFullResearch: ledger.meta.lastFullResearch,
    staleFiles: c.stale.map(s => s.path), newFiles: c.fresh.map(s => s.path), orphanedFiles: c.orphaned };
  // Atomic: four other tools read this file, and two concurrent scans must never
  // leave one of them parsing half a document. The ledger itself is untouched
  // here — scan is the one command that mutates no research state.
  writeJsonAtomic(join(HERE, "coverage-report.json"), report);

  const C = process.stderr.isTTY ? { g:"\x1b[32m", y:"\x1b[33m", r:"\x1b[31m", b:"\x1b[1m", x:"\x1b[0m" } : {g:"",y:"",r:"",b:"",x:""};
  const e = (s)=>process.stderr.write(s+"\n");
  e(`${C.b}research coverage${C.x}  ${C.b}${c.pct}%${C.x}  (${c.covered.length}/${c.total} files current)`);
  e(`  last full research: ${ledger.meta.lastFullResearch || C.y+"never"+C.x}`);
  if (c.stale.length) e(`  ${C.y}↻ ${c.stale.length} CHANGED (stale research)${C.x}`);
  if (c.fresh.length) e(`  ${C.y}＋ ${c.fresh.length} NEW (never researched)${C.x}`);
  if (c.orphaned.length) e(`  ${C.r}－ ${c.orphaned.length} DELETED (prune)${C.x}`);
  const todo = c.stale.length + c.fresh.length;
  if (!todo && !c.orphaned.length) e(`  ${C.g}✓ 100% — every file evaluated & current. Agents not needed.${C.x}`);
  else e(`  ${C.b}→ ${todo} file(s) need agent research; run: coverage.mjs batches${C.x}`);
  process.exit(0);
}

// ==================================================================== batches
// Emit per-batch files for ONLY the stale+new set, so the agent fan-out touches
// nothing that's already covered.
if (cmd === "batches") {
  const ledger = loadLedger();
  const c = classify(ledger);
  const todo = [...c.stale, ...c.fresh];
  const BDIR = join(HERE, "batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
  const RDIR = join(HERE, "results"); if (!existsSync(RDIR)) mkdirSync(RDIR, { recursive: true });
  const B = cfg.batchSize, pad = (i)=>String(i).padStart(3,"0");
  let n = 0;
  for (let i = 0; i < todo.length; i += B) {
    writeFileSync(join(BDIR, `batch-${pad(n)}.json`), JSON.stringify({ batch: n, files: todo.slice(i, i+B).map(t=>({ path:t.path, hash:t.hash })) }, null, 2));
    n++;
  }
  process.stderr.write(`[batches] ${todo.length} uncovered file(s) → ${n} batch(es) of ${B} in ${relative(ROOT,BDIR)}/\n`);
  process.stderr.write(n ? `[batches] dispatch ${n} agents, each writes results/batch-NNN.json, then: coverage.mjs record\n` : `[batches] nothing to do — already 100%\n`);
  writeFileSync(join(HERE, "batch-count.txt"), String(n));
  process.exit(0);
}

// ===================================================================== record
// Fold agent results (results/*.json arrays of {path,role,description,score,...})
// into the ledger, stamping each with its CURRENT hash + researchedAt=now.
//
// The whole read-fold-classify-write runs inside withLedger's lock, on a ledger
// read inside that lock. That is deliberate and it is the ENTIRE lost-update
// fix: the fold takes ~11s on the full monorepo (classify() dominates), and any
// writer who read before that window and writes after it destroys everything
// folded in between. Serialising costs a wait; not serialising cost 200 entries.
if (cmd === "record") {
  let folded = 0, bad = [], pct = 0;
  withLedger(LEDGER, (ledger) => {
    const RDIR = join(HERE, "results");
    for (const f of (existsSync(RDIR) ? readdirSync(RDIR) : []).filter(f => f.endsWith(".json"))) {
      try {
        const arr = JSON.parse(readFileSync(join(RDIR, f), "utf8"));
        for (const r of (Array.isArray(arr) ? arr : [])) {
          if (!r?.path) continue;
          ledger.files[r.path] = foldEntry(ledger.files[r.path], {
            hash: hashOf(r.path), researchedAt: now(),
            score: r.score ?? r.criticality ?? null, role: r.role || "", description: r.description || "",
            whatBreaks: r.what_breaks_if_wrong || "", tier: "agent",
          }, r, PROV);
          folded++;
        }
      } catch (e) { bad.push(`${f}: ${e.message.split("\n")[0]}`); }
    }
    // re-evaluate coverage; if 100%, stamp lastFullResearch
    const c = classify(ledger);
    pct = c.pct;
    if (c.stale.length + c.fresh.length === 0) ledger.meta.lastFullResearch = now();
  });
  process.stderr.write(`[record] folded ${folded} result(s); coverage now ${pct}%${bad.length?` · ${bad.length} malformed`:""}\n`);
  bad.forEach(b => process.stderr.write(`  ✗ ${b}\n`));
  process.exit(0);
}

// ====================================================================== prune
if (cmd === "prune") {
  let removed = 0;
  withLedger(LEDGER, (ledger) => {
    const c = classify(ledger);
    for (const f of c.orphaned) delete ledger.files[f];
    removed = c.orphaned.length;
  });
  process.stderr.write(`[prune] removed ${removed} deleted file(s) from ledger\n`);
  process.exit(0);
}

// ======================================================================= seed
// One-time bootstrap: build the ledger from the importance run we already did.
if (cmd === "seed") {
  let n = 0;
  withLedger(LEDGER, (ledger) => {
    const sigPath = join(ROOT, "tooling/file-importance/file-signals.json");
    const sig = existsSync(sigPath) ? JSON.parse(readFileSync(sigPath, "utf8")).signals : [];
    // agent results (rich) keyed by path
    const RES = join(ROOT, "tooling/file-importance/results");
    const agent = {};
    for (const f of (existsSync(RES) ? readdirSync(RES) : []).filter(f=>f.endsWith(".json"))) {
      try { for (const r of JSON.parse(readFileSync(join(RES, f), "utf8"))) if (r?.path) agent[r.path] = r; } catch {}
    }
    const inScope = new Set(projectFiles());
    for (const s of sig) {
      const a = agent[s.path];
      if (!inScope.has(s.path)) continue; // only ledger files that are in the canonical project set
      ledger.files[s.path] = foldEntry(ledger.files[s.path], {
        hash: hashOf(s.path), researchedAt: now(),
        score: a?.criticality ?? s.prior, role: a?.role || "", description: a?.description || s.autoDescription || "",
        whatBreaks: a?.what_breaks_if_wrong || "", tier: a ? "agent" : "auto",
      }, a ?? s, PROV);
      n++;
    }
    ledger.meta.seededFrom = "importance-run";
  });
  process.stderr.write(`[seed] ledger bootstrapped with ${n} files from the importance run\n`);
  process.stderr.write(`[seed] now run: coverage.mjs scan\n`);
  process.exit(0);
}

process.stderr.write(`unknown command: ${cmd}\nusage: coverage.mjs scan|batches|record|prune|seed\n`);
process.exit(1);
