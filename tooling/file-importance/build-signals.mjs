#!/usr/bin/env node
// File-importance signal builder — the PROGRAMMATIC backbone (zero tokens).
// For every tracked, non-vendored file it computes objective importance signals
// (fan-in, churn, seam membership, LOC, kind, entrypoint, core-dir) and a
// deterministic prior score. Code files are partitioned into batches for the
// agent fan-out; data/asset/doc files get a programmatic description + score.
//
// Reuses the blast-radius reverse-dependency index for fan-in.
//
// Outputs (gitignored):
//   file-signals.json   — every file + signals + prior + auto-description
//   file-batches.json    — { batches:[[...code files...]], tierB:[...] }

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join, basename, extname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
const BATCH = Number(process.argv[2] || 12);

// ---- blast-radius index (fan-in) ----
const idxPath = join(ROOT, "tooling/blast-radius/index.json");
const idx = existsSync(idxPath) ? JSON.parse(readFileSync(idxPath, "utf8")) : null;
const cfg = JSON.parse(readFileSync(join(ROOT, "tooling/blast-radius/config.json"), "utf8"));

// ---- glob matcher (for seam) ----
function expand(g){const m=g.match(/\{([^{}]+)\}/);if(!m)return[g];return m[1].split(",").flatMap(o=>expand(g.slice(0,m.index)+o+g.slice(m.index+m[0].length)));}
function globToRe(g){let re="";for(let i=0;i<g.length;i++){const c=g[i];if(c==="*"){if(g[i+1]==="*"){if(g[i+2]==="/"){re+="(?:.*/)?";i+=2;}else{re+=".*";i+=1;}}else re+="[^/]*";}else if(c==="/")re+="/";else if("+?^${}()|[].\\".includes(c))re+="\\"+c;else re+=c;}return new RegExp("^"+re+"$");}
const reC=new Map();
const matchAny=(p,globs)=>globs.some(g=>expand(g).some(e=>{if(!reC.has(e))reC.set(e,globToRe(e));return reC.get(e).test(p);}));
const seamGlobs = cfg.seam.surfaces.flatMap(s=>s.globs);

// ---- file list ----
const EXCLUDE = /(^|\/)(node_modules|_build|deps|dist|\.git|vendor|priv\/static\/assets|tmp)\/|package-lock\.json$|pnpm-lock\.yaml$|\.lock$|go\.sum$|erl_crash\.dump$/;
const files = git(["ls-files"]).split("\n").filter(Boolean).filter(f => !EXCLUDE.test(f));

// ---- churn (one pass over history) ----
const churn = {};
for (const line of git(["log", "--all", "--pretty=format:", "--name-only"]).split("\n")) {
  const f = line.trim(); if (f) churn[f] = (churn[f] || 0) + 1;
}

// ---- fan-in helpers (package-level from index) ----
function longestPrefix(path, map){let best=null;for(const k of Object.keys(map||{})){if(k==="."||path===k||path.startsWith(k+"/")){if(!best||k.length>best.length)best=k;}}return best;}
function fanIn(f){
  if(/\.(ts|tsx|js|mjs|jsx)$/.test(f) && idx?.js){const d=longestPrefix(f,idx.js.dirToName);if(d){const pkg=idx.js.dirToName[d];return (idx.js.reverse[pkg]||[]).length;}}
  if(f.endsWith(".go") && idx?.go){const d=longestPrefix(dirname(f),idx.go.dirToPkg);if(d){const p=idx.go.dirToPkg[d];return (idx.go.reverse[p]||[]).length;}}
  if(/\.exs?$/.test(f) && idx?.elixir){return (idx.elixir.reverse[f]||[]).length;}
  return 0;
}

