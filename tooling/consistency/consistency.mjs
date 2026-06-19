#!/usr/bin/env node
// Consistency pass — RELATIONAL research (properties that exist BETWEEN files,
// invisible to per-file coverage). Programmatic: group peers, derive each group's
// dominant pattern, flag deviations. Inconsistency = distance from your own norm.
//
//   consistency.mjs scan      → naming + structure + layering + dead-code + dup  [free]
//   consistency.mjs batches   → per-group agent tasks for groups WITH outliers   [free]
//   consistency.mjs report    → write consistency-report.html from scan json     [free]
//
// Agents (optional, over GROUPS not files) then: name the canonical pattern in
// prose + judge each outlier as meaningful-drift vs intentional-exception.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync, readdirSync } from "node:fs";
import { dirname, join, basename, extname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const cfg = JSON.parse(readFileSync(join(HERE, "config.json"), "utf8"));
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 128 * 1024 * 1024 });
const cmd = process.argv[2] || "scan";

const idxPath = join(ROOT, "tooling/blast-radius/index.json");
const idx = existsSync(idxPath) ? JSON.parse(readFileSync(idxPath, "utf8")) : null;

// ---- glob ----
function expand(g){const m=g.match(/\{([^{}]+)\}/);if(!m)return[g];return m[1].split(",").flatMap(o=>expand(g.slice(0,m.index)+o+g.slice(m.index+m[0].length)));}
function globToRe(g){let re="";for(let i=0;i<g.length;i++){const c=g[i];if(c==="*"){if(g[i+1]==="*"){if(g[i+2]==="/"){re+="(?:.*/)?";i+=2;}else{re+=".*";i+=1;}}else re+="[^/]*";}else if(c==="/")re+="/";else if("+?^${}()|[].\\".includes(c))re+="\\"+c;else re+=c;}return new RegExp("^"+re+"$");}
const reC=new Map();
const matchAny=(p,globs)=>globs.some(g=>expand(g).some(e=>{if(!reC.has(e))reC.set(e,globToRe(e));return reC.get(e).test(p);}));

// ---- code files ----
const ext = (f) => extname(f).slice(1);
const isTest = (f) => /(_test\.(go|exs)|\.test\.[tj]sx?|\.spec\.[tj]sx?)$/.test(f);
const files = git(["ls-files"]).split("\n").filter(Boolean)
  .filter(f => cfg.codeExt.includes(ext(f)) && !/^_attic\//.test(f) && !/(^|\/)deps\//.test(f));
const read = (f) => { try { return readFileSync(join(ROOT, f), "utf8"); } catch { return ""; } };
const stackOf = (f) => f.endsWith(".go") ? "go" : /\.(ex|exs|heex|eex)$/.test(f) ? "elixir" : "js";

// ---- naming helpers ----
function casing(name) {
  if (!/[-_]/.test(name) && /^[a-z][a-z0-9]*$/.test(name)) return "flat"; // single word — conforms to snake OR kebab
  if (/^[a-z0-9]+(_[a-z0-9]+)*$/.test(name)) return "snake";
  if (/^[a-z][a-zA-Z0-9]*$/.test(name) && /[A-Z]/.test(name)) return "camel";
  if (/^[a-z0-9]+(-[a-z0-9]+)+$/.test(name)) return "kebab";
  if (/^[A-Z]/.test(name)) return "Pascal";
  return "other";
}
const trailingToken = (name) => { const p = name.split("_"); return p.length > 1 ? p[p.length - 1] : null; };
const modal = (arr) => { const c = {}; for (const x of arr) if (x != null) c[x] = (c[x] || 0) + 1; let best = null, n = 0; for (const [k, v] of Object.entries(c)) if (v > n) { best = k; n = v; } return { value: best, count: n, dist: c }; };

// ---- structural signature (imports / use) ----
function signature(f) {
  const txt = read(f), toks = new Set();
  if (stackOf(f) === "elixir") {
    for (const m of txt.matchAll(/^\s*(use|import|alias|@?behaviour)\s+([A-Z][\w.]*)/gm)) toks.add(`${m[1]} ${m[2].split(".").slice(0,2).join(".")}`);
  } else if (stackOf(f) === "go") {
    const blk = txt.match(/import\s*\(([\s\S]*?)\)/); const body = blk ? blk[1] : (txt.match(/import\s+"[^"]+"/g) || []).join("\n");
    for (const m of body.matchAll(/"([^"]+)"/g)) toks.add(m[1].replace(/^github\.com\/FRIKKern\/barkpark\//, "internal:"));
  } else {
    for (const m of txt.matchAll(/import\s+[^'"]*['"]([^'"]+)['"]/g)) toks.add(m[1].replace(/^\.+\//, "./"));
  }
  return toks;
}

// ===================================================================== scan
function scan() {
  // group by directory (peers that should look alike), code files, >= minGroupSize
  const byDir = {};
  for (const f of files) (byDir[dirname(f)] ||= []).push(f);
  const groups = [];
  for (const [dir, fs] of Object.entries(byDir)) {
    if (fs.length < cfg.minGroupSize) continue;
    const names = fs.map(f => basename(f).replace(/\.[^.]+$/, ""));
    const cas = modal(names.map(casing));
    const suf = modal(names.map(trailingToken));

    // structural signature norm
    const sigs = fs.map(f => ({ f, s: signature(f) }));
    const freq = {};
    for (const { s } of sigs) for (const t of s) freq[t] = (freq[t] || 0) + 1;
    const common = Object.entries(freq).filter(([, c]) => c / fs.length >= cfg.commonThreshold).map(([t]) => t);

    const outliers = [];
    for (const { f, s } of sigs) {
      const name = basename(f).replace(/\.[^.]+$/, "");
      const reasons = [];
      const fc = casing(name);
      if (cas.value && cas.value !== "flat" && fc !== cas.value && fc !== "Pascal" && fc !== "flat") reasons.push(`naming: ${fc} vs group ${cas.value}`);
      if (suf.value && suf.count / fs.length >= cfg.commonThreshold && trailingToken(name) !== suf.value) reasons.push(`suffix: missing _${suf.value}`);
      // only the framework CONTRACT (use/behaviour) is a real consistency signal;
      // alias/import legitimately vary by what a file needs.
      const missing = common.filter(t => !s.has(t) && /^(use|@?behaviour) /.test(t));
      if (missing.length) reasons.push(`structure: missing ${missing.slice(0,3).join(", ")}${missing.length>3?` (+${missing.length-3})`:""}`);
      if (reasons.length) outliers.push({ file: f, reasons });
    }
    const conform = Math.round((1 - outliers.length / fs.length) * 100);
    groups.push({ dir, stack: stackOf(fs[0]), n: fs.length, casing: cas.value, suffix: suf.value, commonSignature: common, conform, outliers });
  }
  groups.sort((a, b) => a.conform - b.conform || b.outliers.length - a.outliers.length);

  // layering back-edges
  const layering = [];
  for (const rule of cfg.layeringRules) {
    for (const f of files) {
      if (!matchAny(f, rule.appliesTo)) continue;
      if (rule.exclude && matchAny(f, rule.exclude)) continue;
      const re = new RegExp(rule.forbid, "m");
      const allow = rule.allow ? new RegExp(rule.allow) : null;
      // skip `#` comments AND inside """ heredocs (@moduledoc/@doc prose) AND backtick-quoted refs
      const lines = read(f).split("\n");
      let inHeredoc = false, hit = -1;
      for (let li = 0; li < lines.length; li++) {
        const l = lines[li];
        if ((l.match(/"""/g) || []).length % 2 === 1) { inHeredoc = !inHeredoc; continue; }
        if (inHeredoc || /^\s*#/.test(l)) continue;
        const m = l.match(re); if (!m) continue;
        if (allow && allow.test(l)) continue;
        if (new RegExp("`[^`]*" + rule.forbid).test(l)) continue; // markdown-quoted in a comment
        hit = li; break;
      }
      if (hit >= 0) layering.push({ rule: rule.name, file: f, line: hit + 1, message: rule.message });
    }
  }

  // dead Go packages (zero internal importers, not main/entry)
  const dead = [];
  if (idx?.go) for (const [pkg, importers] of Object.entries(idx.go.reverse || {})) { /* reverse only lists imported */ }
  if (idx?.go) {
    const imported = new Set(Object.keys(idx.go.reverse || {}));
    for (const pkg of Object.keys(idx.go.forward || {})) {
      const isMain = (idx.go.dirToPkg && Object.entries(idx.go.dirToPkg).find(([d,p])=>p===pkg && (d==="."||/cmd\//.test(d))));
      if (!imported.has(pkg) && !isMain) dead.push(pkg.replace("github.com/FRIKKern/barkpark/", ""));
    }
  }

  // near-duplication within (stack, kind-by-suffix)
  const dup = nearDup();

  const report = { at: new Date().toISOString(), groupsAnalyzed: groups.length,
    groups, layering, deadGoPackages: dead, duplication: dup,
    summary: {
      lowConformGroups: groups.filter(g => g.conform < 80).length,
      totalOutliers: groups.reduce((a, g) => a + g.outliers.length, 0),
      layeringViolations: layering.length, deadGo: dead.length, dupPairs: dup.length,
    } };
  writeFileSync(join(HERE, "consistency-report.json"), JSON.stringify(report, null, 2));
  return report;
}

function nearDup() {
  const norm = (txt) => txt.split("\n").map(l => l.trim()).filter(l => l && !/^(\/\/|#|\*|--)/.test(l));
  const shingles = (lines) => { const s = new Set(); const k = cfg.dupShingleLines; for (let i = 0; i + k <= lines.length; i++) s.add(lines.slice(i, i + k).join("")); return s; };
  const jac = (a, b) => { let inter = 0; const [s, l] = a.size < b.size ? [a, b] : [b, a]; for (const x of s) if (l.has(x)) inter++; return inter / (a.size + b.size - inter || 1); };
  const groups = {};
  for (const f of files) { if (isTest(f)) continue; const key = stackOf(f) + ":" + (trailingToken(basename(f).replace(/\.[^.]+$/, "")) || ext(f)); (groups[key] ||= []).push(f); }
  const pairs = [];
  for (const [, fs] of Object.entries(groups)) {
    if (fs.length < 2 || fs.length > cfg.maxDupGroup) continue;
    const sh = fs.map(f => ({ f, s: shingles(norm(read(f))) })).filter(x => x.s.size >= 3);
    for (let i = 0; i < sh.length; i++) for (let j = i + 1; j < sh.length; j++) {
      const sim = jac(sh[i].s, sh[j].s);
      if (sim >= cfg.dupJaccard) pairs.push({ a: sh[i].f, b: sh[j].f, similarity: Math.round(sim * 100) / 100 });
    }
  }
  return pairs.sort((x, y) => y.similarity - x.similarity).slice(0, 40);
}

// ==================================================================== report
function attachVerdicts(r) {
  const RDIR = join(HERE, "results");
  if (!existsSync(RDIR)) return r;
  const byDir = {};
  for (const f of readdirSync(RDIR).filter(f => f.endsWith(".json"))) {
    try { const v = JSON.parse(readFileSync(join(RDIR, f), "utf8")); if (v.dir) byDir[v.dir] = v; } catch {}
  }
  for (const g of r.groups) { const v = byDir[g.dir]; if (v) { g.canonicalPattern = v.canonical_pattern; g.verdicts = v.verdicts; } }
  return r;
}
function writeHtml(r) {
  const esc = (s) => String(s ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;");
  const vmap = (g) => Object.fromEntries((g.verdicts||[]).map(v=>[v.file, v]));
  const badge = (v) => v ? `<span class="v ${v.verdict}">${v.verdict}</span>` : "";
  const grp = (g) => { const vm = vmap(g); return `<tr class="${g.conform<80?'bad':g.conform<100?'warn':'ok'}"><td class="path">${g.dir}</td><td>${g.stack}</td><td class="n">${g.n}</td>`
    + `<td class="n"><b>${g.conform}%</b></td><td>${esc((g.casing||"")+(g.suffix?` · _${g.suffix}`:""))}${g.canonicalPattern?`<div class="norm">${esc(g.canonicalPattern)}</div>`:""}</td>`
    + `<td>${g.outliers.map(o=>`<div>${badge(vm[o.file])}<code>${basename(o.file)}</code> — ${esc(o.reasons.join("; "))}${vm[o.file]?.recommendation?`<div class="rec">→ ${esc(vm[o.file].recommendation)}</div>`:""}</div>`).join("")}</td></tr>`; };
  const html = `<!doctype html><meta charset=utf-8><title>Barkpark — Consistency</title>
<style>body{font:13px/1.45 -apple-system,Segoe UI,sans-serif;margin:0;color:#1a1a1a}
header{background:#0f172a;color:#fff;padding:14px 20px} h2{margin:22px 20px 6px;font-size:15px}
table{border-collapse:collapse;width:calc(100% - 40px);margin:0 20px} th,td{padding:5px 8px;border-bottom:1px solid #e2e8f0;text-align:left;vertical-align:top}
th{background:#e2e8f0;font-size:11px;text-transform:uppercase} td.path{font-family:ui-monospace,monospace;font-size:12px} td.n{text-align:right}
tr.bad td:nth-child(4){background:#fee2e2} tr.warn td:nth-child(4){background:#fef9c3} code{background:#f1f5f9;padding:0 3px;border-radius:3px}
.norm{color:#0369a1;font-size:12px;margin-top:3px} .rec{color:#475569;font-size:11px;margin-left:14px}
.v{font-size:10px;padding:1px 5px;border-radius:8px;margin-right:5px;text-transform:uppercase}
.v.drift{background:#fecaca} .v.intentional{background:#bbf7d0} .v.refactor{background:#fde68a}</style>
<header><b>Barkpark — Style &amp; Consistency</b><div style="font-size:12px;opacity:.85">${r.groupsAnalyzed} peer-groups · ${r.summary.lowConformGroups} below 80% conformance · ${r.summary.totalOutliers} outliers · ${r.summary.layeringViolations} layering · ${r.summary.deadGo} dead Go pkgs · ${r.summary.dupPairs} near-dup pairs</div></header>
<h2>Peer-group conformance (lowest first)</h2>
<table><thead><tr><th>Directory (peer group)</th><th>Stack</th><th>Files</th><th>Conform</th><th>Norm</th><th>Outliers vs the group's own pattern</th></tr></thead>
<tbody>${r.groups.filter(g=>g.outliers.length).map(grp).join("")}</tbody></table>
<h2>Layering back-edges (dependency-direction violations)</h2>
<table><tbody>${r.layering.map(l=>`<tr><td class=path>${l.file}:${l.line}</td><td>${esc(l.message)}</td></tr>`).join("")||"<tr><td>none</td></tr>"}</tbody></table>
<h2>Near-duplication (same kind, ≥${cfg.dupJaccard} similarity)</h2>
<table><tbody>${r.duplication.map(d=>`<tr><td class="n">${d.similarity}</td><td class=path>${d.a}</td><td class=path>${d.b}</td></tr>`).join("")||"<tr><td>none</td></tr>"}</tbody></table>
<h2>Dead Go packages (zero internal importers)</h2>
<div style="margin:0 20px">${r.deadGoPackages.map(esc).join(", ")||"none"}</div>`;
  writeFileSync(join(HERE, "consistency-report.html"), html);
}

// ==================================================================== batches
function batches(r) {
  const BDIR = join(HERE, "batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
  if (!existsSync(join(HERE, "results"))) mkdirSync(join(HERE, "results"));
  const todo = r.groups.filter(g => g.outliers.length);
  todo.forEach((g, i) => writeFileSync(join(BDIR, `group-${String(i).padStart(3,"0")}.json`), JSON.stringify(g, null, 2)));
  writeFileSync(join(HERE, "batch-count.txt"), String(todo.length));
  process.stderr.write(`[batches] ${todo.length} group(s) with outliers → ${BDIR.replace(ROOT+"/","")}/\n`);
}

// ======================================================================= run
const r = scan();
if (cmd === "merge") attachVerdicts(r);
if (cmd === "report" || cmd === "scan" || cmd === "merge") writeHtml(r);
if (cmd === "batches") batches(r);

const C = process.stderr.isTTY ? { y:"\x1b[33m", r:"\x1b[31m", g:"\x1b[32m", b:"\x1b[1m", x:"\x1b[0m" } : {y:"",r:"",g:"",b:"",x:""};
const e = (s)=>process.stderr.write(s+"\n");
e(`${C.b}consistency${C.x}  ${r.groupsAnalyzed} peer-groups analyzed`);
e(`  ${r.summary.lowConformGroups} group(s) <80% conformance · ${r.summary.totalOutliers} outliers`);
e(`  ${r.summary.layeringViolations} layering back-edge(s) · ${r.summary.deadGo} dead Go pkg(s) · ${r.summary.dupPairs} near-dup pair(s)`);
e(`  → consistency-report.{json,html}`);
if (r.groups.filter(g=>g.outliers.length).length) {
  e(`  ${C.y}lowest-conformance groups:${C.x}`);
  for (const g of r.groups.filter(g=>g.outliers.length).slice(0,6)) e(`    ${String(g.conform).padStart(3)}% ${g.dir} (${g.outliers.length}/${g.n} off-pattern)`);
}