// ---- kind / stack / entrypoint classification ----
const STACK = (f)=> f.endsWith(".go")?"go": /\.exs?$|\.heex$|\.eex$/.test(f)?"elixir": /\.(ts|tsx|js|mjs|jsx)$/.test(f)?"js": /\.(md|mdx)$/.test(f)?"docs": "other";
const isTest = (f)=> /(_test\.go|\.test\.[tj]sx?|\.spec\.[tj]sx?|_test\.exs)$/.test(f) || /(^|\/)test\//.test(f) || /(^|\/)__tests__\//.test(f);
function kind(f){
  if(isTest(f)) return "test";
  if(/\.(md|mdx|txt)$/.test(f)) return "doc";
  if(/\.(svg|ttf|png|jpg|jpeg|gif|ico|woff2?|css|xsd|xml|eot)$/.test(f)) return "asset";
  if(/(^|\/)(fixtures?|priv|\.demo-content|examples?|obsidian_example|proof|secrets|IndxData)\//.test(f) || /\.(json|yml|yaml|toml)$/.test(f)) return "data/config";
  if(/\.(ex|exs|go|ts|tsx|js|mjs|jsx|heex|eex|sh|ps1|tmpl)$/.test(f)) return "code";
  return "other";
}
const ENTRY = /(^|\/)(main\.go|router\.ex|endpoint\.ex|application\.ex|mix\.exs|index\.ts|cli\.ts|cli\.go|root\.html\.heex|run\.sh|deploy\.sh|Makefile)$/;
const CORE = [/(^|\/)lib\/barkpark\//,/(^|\/)lib\/barkpark_web\//,/(^|\/)internal\//,/(^|\/)js\/packages\/core\/src\//,/(^|\/)cmd\//, /(^|\/)plugins?\//];

function loc(f){try{return readFileSync(join(ROOT,f),"utf8").split("\n").length;}catch{return 0;}}

const churnVals = Object.values(churn).sort((a,b)=>a-b);
const pct = (v)=>{ if(!churnVals.length)return 0; let lo=0,hi=churnVals.length; while(lo<hi){const m=(lo+hi)>>1; if(churnVals[m]<v)lo=m+1;else hi=m;} return lo/churnVals.length; };

function priorScore(s){
  let v = 0;
  v += Math.min(35, Math.log2(1 + s.fanIn) * 12);     // fan-in (reverse deps), log-scaled
  if (s.seam) v += 20;                                  // wire-contract surface
  v += s.churnPct * 18;                                 // how actively central
  if (s.coreDir) v += 14;                               // lives in a core dir
  if (s.entrypoint) v += 16;                            // process / module entrypoint
  if (s.kind === "test") v -= 14;
  if (s.kind === "asset") v -= 24;
  if (s.kind === "data/config") v -= 12;
  if (s.kind === "doc") v -= 8;
  return Math.max(1, Math.min(100, Math.round(v)));
}

function autoDesc(f, s){
  const b = basename(f);
  if (s.kind === "doc") { try{const t=readFileSync(join(ROOT,f),"utf8").split("\n").find(l=>l.startsWith("#"));return (t||b).replace(/^#+\s*/,"").slice(0,140);}catch{return b;} }
  if (s.kind === "asset") return `${extname(f).slice(1).toUpperCase()} asset.`;
  if (s.kind === "data/config") return `${extname(f).slice(1)||"data"} ${/(test|fixture)/.test(f)?"fixture":"config/data"} file.`;
  if (s.kind === "test") return `Test for ${dirname(f).split("/").pop()}.`;
  return b;
}

const signals = files.map(f => {
  const s = { path: f, stack: STACK(f), kind: kind(f), loc: loc(f), churn: churn[f]||0,
    fanIn: fanIn(f), seam: matchAny(f, seamGlobs), entrypoint: ENTRY.test(f), coreDir: CORE.some(re=>re.test(f)) };
  s.churnPct = pct(s.churn);
  s.prior = priorScore(s);
  s.autoDescription = autoDesc(f, s);
  return s;
});

// Tier A = code + tests (real logic, gets an agent). Tier B = data/asset/doc (programmatic).
const tierA = signals.filter(s => s.kind === "code" || s.kind === "test");
const tierB = signals.filter(s => s.kind !== "code" && s.kind !== "test");

// batch tierA, biggest-prior first so the most important files land early
tierA.sort((a,b)=>b.prior-a.prior);
const batches = [];
for (let i=0;i<tierA.length;i+=BATCH) batches.push(tierA.slice(i,i+BATCH).map(s=>({
  path:s.path, stack:s.stack, loc:s.loc, fanIn:s.fanIn, churn:s.churn, seam:s.seam, entrypoint:s.entrypoint, coreDir:s.coreDir, prior:s.prior
})));

writeFileSync(join(HERE,"file-signals.json"), JSON.stringify({ generatedFrom: idx?.head||"(no index)", total: signals.length, signals }, null, 2));
writeFileSync(join(HERE,"file-batches.json"), JSON.stringify({ batchSize: BATCH, tierACount: tierA.length, tierBCount: tierB.length, batches, tierB }, null, 2));

// per-batch files (one tiny file per agent) + a clean results dir
const BDIR = join(HERE, "batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
const RDIR = join(HERE, "results"); rmSync(RDIR, { recursive: true, force: true }); mkdirSync(RDIR, { recursive: true });
const pad = (i)=>String(i).padStart(3,"0");
batches.forEach((b,i)=> writeFileSync(join(BDIR,`batch-${pad(i)}.json`), JSON.stringify({ batch: i, files: b }, null, 2)));

console.error(`[signals] ${signals.length} files`);
console.error(`  tier A (agent-scored, code): ${tierA.length} → ${batches.length} batches of ${BATCH}`);
console.error(`  tier B (programmatic): ${tierB.length}`);
console.error(`  seam files: ${signals.filter(s=>s.seam).length} · entrypoints: ${signals.filter(s=>s.entrypoint).length}`);
console.error(`  top-10 prior:`);
for (const s of [...signals].sort((a,b)=>b.prior-a.prior).slice(0,10)) console.error(`    ${String(s.prior).padStart(3)} ${s.path} (fanIn=${s.fanIn} churn=${s.churn}${s.seam?" SEAM":""})`);
